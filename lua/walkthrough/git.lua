-- Everything that runs or parses git.
local M = {}

-- Read-only calls pass --no-optional-locks: a plain `git diff` may refresh
-- the index and take index.lock, which would collide with a stage that
-- gitsigns is running at the same moment.
-- `env` adds environment variables for this one call (e.g. GIT_INDEX_FILE).
function M.run(dir, args, env)
  local cmd = { 'git', '--no-optional-locks', '-C', dir }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { text = true, env = env }):wait()
end

-- Calls that change the repository.
function M.write(dir, args, env)
  local cmd = { 'git', '-C', dir }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { text = true, env = env }):wait()
end

--- `git commit -F -` with `message` on stdin, hooks enabled, without waiting:
--- a hook may take a while. `on_done(result)` runs in the main loop with the
--- result of `vim.system`. Returns the process, or raises when git cannot be
--- started.
function M.commit_async(dir, message, on_done)
  return vim.system({ 'git', '-C', dir, 'commit', '-F', '-' }, { text = true, stdin = message },
    vim.schedule_wrap(on_done))
end

-- Git prints usage texts of several kB on some failures; keep one line.
function M.first_line(text)
  return vim.trim(vim.split(text or '', '\n', { plain = true })[1] or '')
end

function M.in_repo(dir)
  return M.run(dir, { 'rev-parse', '--is-inside-work-tree' }).code == 0
end

function M.has_head(dir)
  return M.run(dir, { 'rev-parse', '--verify', '--quiet', 'HEAD' }).code == 0
end

function M.is_tracked(dir, file)
  return M.run(dir, { 'ls-files', '--error-unmatch', '--', file }).code == 0
end

--- The top-level directory of the repository `dir` is in, or nil.
function M.toplevel(dir)
  local res = M.run(dir, { 'rev-parse', '--show-toplevel' })
  local top = res.code == 0 and vim.trim(res.stdout) or ''
  return top ~= '' and top or nil
end

-- The NUL-separated items of a `-z` listing.
local function split_z(text)
  return vim.tbl_filter(function(item)
    return item ~= ''
  end, vim.split(text or '', '\0', { plain = true }))
end

--- The files of the repository at `root` that differ from `ref` (default
--- HEAD) in the working tree, as paths relative to `root`, in the order
--- `git status` prints them: changes of tracked files by path, then
--- untracked files that are not ignored. Deleted files are left out. Raises
--- with a short message when `ref` is not a commit.
function M.changed_files(root, ref)
  local names = {}
  if ref == nil or ref == 'HEAD' then
    local res = M.run(root, { 'status', '--porcelain=v1', '-z', '--no-renames', '--untracked-files=all' })
    if res.code ~= 0 then
      error('git status failed: ' .. M.first_line(res.stderr), 0)
    end
    for _, item in ipairs(split_z(res.stdout)) do
      -- "XY path": two status letters, a space, the path.
      table.insert(names, item:sub(4))
    end
  else
    if ref:sub(1, 1) == '-' or M.run(root, { 'rev-parse', '--verify', '--quiet', ref .. '^{commit}' }).code ~= 0 then
      error('unknown revision ' .. ref, 0)
    end
    local diff = M.run(root, { 'diff', '--name-only', '-z', '--no-renames', '--no-ext-diff', ref, '--' })
    if diff.code ~= 0 then
      error('git diff failed: ' .. M.first_line(diff.stderr), 0)
    end
    vim.list_extend(names, split_z(diff.stdout))
    local others = M.run(root, { 'ls-files', '-z', '--others', '--exclude-standard' })
    if others.code == 0 then
      vim.list_extend(names, split_z(others.stdout))
    end
  end
  -- What is not a readable file now (a deleted one, a directory, a
  -- submodule) cannot be shown. A file removed from the index but still
  -- there is listed twice (deleted, untracked).
  local seen = {}
  return vim.tbl_filter(function(name)
    local keep = not seen[name] and vim.fn.filereadable(root .. '/' .. name) == 1
    seen[name] = true
    return keep
  end, names)
end

--- Whether the index of the repository at `root` differs from HEAD (there is
--- something to commit). Raises with a short message when git fails.
function M.has_staged(root)
  local res = M.run(root, { 'diff', '--cached', '--quiet' })
  if res.code > 1 then
    error('git diff failed: ' .. M.first_line(res.stderr), 0)
  end
  return res.code == 1
end

--- The staged files of the repository at `root`, as `{ { status, path } }`
--- (`M`, `A`, `D` ..., the path relative to `root`), in path order. Raises
--- with a short message when git fails.
function M.staged_files(root)
  local res = M.run(root, { '-c', 'core.quotepath=off', 'diff', '--cached', '--name-status', '-z', '--no-renames' })
  if res.code ~= 0 then
    error('git diff failed: ' .. M.first_line(res.stderr), 0)
  end
  local items, out = split_z(res.stdout), {}
  for i = 1, #items - 1, 2 do
    table.insert(out, { status = items[i], path = items[i + 1] })
  end
  return out
end

--- Parse `git diff -U0` output into hunks { start, count, removed } in
--- new-file line numbers, where `removed` holds the old lines deleted at
--- that spot. Pure: no git, no buffers.
function M.parse_hunks(text)
  local hunks, cur = {}, nil
  for _, l in ipairs(vim.split(text or '', '\n', { plain = true })) do
    -- Hunk header: @@ -old_start,old_count +new_start,new_count @@
    -- A missing count means 1.
    local start, count = l:match('^@@ %-%d+,?%d* %+(%d+),?(%d*) @@')
    if start then
      cur = { start = tonumber(start), count = count == '' and 1 or tonumber(count), removed = {} }
      table.insert(hunks, cur)
    elseif cur and l:sub(1, 1) == '-' then
      table.insert(cur.removed, l:sub(2))
    end
  end
  return hunks
end

-- A path as `git diff` prints it after `--- ` / `+++ `: a trailing tab (added
-- for names with spaces) is dropped, a quoted name is unescaped, the `a/` or
-- `b/` prefix goes. `/dev/null` is nil.
local function diff_path(text)
  local s = text:gsub('\t.*$', '')
  if s:sub(1, 1) == '"' and s:sub(-1) == '"' and #s >= 2 then
    local escapes = { t = '\t', n = '\n', ['"'] = '"', ['\\'] = '\\' }
    local out, i, body = {}, 1, s:sub(2, -2)
    while i <= #body do
      local c = body:sub(i, i)
      if c == '\\' then
        local oct = body:match('^[0-3][0-7][0-7]', i + 1)
        if oct then
          table.insert(out, string.char(tonumber(oct, 8)))
          i = i + 4
        else
          local n = body:sub(i + 1, i + 1)
          table.insert(out, escapes[n] or n)
          i = i + 2
        end
      else
        table.insert(out, c)
        i = i + 1
      end
    end
    s = table.concat(out)
  end
  if s == '/dev/null' then
    return nil
  end
  return (s:gsub('^[ab]/', ''))
end

-- The path of a `diff --git a/X b/X` header; for names that differ (a rename)
-- the rename lines that follow give the real ones.
local function header_path(rest)
  local len = (#rest - 5) / 2
  if len >= 1 and len == math.floor(len) and rest:sub(1, 2) == 'a/' and rest:sub(3, 2 + len) == rest:sub(len + 6) then
    return rest:sub(3, 2 + len)
  end
  return rest:match('^a/(.-) b/') or rest
end

--- Parse `git diff -U3` output (any context size) for one or more files into
--- `{ [path] = { hunks = { hunk... }, binary?, new?, deleted?, renamed_from? } }`.
--- A hunk is `{ old_start, old_count, new_start, new_count, lines }` and a
--- line `{ kind = ' ' | '+' | '-', text, old, new }`: `old` is missing on
--- an added line, `new` on a removed one. A line that has `\ No newline at
--- end of file` after it gets `noeol = true` (the marker is not a line). The
--- path is the new one (a rename shows as its new path, with `renamed_from`);
--- a deleted file is keyed by its old path. A binary file has no hunks and
--- `binary = true`. Pure: no git, no buffers.
function M.parse_diff(text)
  local list = {}
  local file, hunk, old, new
  -- Header lines seen for `file`: a second `--- ` starts another file when
  -- the output has no `diff --git` lines.
  local saw_old = false
  local function start(path)
    file = { path = path, hunks = {} }
    saw_old = false
    hunk = nil
    table.insert(list, file)
  end
  for _, l in ipairs(vim.split(text or '', '\n', { plain = true })) do
    local c = l:sub(1, 1)
    if hunk and c == '\\' then
      local last = hunk.lines[#hunk.lines]
      if last then
        last.noeol = true
      end
    elseif hunk and (old <= hunk.old_start + hunk.old_count - 1 or new <= hunk.new_start + hunk.new_count - 1) then
      -- Still inside the hunk body, where a line may look like a header.
      local line
      if c == '+' then
        line = { kind = '+', text = l:sub(2), new = new }
        new = new + 1
      elseif c == '-' then
        line = { kind = '-', text = l:sub(2), old = old }
        old = old + 1
      else
        -- A context line; one whose leading space was stripped is empty.
        line = { kind = ' ', text = l:sub(2), old = old, new = new }
        old, new = old + 1, new + 1
      end
      table.insert(hunk.lines, line)
    else
      hunk = nil
      local rest = l:match('^diff %-%-git (.*)$')
      if rest then
        start(header_path(rest))
      elseif l:match('^new file mode') and file then
        file.new = true
      elseif l:match('^deleted file mode') and file then
        file.deleted = true
      elseif l:match('^rename from ') and file then
        file.renamed_from = diff_path(l:sub(13))
      elseif l:match('^rename to ') and file then
        file.path = diff_path(l:sub(11)) or file.path
      elseif (l:match('^Binary files ') or l:match('^GIT binary patch')) and file then
        file.binary = true
      elseif l:match('^%-%-%- ') then
        if not file or saw_old or #file.hunks > 0 then
          start(nil)
        end
        saw_old = true
        file.old_path = diff_path(l:sub(5))
        if not file.old_path then
          file.new = true
        end
      elseif l:match('^%+%+%+ ') and file then
        local p = diff_path(l:sub(5))
        if p then
          file.path = p
        else
          file.deleted = true
          file.path = file.old_path or file.path
        end
      else
        -- @@ -old_start,old_count +new_start,new_count @@ ; a missing count is 1.
        local os, oc, ns, nc = l:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
        if os and file then
          hunk = {
            old_start = tonumber(os), old_count = oc == '' and 1 or tonumber(oc),
            new_start = tonumber(ns), new_count = nc == '' and 1 or tonumber(nc), lines = {},
          }
          old, new = hunk.old_start, hunk.new_start
          -- A zero count names the line before the gap; the first line of
          -- the body is the next one.
          if hunk.old_count == 0 then
            old = old + 1
          end
          if hunk.new_count == 0 then
            new = new + 1
          end
          table.insert(file.hunks, hunk)
        end
      end
    end
  end
  local out = {}
  for _, f in ipairs(list) do
    if f.path then
      f.old_path = nil
      out[f.path] = f
    end
  end
  return out
end

--- The runs of changed lines in parsed hunks, in the shape of `parse_hunks`:
--- `{ start, count, removed }` in new-file numbers. A run that only removes
--- lines starts at the line before the gap (0 at the top), like `git diff
--- -U0` says. The second result maps each `+` and `-` line table to its run.
--- Works on any context size.
function M.runs(hunks)
  local out, of = {}, {}
  for _, h in ipairs(hunks) do
    local cur
    local before = h.new_count == 0 and h.new_start or (h.new_start - 1)
    for _, line in ipairs(h.lines) do
      if line.kind == ' ' then
        cur, before = nil, line.new
      else
        if not cur then
          cur = { start = before, count = 0, removed = {} }
          table.insert(out, cur)
        end
        if line.kind == '+' then
          if cur.count == 0 then
            cur.start = line.new
          end
          cur.count = cur.count + 1
        else
          table.insert(cur.removed, line.text)
        end
        of[line] = cur
      end
    end
  end
  return out, of
end

--- `git diff -U<context>` of the files `rels` (relative to `root`) against
--- `ref` (the index when nil), as `parse_diff` gives it: one git call for
--- all of them. Raises with a short message when git fails.
function M.diff_files(root, ref, rels, context)
  local args = {
    '-c', 'core.quotepath=off', 'diff', '-U' .. (context or 3), '--no-color', '--no-ext-diff', '--no-renames',
    '--src-prefix=a/', '--dst-prefix=b/',
  }
  if ref then
    table.insert(args, ref)
  end
  table.insert(args, '--')
  vim.list_extend(args, rels)
  local res = M.run(root, args)
  if res.code ~= 0 then
    error('git diff failed: ' .. M.first_line(res.stderr), 0)
  end
  return M.parse_diff(res.stdout)
end

-- vim.text.diff exists from Neovim 0.12; vim.diff before that.
local text_diff = (vim.text and vim.text.diff) or vim.diff

local function as_text(lines)
  return #lines == 0 and '' or (table.concat(lines, '\n') .. '\n')
end

--- The hunks (as `parse_diff` gives them) from the lines `old` to the lines
--- `new`, with `ctxlen` lines of context. Pure; for files git cannot compare
--- by itself.
function M.diff_lines(old, new, ctxlen)
  local text = text_diff(as_text(old), as_text(new), { result_type = 'unified', ctxlen = ctxlen or 3 })
  local parsed = M.parse_diff('--- a/f\n+++ b/f\n' .. text)
  return parsed.f and parsed.f.hunks or {}
end

--- Hunks of an untracked `file` against `ref`. `git diff <ref> -- <file>`
--- cannot be used: a file that is not in the index counts as deleted, so it
--- prints the whole ref version as removed lines. A file that exists in the
--- ref is compared with the built-in diff; one that does not is all new.
local function untracked_hunks(dir, file, ref)
  local lines = vim.fn.readfile(file)
  local known = M.run(dir, { 'rev-parse', '--verify', '--quiet', ref .. '^{commit}' }).code == 0
  if not known and ref ~= 'HEAD' then
    error('git diff failed: unknown revision ' .. ref, 0)
  end
  local shown = known and M.run(dir, { 'show', ref .. ':./' .. vim.fs.basename(file) }) or { code = 1 }
  if shown.code ~= 0 then
    return { { start = 1, count = #lines, removed = {} } }
  end
  local old = vim.split(shown.stdout, '\n', { plain = true })
  if old[#old] == '' then
    table.remove(old)
  end
  return M.parse_hunks(text_diff(as_text(old), as_text(lines), { result_type = 'unified', ctxlen = 0 }))
end

--- Hunks of `file` against `ref`, or against the index when `ref` is nil.
--- Returns nil when there is nothing to compare with (not a repository).
--- Without any commit, HEAD is empty, so every line counts as new.
function M.hunks(file, ref)
  local dir = vim.fs.dirname(file)
  if ref and not M.is_tracked(dir, file) then
    if not M.in_repo(dir) then
      return nil
    end
    return untracked_hunks(dir, file, ref)
  end
  local args = { 'diff', '-U0', '--no-color', '--no-ext-diff' }
  if ref then
    table.insert(args, ref)
  end
  vim.list_extend(args, { '--', file })
  local res = M.run(dir, args)
  if res.code ~= 0 then
    -- Outside a repository `git diff` falls back to --no-index and prints
    -- its usage text, so ask before reporting anything.
    if not M.in_repo(dir) then
      return nil
    end
    if ref == 'HEAD' and not M.has_head(dir) then
      return { { start = 1, count = #vim.fn.readfile(file), removed = {} } }
    end
    error('git diff failed: ' .. M.first_line(res.stderr), 0)
  end

  -- Against the index, an untracked file has no diff output, but every
  -- line is new.
  if res.stdout == '' and not M.is_tracked(dir, file) then
    return { { start = 1, count = #vim.fn.readfile(file), removed = {} } }
  end
  return M.parse_hunks(res.stdout)
end

-- Where a hunk's deleted lines are shown. It depends on what replaced them:
--   lines changed (count > 0): above the new lines
--   pure deletion at the top (start 0): above the first line
--   pure deletion elsewhere: git gives the line *before* the gap, so below it
-- Returns a 0-based row and whether the lines go above it.
function M.removed_anchor(h, last)
  local row, above
  if h.count > 0 then
    row, above = h.start - 1, true
  elseif h.start == 0 then
    row, above = 0, true
  else
    row, above = h.start - 1, false
  end
  return math.min(row, last - 1), above
end

--- Changed lines vs the index (what is still unstaged), as a set of line
--- numbers. A deletion is entered under the line it is shown on. Second
--- result: the set of shown deletions, keyed "<row>a" or "<row>b". Third:
--- whether a pure deletion above line 1 is pending, which gitsigns cannot
--- stage by line range.
function M.unstaged_set(index_hunks, last)
  local lines, removed, top_deletion = {}, {}, false
  for _, h in ipairs(index_hunks) do
    for line = h.start, h.start + h.count - 1 do
      lines[line] = true
    end
    if #h.removed > 0 then
      local row, above = M.removed_anchor(h, last)
      removed[row .. (above and 'a' or 'b')] = true
      lines[row + 1] = true
      if h.start == 0 then
        top_deletion = true
      end
    end
  end
  return lines, removed, top_deletion
end

return M

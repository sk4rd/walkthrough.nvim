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

-- vim.text.diff exists from Neovim 0.12; vim.diff before that.
local text_diff = (vim.text and vim.text.diff) or vim.diff

local function as_text(lines)
  return #lines == 0 and '' or (table.concat(lines, '\n') .. '\n')
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

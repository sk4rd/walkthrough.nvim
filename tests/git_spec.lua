-- git.lua against real repositories: no optional locks (T-12), no HEAD and
-- no repository (T-10).
local H = require('helpers')
local check = H.check
local git = require('walkthrough.git')
local w = H.w

-- T-12: every read-only call passes --no-optional-locks ----------------------------
local repo = H.repo({ ['a.txt'] = { '1', '2', '3' } }, { ['a.txt'] = { '1', 'two', '3' }, ['u.txt'] = { 'u' } })
local trace = vim.fn.tempname()
vim.env.GIT_TRACE2_EVENT = trace
git.hunks(repo .. '/a.txt', nil)
git.hunks(repo .. '/a.txt', 'HEAD')
git.hunks(repo .. '/u.txt', nil)
H.send('load', { file = repo .. '/a.txt', diff = true, hunks = { { from = 2 } } })
vim.env.GIT_TRACE2_EVENT = nil
local seen, bare = 0, {}
for _, line in ipairs(vim.fn.readfile(trace)) do
  local ok, ev = pcall(vim.json.decode, line)
  if ok and ev.event == 'start' and ev.argv and ev.argv[2] ~= 'maintenance' and ev.argv[2] ~= '--version' then
    seen = seen + 1
    if not vim.tbl_contains(ev.argv, '--no-optional-locks') then
      table.insert(bare, table.concat(ev.argv, ' '))
    end
  end
end
check('T-12: git was traced', seen >= 5, seen)
check('T-12: all reads pass --no-optional-locks', #bare == 0, table.concat(bare, '; '))

-- hunks() ------------------------------------------------------------------------------
local hunks = git.hunks(repo .. '/a.txt', nil)
check('hunks: changed line', #hunks == 1 and hunks[1].start == 2 and hunks[1].count == 1 and hunks[1].removed[1] == '2')
hunks = git.hunks(repo .. '/u.txt', 'HEAD')
check('hunks: untracked file is all new', #hunks == 1 and hunks[1].start == 1 and hunks[1].count == 1)

-- T-10 -----------------------------------------------------------------------------------
local plain = vim.fn.tempname()
vim.fn.writefile({ 'x' }, plain)
check('hunks: nil outside a repository', git.hunks(plain, nil) == nil and git.hunks(plain, 'HEAD') == nil and git.hunks(plain, 'main') == nil)

local fresh = H.repo(nil, { ['n.txt'] = { 'a', 'b' } })
hunks = git.hunks(fresh .. '/n.txt', 'HEAD')
check('hunks: no commits means every line is new', #hunks == 1 and hunks[1].start == 1 and hunks[1].count == 2)
check('hunks: no commits, index diff of an untracked file', #git.hunks(fresh .. '/n.txt', nil) == 1)

local ok, err = pcall(git.hunks, repo .. '/a.txt', 'no-such-ref')
check('hunks: bad ref is one line without a path', not ok and not err:match('\n') and err:match('^git diff failed: ') ~= nil
  and not err:match('lua/walkthrough'), err)
check('first_line of git usage text', git.first_line('usage: git diff --no-index\n\n    --cached\n') == 'usage: git diff --no-index')

-- unstaged_set --------------------------------------------------------------------------
local lines, removed, top = git.unstaged_set({ { start = 0, count = 0, removed = { 'x' } }, { start = 5, count = 2, removed = {} } }, 10)
check('unstaged_set: lines, top deletion', lines[1] and lines[5] and lines[6] and top and removed['0a'], vim.inspect({ lines, removed, top }))
_, _, top = git.unstaged_set({ { start = 4, count = 0, removed = { 'x' } } }, 10)
check('unstaged_set: inner deletion is not a top deletion', not top)


-- parse_diff -----------------------------------------------------------------------------
local function lines_of(h)
  return vim.tbl_map(function(l)
    return ('%s%s@%s/%s'):format(l.kind, l.text, tostring(l.old), tostring(l.new))
  end, h.lines)
end
local function hdr(h)
  return table.concat({ h.old_start, h.old_count, h.new_start, h.new_count }, ',')
end

local d = git.parse_diff(table.concat({
  'diff --git a/f.txt b/f.txt', 'index 1111111..2222222 100644', '--- a/f.txt', '+++ b/f.txt',
  '@@ -2,3 +2,3 @@ function', ' a', '-b', '+B', ' c', '',
}, '\n'))
check('parse_diff: a replacement', vim.deep_equal(vim.tbl_keys(d), { 'f.txt' }) and #d['f.txt'].hunks == 1
  and hdr(d['f.txt'].hunks[1]) == '2,3,2,3'
  and vim.deep_equal(lines_of(d['f.txt'].hunks[1]), { ' a@2/2', '-b@3/nil', '+B@nil/3', ' c@4/4' }), vim.inspect(d))
check('parse_diff: not binary, not new', not d['f.txt'].binary and not d['f.txt'].new)

d = git.parse_diff(table.concat({
  'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt', '@@ -2,0 +3,2 @@', '+x', '+y', '',
}, '\n'))
check('parse_diff: a pure addition', hdr(d['f.txt'].hunks[1]) == '2,0,3,2'
  and vim.deep_equal(lines_of(d['f.txt'].hunks[1]), { '+x@nil/3', '+y@nil/4' }), vim.inspect(d))

d = git.parse_diff(table.concat({
  'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt', '@@ -3,2 +2,0 @@', '-c', '-d', '',
}, '\n'))
check('parse_diff: a pure deletion', hdr(d['f.txt'].hunks[1]) == '3,2,2,0'
  and vim.deep_equal(lines_of(d['f.txt'].hunks[1]), { '-c@3/nil', '-d@4/nil' }), vim.inspect(d))

d = git.parse_diff(table.concat({
  'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt',
  '@@ -1,2 +1,2 @@', '-a', '+A', ' b',
  '@@ -20,2 +20,3 @@ x', ' t', '+u', ' v', '',
}, '\n'))
check('parse_diff: several hunks', #d['f.txt'].hunks == 2 and hdr(d['f.txt'].hunks[2]) == '20,2,20,3'
  and vim.deep_equal(lines_of(d['f.txt'].hunks[2]), { ' t@20/20', '+u@nil/21', ' v@21/22' }), vim.inspect(d))

d = git.parse_diff(table.concat({
  'diff --git a/a.txt b/a.txt', '--- a/a.txt', '+++ b/a.txt', '@@ -1 +1 @@', '-1', '+one',
  'diff --git a/dir/b c.txt b/dir/b c.txt', '--- a/dir/b c.txt\t', '+++ b/dir/b c.txt\t', '@@ -5 +5 @@', '-5', '+five', '',
}, '\n'))
check('parse_diff: two files, a name with a space', d['a.txt'] and d['dir/b c.txt'] and hdr(d['a.txt'].hunks[1]) == '1,1,1,1'
  and d['dir/b c.txt'].hunks[1].lines[2].text == 'five', vim.inspect(vim.tbl_keys(d)))

d = git.parse_diff(table.concat({
  'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt', '@@ -1 +1 @@', '-a', '\\ No newline at end of file', '+b',
  '\\ No newline at end of file', '',
}, '\n'))
local nl = d['f.txt'].hunks[1].lines
check('parse_diff: no newline at end of file', #nl == 2 and nl[1].noeol and nl[2].noeol and nl[1].text == 'a' and nl[2].text == 'b',
  vim.inspect(nl))
d = git.parse_diff(table.concat({
  'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt', '@@ -1,2 +1,2 @@', ' a', '-b', '+c', '\\ No newline at end of file', '',
}, '\n'))
nl = d['f.txt'].hunks[1].lines
check('parse_diff: the marker belongs to the line before it only', #nl == 3 and not nl[1].noeol and not nl[2].noeol and nl[3].noeol)

d = git.parse_diff(table.concat({
  'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt', '@@ -1,2 +1,1 @@', ' a', '--- x', 'diff --git a/z b/z', '',
}, '\n'))
check('parse_diff: a removed line that looks like a header stays a line', #d['f.txt'].hunks[1].lines == 2
  and d['f.txt'].hunks[1].lines[2].text == '-- x' and d['f.txt'].hunks[1].lines[2].kind == '-', vim.inspect(d))

d = git.parse_diff(table.concat({
  'diff --git a/old.txt b/new.txt', 'similarity index 80%', 'rename from old.txt', 'rename to new.txt', 'index 1..2 100644',
  '--- a/old.txt', '+++ b/new.txt', '@@ -1,2 +1,2 @@', ' x', '-y', '+z', '',
}, '\n'))
check('parse_diff: a rename is shown as its new path', d['old.txt'] == nil and d['new.txt'] ~= nil
  and d['new.txt'].renamed_from == 'old.txt' and #d['new.txt'].hunks == 1, vim.inspect(vim.tbl_keys(d)))
d = git.parse_diff(table.concat({
  'diff --git a/old.txt b/new.txt', 'similarity index 100%', 'rename from old.txt', 'rename to new.txt', '',
}, '\n'))
check('parse_diff: a pure rename has no hunks', d['new.txt'] and #d['new.txt'].hunks == 0)

d = git.parse_diff(table.concat({
  'diff --git a/img.png b/img.png', 'index 1..2 100644', 'Binary files a/img.png and b/img.png differ',
  'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt', '@@ -1 +1 @@', '-a', '+b', '',
}, '\n'))
check('parse_diff: a binary file has no hunks and is flagged', d['img.png'] and d['img.png'].binary and #d['img.png'].hunks == 0
  and d['f.txt'] and not d['f.txt'].binary and #d['f.txt'].hunks == 1, vim.inspect(d))

d = git.parse_diff(table.concat({
  'diff --git a/n.txt b/n.txt', 'new file mode 100644', 'index 0000000..1111111', '--- /dev/null', '+++ b/n.txt',
  '@@ -0,0 +1,2 @@', '+a', '+b', '',
}, '\n'))
check('parse_diff: a new file', d['n.txt'] and d['n.txt'].new and hdr(d['n.txt'].hunks[1]) == '0,0,1,2'
  and vim.deep_equal(lines_of(d['n.txt'].hunks[1]), { '+a@nil/1', '+b@nil/2' }), vim.inspect(d))
d = git.parse_diff(table.concat({
  'diff --git a/gone.txt b/gone.txt', 'deleted file mode 100644', '--- a/gone.txt', '+++ /dev/null', '@@ -1 +0,0 @@', '-bye', '',
}, '\n'))
check('parse_diff: a deleted file is keyed by its old path', d['gone.txt'] and d['gone.txt'].deleted
  and d['gone.txt'].hunks[1].lines[1].old == 1, vim.inspect(d))
check('parse_diff: empty input', vim.deep_equal(git.parse_diff(''), {}) and vim.deep_equal(git.parse_diff(nil), {})
  and vim.deep_equal(git.parse_diff('\n'), {}))
check('parse_diff: parse_hunks still works', #git.parse_hunks('@@ -1 +1,2 @@\n-a\n+b\n+c\n') == 1)

-- runs: the changes of a hunk with context, in the shape of `git diff -U0`.
d = git.parse_diff(table.concat({
  'diff --git a/f.txt b/f.txt', '--- a/f.txt', '+++ b/f.txt', '@@ -1,11 +1,8 @@',
  '-a', ' b', ' c', '-d', '-e', '+D', ' f', ' g', ' h', ' i', '-j', ' k', '',
}, '\n'))
local runs, of = git.runs(d['f.txt'].hunks)
check('runs: a deletion at the top, a replacement, a deletion inside', #runs == 3
  and runs[1].start == 0 and runs[1].count == 0 and runs[1].removed[1] == 'a'
  and runs[2].start == 3 and runs[2].count == 1 and vim.deep_equal(runs[2].removed, { 'd', 'e' })
  and runs[3].start == 7 and runs[3].count == 0 and runs[3].removed[1] == 'j', vim.inspect(runs))
check('runs: every changed line knows its run', of[d['f.txt'].hunks[1].lines[1]] == runs[1]
  and of[d['f.txt'].hunks[1].lines[6]] == runs[2])

-- parse_diff against real git output: every line is where it says it is.
local lines30 = {}
for i = 1, 30 do
  lines30[i] = 'l' .. i
end
local edited30 = vim.deepcopy(lines30)
edited30[3] = 'X3'
table.remove(edited30, 10)
table.insert(edited30, 15, 'inserted')
edited30[#edited30] = 'last'
local real = H.repo({ ['f.txt'] = lines30, ['gone.txt'] = { 'g' }, ['old name.txt'] = { 'o1', 'o2', 'o3', 'o4', 'o5', 'o6' } },
  { ['f.txt'] = edited30 })
vim.fn.writefile({ 'n1', 'n2' }, real .. '/added.txt')
H.git_in(real, 'add', 'added.txt')
local out = vim.fn.system({ 'git', '-C', real, 'diff', '-U3', '--no-color', 'HEAD', '--' })
d = git.parse_diff(out)
local ok_lines = d['f.txt'] ~= nil and #d['f.txt'].hunks >= 2
for _, h in ipairs(d['f.txt'] and d['f.txt'].hunks or {}) do
  for _, l in ipairs(h.lines) do
    if l.new and edited30[l.new] ~= l.text then
      ok_lines = false
    end
    if l.old and lines30[l.old] ~= l.text then
      ok_lines = false
    end
  end
end
check('parse_diff: line numbers of real git output match both files', ok_lines, out)
check('parse_diff: real new file', d['added.txt'] and d['added.txt'].new and #d['added.txt'].hunks == 1)

w.close()
H.finish()

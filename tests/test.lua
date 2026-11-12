-- Regression suite, run by tests/run.sh inside a throwaway git repository.

local work = vim.env.WORK
local results, failed = {}, 0

local function check(name, ok, info)
  if not ok then
    failed = failed + 1
  end
  table.insert(results, (ok and 'PASS ' or 'FAIL ') .. name .. (info and not ok and (' (' .. tostring(info) .. ')') or ''))
end

local function skip(name)
  table.insert(results, 'SKIP ' .. name)
end

local function git(...)
  return vim.trim(vim.fn.system({ 'git', '-C', work, ... }))
end

local w = require('walkthrough')
local function send(fn, t)
  local p = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(t) }, p)
  return w[fn](p)
end

local ns = vim.api.nvim_get_namespaces().walkthrough
local function marks(pred)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    if pred(m[4]) then
      n = n + 1
    end
  end
  return n
end
local function sign(d, s)
  return d.sign_text and vim.trim(d.sign_text) == s
end

local hunks = { { from = 2, to = 3, group = 'A' }, { from = 4, to = 4, group = 'B' }, { from = 9, to = 9, group = 'A' } }
local tour = {
  group = 'A',
  steps = {
    {
      file = work .. '/f.txt',
      title = 'one',
      from = 2,
      to = 3,
      hunks = hunks,
      notes = { { line = 2, text = 'n1', verdict = 'simplify' }, { line = 8, text = 'n2' } },
      panel = '# One',
    },
    { file = work .. '/g.txt', title = 'two' },
    { file = work .. '/new.txt', title = 'three', hunks = { { from = 1, to = 2, group = 'A' } } },
  },
}

-- Loading and the overlay ------------------------------------------------------
check('load tour', send('load', tour) == 'ok')
check('status', vim.json.decode(w.status()).step == 1)
check('error: missing file', send('load', { file = work .. '/nope' }):match('^error: .*cannot read file') ~= nil)
check('error: bad json', w.load((function()
  local p = vim.fn.tempname()
  vim.fn.writefile({ '{nope' }, p)
  return p
end)()):match('^error:') ~= nil)
check('reviewed group green', marks(function(d)
  return d.line_hl_group == 'WalkthroughAdded'
end) == 2)
check('other group dimmed', marks(function(d)
  return sign(d, '·')
end) == 1)
check('unassigned flagged', marks(function(d)
  return sign(d, '?')
end) == 1)
check('mixed hunk warning', marks(function(d)
  return d.virt_text and d.virt_text[1][1]:match('mixed') ~= nil
end) == 1)
check('focus bar', marks(function(d)
  return sign(d, '▎')
end) >= 1)

-- Navigation and patches -------------------------------------------------------
vim.api.nvim_win_set_cursor(0, { 1, 0 })
w.note(1)
check(']n first note', vim.api.nvim_win_get_cursor(0)[1] == 2)
w.note(1)
check(']n second note', vim.api.nvim_win_get_cursor(0)[1] == 8)
check('patch note', send('patch', { note = 1, verdict = 'done', text = 'renamed' }) == 'ok')
check('patch shows DONE', marks(function(d)
  return d.virt_text and vim.iter(d.virt_text):any(function(c)
    return c[1]:match('DONE') ~= nil
  end)
end) == 1)
check('patch keeps cursor', vim.api.nvim_win_get_cursor(0)[1] == 8)
check('patch rejects typo', send('patch', { titel = 'x' }):match('unknown step field') ~= nil)

-- Reload survival --------------------------------------------------------------
package.loaded.walkthrough = nil
w = require('walkthrough')
check('reload keeps tour', vim.json.decode(w.status()).step == 1)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
w.note(1)
check(']n after reload', vim.api.nvim_win_get_cursor(0)[1] == 2)
w.step(1)
check(']w after reload', vim.fn.expand('%:t') == 'g.txt')
w.step(-1)

-- Staging with gitsigns ----------------------------------------------------------
local has_gitsigns, gitsigns = pcall(require, 'gitsigns')
if has_gitsigns then
  gitsigns.setup()
  local function attached(buf)
    return vim.wait(5000, function()
      return vim.b[buf].gitsigns_status_dict ~= nil
    end)
  end
  local function staged(f, want)
    vim.wait(5000, function()
      return git('diff', '--cached', '--numstat', '--', f):match(want) ~= nil
    end)
    return git('diff', '--cached', '--numstat', '--', f)
  end

  vim.cmd('edit!')
  attached(vim.api.nvim_get_current_buf())
  vim.wait(300)
  w.stage_group()
  check('<leader>gw stages only group A', staged('f.txt', '^2%s+3'):match('^2%s+3') ~= nil, staged('f.txt', '.'))
  w.stage_group()
  vim.wait(500)
  check('second <leader>gw does not unstage', git('diff', '--cached', '--numstat', '--', 'f.txt'):match('^2%s+3') ~= nil)

  w.step(2)
  vim.wait(500)
  w.stage_group()
  check('untracked file staged via git add -N', staged('new.txt', '^2'):match('^2') ~= nil, git('status', '--short'))
else
  skip('staging tests (gitsigns.nvim not on the packpath)')
end

w.close()
check('close', vim.json.decode(w.status()).step == 0)

-- Layout ---------------------------------------------------------------------
-- A new tab with only a scratch window stands in for the Claude terminal.
local function layout(opts)
  w.close()
  w.setup(opts)
  vim.cmd('tabnew')
  vim.bo.buftype = 'nofile'
  local claude = vim.api.nvim_get_current_win()
  send('load', { file = work .. '/g.txt', panel = '# x' })
  local cols = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    local name = win == claude and 'claude' or (vim.bo[b].filetype == 'markdown' and 'panel' or 'code')
    table.insert(cols, { name = name, col = vim.api.nvim_win_get_position(win)[2] })
  end
  table.sort(cols, function(a, b) return a.col < b.col end)
  vim.api.nvim_set_current_win(claude)
  return table.concat(vim.tbl_map(function(c) return c.name end, cols), ' | ')
end
local order = layout({ panel_side = 'left' })
check('default layout: claude | panel | code', order == 'claude | panel | code', order)
order = layout({ panel_side = 'right' })
check('panel_side right: code | panel | claude', order == 'code | panel | claude', order)
check('setup rejects bad side', not pcall(w.setup, { panel_side = 'up' }))
w.setup({ panel_side = 'left' })
w.close()

-- Minimum code width ---------------------------------------------------------
vim.o.columns = 200
vim.cmd('tabnew')
vim.bo.buftype = 'nofile'
local claude = vim.api.nvim_get_current_win()
send('load', { file = work .. '/g.txt', panel = '# x' })
vim.api.nvim_win_set_width(claude, 60)
w.keep_code_wide()
local function widths()
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    local name = win == claude and 'claude' or (vim.bo[b].filetype == 'markdown' and 'panel' or 'code')
    out[name] = vim.api.nvim_win_get_width(win)
  end
  return out
end
local wd = widths()
check('code at least half the screen', wd.code >= 100, vim.inspect(wd))
check('panel keeps its minimum', wd.panel >= 30, vim.inspect(wd))
-- Widen Claude's window: the resize event must win the space back for the code.
vim.api.nvim_win_set_width(claude, 150)
-- A headless script run never fires WinResized (a running Neovim does), so
-- fire it here; this still goes through the plugin's own handler.
vim.api.nvim_exec_autocmds('WinResized', {})
vim.wait(300, function() return widths().code >= 100 end)
wd = widths()
check('code stays half after a resize', wd.code >= 100, vim.inspect(wd))
check('panel minimum after a resize', wd.panel >= 30, vim.inspect(wd))
check('setup rejects bad ratio', not pcall(w.setup, { code_min_ratio = 1.5 }))
w.close()

print(table.concat(results, '\n'))
print(('%d failed'):format(failed))
vim.cmd(failed > 0 and ('cquit ' .. failed) or 'qall!')

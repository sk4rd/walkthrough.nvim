-- Shared by tests/test.lua and tests/*_spec.lua. Each file runs in its own
-- Neovim, in a fresh fixture repository (tests/run.sh), whose path is $WORK.
local H = {}

H.work = vim.env.WORK
H.results, H.failed = {}, 0

function H.check(name, ok, info)
  if not ok then
    H.failed = H.failed + 1
  end
  table.insert(H.results, (ok and 'PASS ' or 'FAIL ') .. name .. (info and not ok and (' (' .. tostring(info) .. ')') or ''))
end

function H.skip(name)
  table.insert(H.results, 'SKIP ' .. name)
end

--- Print the results and leave Neovim. The DONE line tells tests/run.sh the
--- file ran to its end.
function H.finish()
  print('\n' .. table.concat(H.results, '\n'))
  print('DONE')
  vim.cmd(H.failed > 0 and ('cquit ' .. H.failed) or 'qall!')
end

--- Run git in `dir` (default: the fixture). Returns trimmed output.
function H.git(...)
  return vim.trim(vim.fn.system({ 'git', '-C', H.work, ... }))
end

function H.git_in(dir, ...)
  return vim.trim(vim.fn.system({ 'git', '-C', dir, '-c', 'user.email=t@example.com', '-c', 'user.name=t', ... }))
end

--- A new repository outside the fixture. `base` maps file name to lines and
--- is committed (nothing is committed when it is nil); `work` maps file name
--- to the lines the working tree gets afterwards.
function H.repo(base, work)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  H.git_in(dir, 'init', '-q')
  if base then
    for name, lines in pairs(base) do
      vim.fn.mkdir(vim.fs.dirname(dir .. '/' .. name), 'p')
      vim.fn.writefile(lines, dir .. '/' .. name)
      H.git_in(dir, 'add', name)
    end
    H.git_in(dir, 'commit', '-qm', 'base')
  end
  for name, lines in pairs(work or {}) do
    vim.fn.writefile(lines, dir .. '/' .. name)
  end
  return dir
end

local w = require('walkthrough')
H.w = w

--- Write `t` as JSON to a temp file and pass the path to walkthrough[fn].
function H.send(fn, t)
  local p = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(t) }, p)
  return w[fn](p)
end

H.ns = vim.api.nvim_get_namespaces().walkthrough

--- Count extmarks of the plugin in `buf` (default current) whose details match.
function H.marks(pred, buf)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf or 0, H.ns, 0, -1, { details = true })) do
    if pred(m[4], m) then
      n = n + 1
    end
  end
  return n
end

function H.sign(d, s)
  return d.sign_text and vim.trim(d.sign_text) == s
end

--- Marks as { line, details } for the lines they sit on.
function H.marks_at(line, buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf or 0, H.ns, { line - 1, 0 }, { line - 1, -1 }, { details = true })) do
    table.insert(out, m[4])
  end
  return out
end

function H.panel_text()
  local st = _G.walkthrough_state
  if not (st.panel_buf and vim.api.nvim_buf_is_valid(st.panel_buf)) then
    return ''
  end
  return table.concat(vim.api.nvim_buf_get_lines(st.panel_buf, 0, -1, false), '\n')
end

function H.panel_winbar()
  local st = _G.walkthrough_state
  if st.panel_win and vim.api.nvim_win_is_valid(st.panel_win) then
    return vim.wo[st.panel_win].winbar
  end
  return ''
end

--- Capture vim.notify. Returns the list of { msg, level } and a function that
--- finds the first message matching a Lua pattern.
function H.capture_notify()
  local log = {}
  vim.notify = function(msg, level)
    table.insert(log, { msg = msg, level = level })
  end
  local function find(pattern)
    for _, n in ipairs(log) do
      if n.msg:match(pattern) then
        return n
      end
    end
  end
  return log, find
end

--- Wait until a notification matching `pattern` arrives; returns it.
function H.wait_notify(find, pattern)
  vim.wait(5000, function()
    return find(pattern) ~= nil
  end, 20)
  return find(pattern)
end

--- gitsigns when it is installed (set up once), else nil.
function H.gitsigns()
  local ok, gs = pcall(require, 'gitsigns')
  if not ok then
    return nil
  end
  if not H.gitsigns_ready then
    gs.setup()
    H.gitsigns_ready = true
  end
  return gs
end

--- Reload the current buffer and wait until gitsigns is attached to it.
function H.attach()
  vim.cmd('edit!')
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(5000, function()
    return vim.b[buf].gitsigns_status_dict ~= nil
  end, 20)
  vim.wait(300)
end

--- Wait for `fn` to return truthy.
function H.wait(fn)
  return vim.wait(5000, fn, 20)
end

--- The text of one virtual line: all its chunks, as it reads on screen.
function H.vtext(vl)
  local out = {}
  for _, chunk in ipairs(vl or {}) do
    table.insert(out, chunk[1])
  end
  return table.concat(out)
end

return H

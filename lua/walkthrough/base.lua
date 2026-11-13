-- The base version of the current step's file in a read-only float, to see
-- the code as it was before the change.
local st = require('walkthrough.state')
local git = require('walkthrough.git')
local anchor = require('walkthrough.anchor')
local tour = require('walkthrough.tour')

local M = {}

--- The ref the step's change is measured against: the step's own ref, else HEAD.
function M.ref_of(step)
  return type(step.diff) == 'string' and step.diff or 'HEAD'
end

--- The lines of the step's file at `ref`. Returns them, or nil and why: a
--- file that does not exist there is `missing = true`.
function M.base_lines(step, ref)
  local abs = vim.fn.fnamemodify(step.file, ':p')
  local dir = vim.fs.dirname(abs)
  if not git.in_repo(dir) then
    return nil, 'this file is not in a git repository'
  end
  if not git.has_head(dir) and ref == 'HEAD' then
    return nil, 'the repository has no commit yet', true
  end
  local prefix = git.run(dir, { 'rev-parse', '--show-prefix' })
  local path = vim.trim(prefix.stdout or '') .. vim.fs.basename(abs)
  local res = git.run(dir, { 'show', ref .. ':' .. path })
  if res.code ~= 0 then
    local why = git.first_line(res.stderr)
    local missing = why:match('exists on disk, but not in') or why:match('does not exist in')
    return nil, missing and ('%s does not exist at %s'):format(vim.fn.fnamemodify(step.file, ':~:.'), ref) or why,
      missing ~= nil
  end
  local lines = vim.split(res.stdout, '\n', { plain = true })
  if lines[#lines] == '' then
    table.remove(lines)
  end
  return lines
end

--- Open the base version of the current step's file in a centered float, on
--- the line that corresponds to the start of the step's focus. `q` and
--- `<Esc>` close it.
function M.show()
  local step = st.history[st.pos]
  if not step then
    vim.notify('walkthrough: no tour open', vim.log.levels.INFO)
    return
  end
  local ref = M.ref_of(step)
  local lines, why, missing = M.base_lines(step, ref)
  if not lines then
    vim.notify('walkthrough: ' .. why, missing and vim.log.levels.INFO or vim.log.levels.ERROR)
    return
  end

  -- The focus start, mapped from the file as it is to the base version.
  pcall(tour.sync, step)
  local target = 1
  if step.from then
    local hunks = anchor.diff(vim.fn.readfile(step.file), lines)
    target = (anchor.map_line(hunks, step.from))
  end
  target = math.max(1, math.min(target, math.max(#lines, 1)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ft = vim.filetype.match({ filename = step.file, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local width = math.max(40, math.floor(vim.o.columns * 0.8))
  local height = math.max(5, math.floor((vim.o.lines - vim.o.cmdheight) * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.min(width, vim.o.columns),
    height = math.min(height, vim.o.lines),
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = (' %s: %s '):format(ref, vim.fn.fnamemodify(step.file, ':~:.')),
    title_pos = 'center',
  })
  vim.wo[win].number = true
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.cmd('normal! zz')
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, desc = 'Close the base version' })
  end
  return win
end

return M

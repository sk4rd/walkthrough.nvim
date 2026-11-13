-- Where the user types what they write on the code (a question, a change
-- request, a reply, the free text of plan feedback): a small centered float
-- with an editable scratch buffer, instead of the command line at the bottom
-- of the screen, which is far from the code being talked about. The option
-- `input` = 'ui' hands the prompt to `vim.ui.input` instead, for those who
-- have an input UI of their own.
--
-- Keys: <CR> sends (insert and normal mode), <C-j> starts a new line in
-- insert mode, <Esc> in normal mode and q cancel. An empty text cancels, and
-- so does closing the window in any other way. The callback gets the text, or
-- nil when the prompt was cancelled, as with `vim.ui.input`.
local st = require('walkthrough.state')
local ui = require('walkthrough.ui')

local M = {}

-- The open prompt: { win, buf, cancel }. Only one at a time: opening another
-- cancels the first.
local current

local FOOTER = ' Enter send · Ctrl-j new line · Esc Esc or q cancel '
local MAX_WIDTH, MAX_HEIGHT = 70, 10

-- Window size and place for the text in `buf`: about 70 columns or 60 % of the
-- screen, whichever is smaller; as high as the wrapped text, up to a
-- sensible limit; in the middle of the screen, border included.
local function layout(buf, win)
  local width = math.max(10, math.min(MAX_WIDTH, math.floor(vim.o.columns * 0.6), vim.o.columns - 2))
  local room = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
  local limit = math.min(MAX_HEIGHT, room)
  local height = 0
  if win then
    -- The window must have its width first: the height depends on wrapping.
    vim.api.nvim_win_set_width(win, width)
    local ok, res = pcall(vim.api.nvim_win_text_height, win, {})
    height = ok and res.all or 0
  end
  if height == 0 then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
    end
  end
  height = math.max(1, math.min(height, limit))
  return {
    relative = 'editor', width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - (height + 2)) / 2)),
    col = math.max(0, math.floor((vim.o.columns - (width + 2)) / 2)),
  }
end

local function text_of(buf)
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
end

--- Ask for a text. `opts.title` names what is written and where
--- (`Question on backup.sh:7`); `opts.prompt` is the line `vim.ui.input` gets
--- when the option `input` is 'ui' (default: the title and a colon);
--- `opts.default` is a text to start from. `callback(text)` runs once: with
--- the text, or with nil when the user cancelled. Never raises.
function M.ask(opts, callback)
  local run = ui.safe(callback)
  if st.config.input == 'ui' then
    local ok, err = pcall(vim.ui.input, { prompt = opts.prompt or (opts.title .. ': '), default = opts.default }, run)
    if not ok then
      vim.notify('walkthrough: ' .. require('walkthrough.tour').clean_error(err), vim.log.levels.ERROR)
    end
    return
  end

  if current then
    current.cancel()
  end
  -- Where the user was, to put them back: the window, the cursor in it and
  -- whether they were typing.
  local origin = {
    win = vim.api.nvim_get_current_win(),
    cursor = vim.api.nvim_win_get_cursor(0),
    typing = vim.api.nvim_get_mode().mode:match('^[iR]') ~= nil,
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  -- A name of its own lets users switch completion and the like off for it.
  vim.bo[buf].filetype = 'walkthrough_input'
  if opts.default and opts.default ~= '' then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.default, '\n', { plain = true }))
  end
  local config = layout(buf)
  config.style = 'minimal'
  config.border = 'rounded'
  config.title = ' ' .. opts.title .. ' '
  config.title_pos = 'center'
  config.footer = FOOTER
  config.footer_pos = 'center'
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true

  local done = false
  local group = vim.api.nvim_create_augroup('walkthrough_input_' .. win, { clear = true })

  local function restore()
    if vim.api.nvim_win_is_valid(origin.win) then
      pcall(vim.api.nvim_set_current_win, origin.win)
      pcall(vim.api.nvim_win_set_cursor, origin.win, origin.cursor)
    end
    if origin.typing then
      vim.cmd.startinsert()
    end
  end

  -- Close the prompt and hand over `text` (nil: cancelled).
  local function finish(text)
    if done then
      return
    end
    done = true
    if current and current.win == win then
      current = nil
    end
    pcall(vim.api.nvim_del_augroup_by_id, group)
    -- Closing a window leaves the mode as it is: leave insert mode first,
    -- or the code buffer would be left in it.
    vim.cmd.stopinsert()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    restore()
    if text ~= nil and text == '' then
      text = nil
    end
    run(text)
  end

  local function submit()
    finish(text_of(buf))
  end
  local function cancel()
    finish(nil)
  end

  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, desc = 'Walkthrough: ' .. desc })
  end
  map('n', '<CR>', submit, 'send the text')
  -- Leave Insert mode first and send from Normal mode: a send from inside
  -- Insert mode would end it in the window the focus went back to, and move
  -- the cursor there one column to the left.
  vim.keymap.set('i', '<CR>', '<Esc><CR>', { buffer = buf, remap = true, nowait = true, desc = 'Walkthrough: send the text' })
  -- The same key as in a terminal: a new line, not a send.
  vim.keymap.set('i', '<C-j>', '<CR>', { buffer = buf, remap = false, desc = 'Walkthrough: new line' })
  map('n', '<Esc>', cancel, 'cancel')
  map('n', 'q', cancel, 'cancel')

  -- The window grows with the text.
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, layout(buf, win))
      end
    end,
  })
  -- Closed any other way (:q, <C-w>c, ...): cancelled. The window is still
  -- open while this runs, so the rest waits until it is closed.
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      if done then
        return
      end
      done = true
      if current and current.win == win then
        current = nil
      end
      pcall(vim.api.nvim_del_augroup_by_id, group)
      vim.schedule(function()
        if vim.fn.mode():match('^[iR]') and not origin.typing then
          vim.cmd.stopinsert()
        end
        restore()
        run(nil)
      end)
    end,
  })

  current = { win = win, buf = buf, cancel = cancel }
  vim.cmd.startinsert({ bang = true })
end

--- The window of the open prompt, if any.
function M.win()
  return current and vim.api.nvim_win_is_valid(current.win) and current.win or nil
end

return M

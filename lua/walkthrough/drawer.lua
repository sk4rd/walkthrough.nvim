-- Threads wherever their file is shown. The code window's full draw (ui.draw)
-- draws the shown step with its notes, diff and threads; a thread on any
-- other file, or on another step of the same file, is drawn here, in a
-- namespace of its own, in every loaded buffer that has some. The look is the
-- same (ui.draw_thread). Marks belong to the buffer, so a second window on a
-- buffer shows them too.
--
-- Everything here runs from autocommands and after changes: it is cheap when
-- no tour is loaded, and never raises.
local st = require('walkthrough.state')
local tour = require('walkthrough.tour')
local tours = require('walkthrough.tours')
local ui = require('walkthrough.ui')

local M = {}

local ns = vim.api.nvim_create_namespace('walkthrough_threads')
M.ns = ns

-- A loaded buffer of a normal file.
local function is_file(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == ''
    and vim.api.nvim_buf_get_name(buf) ~= ''
end

-- The step whose threads the full draw put in `buf`, which are not drawn here.
local function covered(buf)
  local d = st.drawn
  return d and d.buf == buf and d.step or nil
end

-- Draw the threads of the buffer again, or remove them. A buffer with unsaved
-- changes keeps its marks: stored positions are those of the saved file, and
-- the marks already there follow the edits.
local function redraw_buf(buf, index)
  if not is_file(buf) or vim.bo[buf].modified then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local list = index[tours.index_key(vim.api.nvim_buf_get_name(buf))]
  if not list then
    return
  end
  local skip = covered(buf)
  for _, e in ipairs(list) do
    if e.step ~= skip then
      -- Numbers first follow the edits made since they were written.
      pcall(tour.sync, e.step)
      for _, th in ipairs(e.step.threads) do
        pcall(ui.draw_thread, buf, th, ns)
      end
    end
  end
end

--- Draw the threads of one buffer (an event about it), or of all of them.
function M.redraw(buf)
  pcall(function()
    local index = tours.threaded_index()
    if buf then
      redraw_buf(buf, index)
      return
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      redraw_buf(b, index)
    end
  end)
end

--- Remove every mark of the drawer, from all buffers.
function M.clear()
  pcall(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
      end
    end
  end)
end

--- The autocommand callback for an event about `ev.buf`: only for a normal
--- file and only while tours are loaded.
function M.on_event(ev)
  if #st.tours == 0 or not ev.buf then
    return
  end
  M.redraw(ev.buf)
end

return M

-- Several tours at once (P-3, U-1), `seen` (U-4) and the status fields.
local H = require('helpers')
local check, send, w = H.check, H.send, H.w
local st = _G.walkthrough_state
local log, find = H.capture_notify()
local function status()
  return vim.json.decode(w.status())
end
local function reset_log()
  for i = #log, 1, -1 do
    log[i] = nil
  end
end
local f, g, new = H.work .. '/f.txt', H.work .. '/g.txt', H.work .. '/new.txt'
local function names()
  return vim.tbl_map(function(t)
    return t.group or '(unnamed)'
  end, st.tours)
end

-- Adding tours ---------------------------------------------------------------------
check('load A', send('load', { group = 'A', steps = { { file = f, title = 'a1' }, { file = g, title = 'a2' } } }) == 'ok')
local s = status()
check('status keeps its old fields', s.step == 1 and s.total == 2 and s.title == 'a1' and s.file == f and s.group == 'A')
check('status: seen counts the shown step', s.seen == 1)
check('status: groups lists the tour', #s.groups == 1 and s.groups[1].group == 'A' and s.groups[1].steps == 2
  and s.groups[1].seen == 1 and s.groups[1].current == true, vim.inspect(s.groups))

w.step(1)
check('step 2 is seen too', status().seen == 2)

check('load B', send('load', { group = 'B', steps = { { file = f, title = 'b1' }, { file = new, title = 'b2' }, { file = g, title = 'b3' } } }) == 'ok')
s = status()
check('a different group is added and becomes active', #s.groups == 2 and s.group == 'B' and s.total == 3 and s.step == 1)
check('groups: A is not current, B is', s.groups[1].group == 'A' and not s.groups[1].current and s.groups[2].current, vim.inspect(s.groups))
check('groups: counts per tour', s.groups[1].steps == 2 and s.groups[1].seen == 2 and s.groups[2].steps == 3 and s.groups[2].seen == 1)
check('st.history, st.pos, st.tour_group follow the active tour', st.history == st.tours[2].steps and st.pos == 1 and st.tour_group == 'B')

-- Switching ------------------------------------------------------------------------
w.step(1)
check('B is at step 2', status().step == 2 and vim.fn.expand('%:t') == 'new.txt')
w.group(-1)
s = status()
check('group(-1): back to A at its last position', s.group == 'A' and s.step == 2 and vim.fn.expand('%:t') == 'g.txt', vim.inspect(s))
check('... and A is the current one', st.tour_group == 'A' and st.pos == 2 and #st.history == 2)
w.group(1)
check('group(1): B again, where it was left', status().group == 'B' and status().step == 2)
w.group(1)
check('group(1) wraps around', status().group == 'A')
w.group('B')
check('group("B") selects by name', status().group == 'B')
w.group('prev')
check('group("prev")', status().group == 'A')
w.group('next')
check('group("next")', status().group == 'B')
reset_log()
w.group('Z')
check('group: unknown name is reported', find('no commit named "Z"') ~= nil)
check('group: ... and nothing changed', status().group == 'B')
reset_log()
w.group()
check('group(): lists the tours', log[1] and log[1].msg:match('A: entry 2/2') and log[1].msg:match('%* B: entry 2/3'), vim.inspect(log))
check('group: never raises', pcall(w.group, {}))

-- Patches and steps act on the active tour -----------------------------------------
check('patch goes to the active tour', send('patch', { step = 1, title = 'b1 renamed' }) == 'ok'
  and st.tours[2].steps[1].title == 'b1 renamed' and st.tours[1].steps[1].title == 'a1')
w.step(-1)
check('step moves within the active tour', status().step == 1 and status().group == 'B')

-- Replacing a tour -------------------------------------------------------------------
-- A's step 2 was seen; sending A again keeps that for steps with the same file
-- and title, and not for a step whose title changed or a new one.
check('replace A', send('load', { group = 'A', steps = {
  { file = f, title = 'a1' }, { file = g, title = 'a2' }, { file = g, title = 'a2 but different' }, { file = f, title = 'a4' },
} }) == 'ok')
s = status()
check('replace: still two tours, A first, now active', #s.groups == 2 and s.groups[1].group == 'A' and s.groups[1].current
  and s.groups[1].steps == 4, vim.inspect(s.groups))
local a = st.tours[1].steps
check('replace: seen is kept for the same file and title', a[1].seen == true and a[2].seen == true)
check('replace: ... and not for new or retitled steps', not a[3].seen and not a[4].seen)
check('replace: status counts them', s.seen == 2 and s.groups[1].seen == 2)
check('replace: B was left alone', st.tours[2].steps[1].title == 'b1 renamed' and #st.tours[2].steps == 3)

-- seen is internal --------------------------------------------------------------------
check('"seen" cannot come from JSON', send('load', { group = 'C', steps = { { file = f, seen = true } } }):match('unknown step field "seen"') ~= nil)
check('"seen" cannot be patched', send('patch', { seen = true }):match('unknown step field "seen"') ~= nil)

-- The unnamed tour ---------------------------------------------------------------------
check('load without group', send('load', { steps = { { file = f, title = 'u1' } } }) == 'ok')
check('... is its own tour', #st.tours == 3 and st.tours[3].group == nil and st.tour_group == nil, vim.inspect(names()))
check('another tour without group replaces the unnamed one', send('load', { steps = { { file = f, title = 'u1' }, { file = g, title = 'u2' } } }) == 'ok'
  and #st.tours == 3 and #st.tours[3].steps == 2, vim.inspect(names()))
check('unnamed: seen kept for the same step', st.tours[3].steps[1].seen == true)
check('status: the unnamed tour has no group key', (function()
  local ss = status()
  return ss.group == nil and ss.groups[3].group == nil and ss.groups[3].current == true
end)())
check('group lists it as (unnamed)', (function()
  reset_log()
  w.group()
  return log[1] and log[1].msg:match('%(unnamed%)') ~= nil
end)())

-- A lone step joins the active tour ---------------------------------------------------------
check('lone step', send('load', { file = new, title = 'u3' }) == 'ok')
check('... appended to the active tour only', #st.tours[3].steps == 3 and #st.tours[1].steps == 4 and st.pos == 3)
check('... and shown', status().step == 3 and status().seen == 2)

-- Reload of the module keeps all tours ----------------------------------------------------------
package.loaded.walkthrough = nil
w = require('walkthrough')
check('reload keeps every tour', #status().groups == 3 and status().group == nil and status().step == 3)
w.group('A')
check('... and switching still works', status().group == 'A')

-- close forgets them all; the status is as before ---------------------------------------------------
w.close()
check('close: status is {"step":0}', w.status() == '{"step":0}', w.status())
check('close: no tours in memory', #st.tours == 0 and st.history ~= nil and #st.history == 0 and st.pos == 0 and st.tour_group == nil)
reset_log()
w.group('A')
check('group with nothing loaded does not raise', find('no review open') ~= nil)
H.finish()

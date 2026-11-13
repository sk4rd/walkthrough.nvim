-- :Walkthrough and the <Plug> mappings. Sourcing this file loads nothing:
-- the module is required when a command or mapping runs. Safe to source
-- twice (commands are redefined, mappings set again).

local function wt()
  return require('walkthrough')
end

-- The user entry points report problems themselves; the socket-style ones
-- (resume, discard) answer "ok" or "error: ...", which becomes a notification.
local function report(result)
  if type(result) == 'string' and result:match('^error: ') then
    vim.notify('walkthrough: ' .. result:sub(8), vim.log.levels.ERROR)
  end
end

local function status()
  local ok, s = pcall(vim.json.decode, wt().status())
  if not ok or type(s) ~= 'table' then
    return vim.notify('walkthrough: status unavailable', vim.log.levels.ERROR)
  end
  if s.step == 0 then
    if s.groups then
      -- Only threads on files outside every review: no entry to report.
      return vim.notify(('walkthrough: no entry shown, %d commit%s loaded'):format(
        #s.groups, #s.groups == 1 and '' or 's'), vim.log.levels.INFO)
    end
    return vim.notify('walkthrough: no review open', vim.log.levels.INFO)
  end
  local line = ('walkthrough: entry %d/%d%s, seen %d, %d commit%s loaded, %s view'):format(
    s.step, s.total, s.group and (' of "' .. s.group .. '"') or '', s.seen or 0,
    #(s.groups or {}), #(s.groups or {}) == 1 and '' or 's', s.view or 'file')
  if s.stale then
    line = line .. (', %d stale'):format(#s.stale)
  end
  if s.map then
    line = line .. ', map requested'
  end
  vim.notify(line, vim.log.levels.INFO)
end

-- Record the working tree as refs/walkthrough/<name> (default "reviewed").
local function reviewed(name)
  local id = wt().snapshot(name)
  if id:match('^error: ') then
    return report(id)
  end
  vim.notify(('walkthrough: recorded refs/walkthrough/%s at %s'):format(name or 'reviewed', id:sub(1, 7)),
    vim.log.levels.INFO)
end

-- name -> function(arg, opts) ; `arg` is the rest of the command line and
-- `opts` the command's (its range).
local subcommands = {
  next = function() wt().step(1) end,
  prev = function() wt().step(-1) end,
  ['note-next'] = function() wt().note(1) end,
  ['note-prev'] = function() wt().note(-1) end,
  -- ask [text], change [text]: the lines are the command's range, else the cursor.
  ask = function(arg, o)
    wt().ask(arg ~= '' and arg or nil, o and o.range > 0 and { o.line1, o.line2 } or nil)
  end,
  change = function(arg, o)
    wt().change(arg ~= '' and arg or nil, o and o.range > 0 and { o.line1, o.line2 } or nil)
  end,
  thread = function() wt().thread() end,
  -- map: show the map panel, or hide it.
  map = function() wt().map() end,
  ['thread-delete'] = function() wt().thread_delete() end,
  stage = function(arg)
    if arg == 'all' then
      wt().stage_group({ all = true })
    elseif arg == '' then
      wt().stage_group()
    else
      vim.notify('walkthrough: stage takes no argument or "all"', vim.log.levels.ERROR)
    end
  end,
  close = function() report(wt().close()) end,
  status = status,
  group = function(arg) wt().group(arg ~= '' and arg or nil) end,
  resume = function() report(wt().resume()) end,
  -- review [ref]: the files that differ from ref (default HEAD), without an agent.
  review = function(arg) wt().review(arg ~= '' and arg or nil) end,
  -- request: ask the working session for the map of the change under review.
  request = function() wt().request() end,
  discard = function() report(wt().discard()) end,
  decide = function(arg)
    if arg ~= 'accept' and arg ~= 'reject' and arg ~= 'clear' then
      return vim.notify('walkthrough: decide takes accept, reject or clear', vim.log.levels.ERROR)
    end
    wt().decide(arg)
  end,
  send = function() wt().send() end,
  explain = function(arg)
    if arg ~= 'simpler' and arg ~= 'deeper' then
      return vim.notify('walkthrough: explain takes simpler or deeper', vim.log.levels.ERROR)
    end
    wt().explain(arg)
  end,
  reject = function() wt().reject_group() end,
  -- commit: check, message and commit what is staged.
  commit = function() wt().commit() end,
  base = function() wt().base() end,
  back = function() wt().step(0) end,
  -- view [compact|file]: switch between the compact view and the file.
  view = function(arg) wt().view(arg ~= '' and arg or nil) end,
  -- reviewed [name]: record the working tree as the point reviewed so far.
  reviewed = function(arg) reviewed(arg ~= '' and arg or nil) end,
  keys = function() wt().keys() end,
  -- plan [approve|feedback]: the agent's plan under review (see plan.lua).
  plan = function(arg)
    if arg == '' then
      wt().plan_show()
    elseif arg == 'approve' then
      wt().plan_approve()
    elseif arg == 'feedback' then
      wt().plan_feedback()
    else
      vim.notify('walkthrough: plan takes no argument, approve or feedback', vim.log.levels.ERROR)
    end
  end,
}
local names = vim.tbl_keys(subcommands)
table.sort(names)

vim.api.nvim_create_user_command('Walkthrough', function(o)
  local sub = o.fargs[1]
  local run = sub and subcommands[sub]
  if not run then
    vim.notify(('walkthrough: unknown subcommand "%s" (one of: %s)'):format(sub or '', table.concat(names, ' ')),
      vim.log.levels.ERROR)
    return
  end
  run(vim.trim(table.concat(o.fargs, ' ', 2)), o)
end, {
  nargs = '+',
  range = true,
  desc = 'Walkthrough: ' .. table.concat(names, ', '),
  complete = function(lead, line)
    local words = vim.split(vim.trim(line), '%s+')
    local typing_sub = #words == 1 or (#words == 2 and not line:match('%s$'))
    local pool = names
    if not typing_sub then
      pool = {}
      if words[2] == 'stage' then
        pool = { 'all' }
      elseif words[2] == 'decide' then
        pool = { 'accept', 'reject', 'clear' }
      elseif words[2] == 'view' then
        pool = { 'compact', 'file' }
      elseif words[2] == 'explain' then
        pool = { 'simpler', 'deeper' }
      elseif words[2] == 'plan' then
        pool = { 'approve', 'feedback' }
      elseif words[2] == 'group' then
        pool = { 'next', 'prev' }
        -- Read from the state table: completing must not load the module.
        for _, t in ipairs((_G.walkthrough_state or {}).tours or {}) do
          if t.group then
            table.insert(pool, t.group)
          end
        end
      end
    end
    return vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, pool)
  end,
})

-- One <Plug> mapping per action: name -> { function, modes }. Modes default
-- to normal. The ask and change mappings work on a selection too.
local function plug(fn, modes)
  return { fn, modes or { 'n' } }
end
local plugs = {
  next = plug(function() wt().step(1) end),
  prev = plug(function() wt().step(-1) end),
  back = plug(function() wt().step(0) end),
  view = plug(function() wt().view() end),
  ['note-next'] = plug(function() wt().note(1) end),
  ['note-prev'] = plug(function() wt().note(-1) end),
  ['group-next'] = plug(function() wt().group('next') end),
  ['group-prev'] = plug(function() wt().group('prev') end),
  ask = plug(function() wt().ask() end, { 'n', 'x' }),
  change = plug(function() wt().change() end, { 'n', 'x' }),
  thread = plug(function() wt().thread() end),
  map = plug(function() wt().map() end),
  ['thread-delete'] = plug(function() wt().thread_delete() end),
  send = plug(function() wt().send() end),
  accept = plug(function() wt().decide('accept') end),
  decline = plug(function() wt().decide('reject') end),
  undecide = plug(function() wt().decide('clear') end),
  simpler = plug(function() wt().explain('simpler') end),
  deeper = plug(function() wt().explain('deeper') end),
  stage = plug(function() wt().stage_group() end),
  ['stage-all'] = plug(function() wt().stage_group({ all = true }) end),
  reject = plug(function() wt().reject_group() end),
  commit = plug(function() wt().commit() end),
  base = plug(function() wt().base() end),
  reviewed = plug(function() reviewed() end),
  resume = plug(function() report(wt().resume()) end),
  review = plug(function() wt().review() end),
  request = plug(function() wt().request() end),
  close = plug(function() report(wt().close()) end),
  keys = plug(function() wt().keys() end),
  ['plan-feedback'] = plug(function() wt().plan_feedback() end),
  ['plan-approve'] = plug(function() wt().plan_approve() end),
}
for name, p in pairs(plugs) do
  vim.keymap.set(p[2], '<Plug>(walkthrough-' .. name .. ')', p[1], { desc = 'Walkthrough: ' .. name })
end

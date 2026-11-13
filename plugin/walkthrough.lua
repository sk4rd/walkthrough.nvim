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
    return vim.notify('walkthrough: no tour open', vim.log.levels.INFO)
  end
  local line = ('walkthrough: step %d/%d%s, seen %d, %d tour%s loaded'):format(
    s.step, s.total, s.group and (' of "' .. s.group .. '"') or '', s.seen or 0,
    #(s.groups or {}), #(s.groups or {}) == 1 and '' or 's')
  if s.stale then
    line = line .. (', %d stale'):format(#s.stale)
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

local comment_types = { 'question', 'issue', 'suggestion' }

-- name -> function(arg, opts) ; `arg` is the rest of the command line and
-- `opts` the command's (its range).
local subcommands = {
  next = function() wt().step(1) end,
  prev = function() wt().step(-1) end,
  ['note-next'] = function() wt().note(1) end,
  ['note-prev'] = function() wt().note(-1) end,
  ask = function() wt().ask_line() end,
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
  discard = function() report(wt().discard()) end,
  -- comment [type] [text]; the lines are the command's range, else the cursor.
  comment = function(arg, o)
    local first, rest = arg:match('^(%S+)%s*(.*)$')
    local ctype
    if first and vim.tbl_contains(comment_types, first) then
      ctype, arg = first, rest
    end
    wt().comment(ctype, arg ~= '' and arg or nil, o and o.range > 0 and { o.line1, o.line2 } or nil)
  end,
  ['comment-delete'] = function() wt().comment_delete() end,
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
  check = function(arg)
    if arg ~= 'reveal' and arg ~= 'answer' then
      return vim.notify('walkthrough: check takes reveal or answer', vim.log.levels.ERROR)
    end
    wt().check(arg)
  end,
  reject = function() wt().reject_group() end,
  base = function() wt().base() end,
  back = function() wt().step(0) end,
  -- reviewed [name]: record the working tree as the point reviewed so far.
  reviewed = function(arg) reviewed(arg ~= '' and arg or nil) end,
  keys = function() wt().keys() end,
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
      elseif words[2] == 'comment' and #words <= 3 then
        pool = comment_types
      elseif words[2] == 'decide' then
        pool = { 'accept', 'reject', 'clear' }
      elseif words[2] == 'explain' then
        pool = { 'simpler', 'deeper' }
      elseif words[2] == 'check' then
        pool = { 'reveal', 'answer' }
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
-- to normal. The comment mappings work on a selection too.
local function plug(fn, modes)
  return { fn, modes or { 'n' } }
end
local function comment(ctype)
  return plug(function() wt().comment(ctype) end, { 'n', 'x' })
end
local plugs = {
  next = plug(function() wt().step(1) end),
  prev = plug(function() wt().step(-1) end),
  back = plug(function() wt().step(0) end),
  ['note-next'] = plug(function() wt().note(1) end),
  ['note-prev'] = plug(function() wt().note(-1) end),
  ['group-next'] = plug(function() wt().group('next') end),
  ['group-prev'] = plug(function() wt().group('prev') end),
  ask = plug(function() wt().ask_line() end),
  comment = comment('question'),
  ['comment-issue'] = comment('issue'),
  ['comment-suggestion'] = comment('suggestion'),
  ['comment-delete'] = plug(function() wt().comment_delete() end),
  send = plug(function() wt().send() end),
  accept = plug(function() wt().decide('accept') end),
  decline = plug(function() wt().decide('reject') end),
  undecide = plug(function() wt().decide('clear') end),
  simpler = plug(function() wt().explain('simpler') end),
  deeper = plug(function() wt().explain('deeper') end),
  ['check-reveal'] = plug(function() wt().check('reveal') end),
  ['check-answer'] = plug(function() wt().check('answer') end),
  stage = plug(function() wt().stage_group() end),
  ['stage-all'] = plug(function() wt().stage_group({ all = true }) end),
  reject = plug(function() wt().reject_group() end),
  base = plug(function() wt().base() end),
  reviewed = plug(function() reviewed() end),
  resume = plug(function() report(wt().resume()) end),
  close = plug(function() report(wt().close()) end),
  keys = plug(function() wt().keys() end),
}
for name, p in pairs(plugs) do
  vim.keymap.set(p[2], '<Plug>(walkthrough-' .. name .. ')', p[1], { desc = 'Walkthrough: ' .. name })
end

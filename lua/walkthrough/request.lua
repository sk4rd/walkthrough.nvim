-- Asking the working session for the map of the change under review (the
-- second step of reviewing a finished change).
--
-- `describe` collects what the agent needs to know: the repository root, the
-- base the change is measured against, and the list of changed files. The
-- list is the one of the local review (the tour flagged `auto`) when there is
-- one, else git's, as `review` computes it. `message` turns it into the text
-- for the sender. The request is remembered per repository until a map of
-- the agent arrives (init.lua `load`), the session is closed or the review is
-- discarded; `pending` lists it for `inbox` and `status` for `status`.
local st = require('walkthrough.state')
local git = require('walkthrough.git')
local tours = require('walkthrough.tours')

local M = {}

-- The most files listed in the message; the request keeps them all.
local MAX_LISTED = 200

-- A path as the agent should read it: relative to the repository root.
local function relative(root, file)
  local abs = vim.fn.fnamemodify(file, ':p')
  if vim.startswith(abs, root .. '/') then
    return abs:sub(#root + 2)
  end
  return vim.fn.fnamemodify(abs, ':~:.')
end

--- What the request is about, for the review `t` (a tour of a change):
--- `{ root, base, files }`. `base` is the ref the review was made against,
--- `HEAD` when it has none. Raises when git cannot list the files.
function M.describe(t)
  local root = t.root
  local _, auto = tours.find_auto(root)
  local source = auto or t
  local first = source.steps[1]
  local base = first and type(first.diff) == 'string' and first.diff or 'HEAD'
  local files = {}
  if auto then
    for i, step in ipairs(auto.steps) do
      files[i] = relative(root, step.file)
    end
  else
    for i, name in ipairs(git.changed_files(root, base ~= 'HEAD' and base or nil)) do
      files[i] = name
    end
  end
  return { root = root, base = base, files = files }
end

--- The message for the sender: the facts, then what is expected.
function M.message(info)
  local lines = {
    'Walkthrough: the user asks for the map of the change under review.',
    '',
    'Repository: ' .. info.root,
    'Base: ' .. info.base,
    ('Changed files (%d):'):format(#info.files),
  }
  for i, name in ipairs(info.files) do
    if i > MAX_LISTED then
      table.insert(lines, ('  ... %d more (see git status)'):format(#info.files - MAX_LISTED))
      break
    end
    table.insert(lines, '  ' .. name)
  end
  vim.list_extend(lines, {
    '',
    'Expected: build the map of this change. Sort the changes into commits that each stand on their own,',
    '          ordered so that nothing depends on a later commit.',
    '          Send one map per commit with tour.sh: "group" is the commit\'s subject; "steps" are its files',
    '          in reading order, each with a one-sentence "title"; "hunks" assign every changed line of each',
    '          file to a commit. Add your findings as "notes", each with a "verdict" and "evidence".',
    '          Use the walkthrough skill for the format.',
  })
  return { text = table.concat(lines, '\n'), refs = {} }
end

--- Remember that the agent was asked, until its map arrives.
function M.record(info)
  st.map_requests[info.root] = info
end

--- The agent's map for `root` arrived (or the request is void).
function M.clear(root)
  st.map_requests[root] = nil
end

--- Forget every request: the session ended.
function M.clear_all()
  st.map_requests = {}
end

--- The requests for the repositories in `roots` (a set), as the items of
--- `inbox`: `{ kind = 'map', root, base, files }`. They are not marked as
--- delivered: a request stays until the map arrived.
function M.pending(roots)
  local out = {}
  for root, info in pairs(st.map_requests) do
    if roots[root] then
      table.insert(out, { kind = 'map', root = root, base = info.base, files = info.files })
    end
  end
  table.sort(out, function(a, b)
    return a.root < b.root
  end)
  return out
end

--- "requested" while the map of the active review's repository (else of any
--- repository) is asked for and has not arrived; nil otherwise.
function M.status()
  local active = tours.active()
  if active then
    return st.map_requests[active.root] and 'requested' or nil
  end
  return next(st.map_requests) and 'requested' or nil
end

return M

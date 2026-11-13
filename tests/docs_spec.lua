-- Keeps the documents and the code together. The names come from the code:
-- the validator's tables, the command's completion and the config defaults.
-- Fields, verdicts, evidence values and options must appear in backticks
-- (`name`), commands as ":Walkthrough name".
local H = require('helpers')
local check = H.check
local tour = require('walkthrough.tour')

local root = vim.env.WALKTHROUGH_ROOT or vim.fn.getcwd()
local function read(path)
  return table.concat(vim.fn.readfile(root .. '/' .. path), '\n')
end
local help = read('doc/walkthrough.txt')
local format = read('skills/walkthrough/references/format.md')

local function names(set)
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

local function mentions(text, name)
  return text:find('`' .. name .. '`', 1, true) ~= nil
end

-- Every name in `set` must be in `text`; one check per table.
local function covers(label, set, text, file)
  local missing = {}
  for _, name in ipairs(names(set)) do
    if not mentions(text, name) then
      table.insert(missing, name)
    end
  end
  check(('%s are all in %s'):format(label, file), #missing == 0, 'missing: ' .. table.concat(missing, ', '))
end

local tables = {
  { 'step fields', tour.step_fields },
  { 'note fields', tour.note_fields },
  { 'hunk fields', tour.hunk_fields },
  { 'verdicts', tour.verdicts },
  { 'evidence values', tour.evidence },
  { 'thread states', tour.thread_states },
  { 'thread kinds', tour.thread_kinds },
  { 'plan thread kinds', tour.plan_thread_kinds },
  { 'inbox item kinds', require('walkthrough.feedback').inbox_kinds },
  { 'thread patch fields', tour.thread_patch_fields },
  { 'commit message patch fields', tour.commit_patch_fields },
  { 'decisions', tour.decisions },
  { 'depths', tour.depths },
}
for _, t in ipairs(tables) do
  covers(t[1], t[2], help, 'doc/walkthrough.txt')
  covers(t[1], t[2], format, 'references/format.md')
end

-- The tables are not empty (a renamed table would make the loop above vacuous).
for _, t in ipairs(tables) do
  check(t[1] .. ': the table has entries', next(t[2]) ~= nil)
end
check('the format knows the new verdict and a known evidence value', tour.verdicts.moved and tour.evidence.ran)
-- The field `total` is gone from the protocol, and so from both documents' field tables.
check('no step field total', tour.step_fields.total == nil)
check('every inbox item kind is one of the five', vim.deep_equal(names(require('walkthrough.feedback').inbox_kinds),
  { 'change', 'commit', 'decision', 'map', 'question' }))
check('every thread state is one of the seven', vim.deep_equal(names(tour.thread_states),
  { 'accepted', 'answered', 'declined', 'done', 'draft', 'proposed', 'waiting' }))

-- A plan has comments, and the documents say how they are written and sent.
check('the plan has one kind of thread, the comment', vim.deep_equal(names(tour.plan_thread_kinds), { 'comment' }))
for _, phrase in ipairs({ 'Comment on plan line 4', 'Comment on plan lines 4-6', 'Comment t1 on plan line 4:' }) do
  check('doc/walkthrough.txt names "' .. phrase .. '"', help:find(phrase, 1, true) ~= nil)
end
check('references/format.md names the label of a comment in the plan feedback', format:find('Comment t1 on plan line 4:', 1, true) ~= nil)

-- The word "annotation" is not used for what the user writes. The user documents
-- have no "annotat" at all, except in the name of the Lua function `annotate`
-- where the API lists it.
local user_docs = { 'doc/walkthrough.txt', 'README.md', 'skills/walkthrough/SKILL.md' }
local references = vim.fn.glob(root .. '/skills/walkthrough/references/*.md', false, true)
check('the references are found', #references >= 2, #references)
for _, path in ipairs(references) do
  table.insert(user_docs, path:sub(#root + 2))
end
for _, path in ipairs(user_docs) do
  local text = read(path):gsub('annotate%(', '')
  local at = text:lower():find('annotat', 1, true)
  check(path .. ' does not say "annotation"', at == nil, at and text:sub(math.max(1, at - 40), at + 40) or '')
end
check('the API list still names the Lua function annotate', help:find('  annotate(', 1, true) ~= nil)

-- Subcommands: whatever :Walkthrough completes.
local subcommands = vim.fn.getcompletion('Walkthrough ', 'cmdline')
check('subcommands are found through completion', #subcommands >= 20, #subcommands)
local missing = {}
for _, sub in ipairs(subcommands) do
  if not help:find(':Walkthrough ' .. sub, 1, true) then
    table.insert(missing, sub)
  end
end
check('every :Walkthrough subcommand is in doc/walkthrough.txt', #missing == 0, 'missing: ' .. table.concat(missing, ', '))

-- Config options: the defaults in state.lua.
local options = {}
for key in pairs(require('walkthrough.state').config) do
  options[key] = true
end
covers('setup options', options, help, 'doc/walkthrough.txt')

-- The <Plug> mappings the plugin file defines.
local plugs = {}
for _, m in ipairs(vim.api.nvim_get_keymap('n')) do
  local name = m.lhs:match('^<Plug>%(walkthrough%-([%w-]+)%)$')
  if name then
    plugs[name] = true
  end
end
check('the <Plug> mappings are found', next(plugs) ~= nil)
local plug_missing = {}
for name in pairs(plugs) do
  if not help:find('<Plug>(walkthrough-' .. name .. ')', 1, true) then
    table.insert(plug_missing, name)
  end
end
check('every <Plug> mapping is in doc/walkthrough.txt', #plug_missing == 0, 'missing: ' .. table.concat(plug_missing, ', '))

-- Default keys: each suffix (or absolute key) appears in the help file, as
-- written there: the prefix is shown as P, so "P" followed by the suffix.
local key_missing = {}
local defaults = require('walkthrough.keys').defaults
check('the default keys are found', #defaults > 0)
for _, k in ipairs(defaults) do
  local shown = k[4] and k[1] or ('P' .. k[1])
  if not help:find('  ' .. shown, 1, true) then
    table.insert(key_missing, shown)
  end
end
check('every default key is in doc/walkthrough.txt', #key_missing == 0, 'missing: ' .. table.concat(key_missing, ', '))

-- Public Lua functions of the module.
local api_missing = {}
for name, fn in pairs(H.w) do
  if type(fn) == 'function' and not help:find('  ' .. name .. '(', 1, true) then
    table.insert(api_missing, name)
  end
end
table.sort(api_missing)
check('every public function is in doc/walkthrough.txt', #api_missing == 0, 'missing: ' .. table.concat(api_missing, ', '))

-- The skill's front matter stays valid (https://agentskills.io/specification).
local skill = read('skills/walkthrough/SKILL.md')
local front = skill:match('^%-%-%-\n(.-)\n%-%-%-\n')
check('SKILL.md has front matter', front ~= nil)
check('SKILL.md name is the directory name', front and front:match('\nname: walkthrough\n') ~= nil
  or (front and front:match('^name: walkthrough\n') ~= nil))
local desc = front and front:match('description: ([^\n]+)')
check('SKILL.md description is 1 to 1024 characters', desc ~= nil and #desc >= 1 and #desc <= 1024)
check('SKILL.md stays short', #vim.split(skill, '\n', { plain = true }) <= 170)
-- The agent's skill names every kind of item the inbox lists, and the README every option.
covers('inbox item kinds', require('walkthrough.feedback').inbox_kinds, skill, 'SKILL.md')
covers('setup options', options, read('README.md'), 'README.md')

H.finish()

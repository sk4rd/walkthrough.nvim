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
  { 'check fields', tour.check_fields },
  { 'verdicts', tour.verdicts },
  { 'evidence values', tour.evidence },
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

H.finish()

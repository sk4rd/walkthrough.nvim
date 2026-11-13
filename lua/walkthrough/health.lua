-- :checkhealth walkthrough
local M = {}

function M.check()
  local h = vim.health
  h.start('walkthrough.nvim')

  if vim.fn.has('nvim-0.10') == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim 0.10 or newer is required', 'Update Neovim')
  end

  if vim.fn.executable('git') == 1 then
    h.ok(vim.trim(vim.fn.system({ 'git', '--version' })))
  else
    h.error('git not found in $PATH', 'The diff overlay and staging need git')
  end

  if pcall(require, 'gitsigns') then
    h.ok('gitsigns.nvim found (staging by line range)')
  else
    h.warn('gitsigns.nvim not found: stage_group cannot stage', 'Install lewis6991/gitsigns.nvim')
  end

  if vim.fn.exists(':ClaudeCodeAdd') == 2 then
    h.ok('claudecode.nvim found (optional)')
  else
    h.info('claudecode.nvim not loaded (optional)')
  end

  local send = require('walkthrough.send')
  local configured = require('walkthrough.state').config.sender
  h.info('sender: ' .. (type(configured) == 'function' and 'custom function' or tostring(configured)))
  if configured == 'auto' then
    h.ok('"auto" currently resolves to: ' .. send.resolve())
  end
end

return M

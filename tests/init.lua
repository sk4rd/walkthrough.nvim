-- Minimal init for the tests: no user config, but start packages (gitsigns
-- if installed) still load. The plugin itself comes first on the runtimepath
-- (tests/run.sh), so this checkout wins over an installed copy.
vim.o.swapfile = false
vim.o.autoread = true

-- CI clones gitsigns into a directory of its own instead of installing it.
if vim.env.WALKTHROUGH_GITSIGNS and vim.env.WALKTHROUGH_GITSIGNS ~= '' then
  vim.opt.runtimepath:append(vim.env.WALKTHROUGH_GITSIGNS)
end

-- `require('helpers')` in the test files.
if vim.env.WALKTHROUGH_ROOT then
  package.path = vim.env.WALKTHROUGH_ROOT .. '/tests/?.lua;' .. package.path
end

-- Review state (:Walkthrough resume) goes where tests/run.sh says, never to
-- the user's real state directory.
if vim.env.WALKTHROUGH_STATE_DIR and vim.env.WALKTHROUGH_STATE_DIR ~= '' then
  require('walkthrough.state').config.state_dir = vim.env.WALKTHROUGH_STATE_DIR
end

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

-- Most specs test the file view, so tours open in it. The plugin's default is
-- the compact view: tests/compact_spec.lua (and a few checks of other specs)
-- switch it on.
require('walkthrough.state').config.view = 'file'

-- Review state (:Walkthrough resume) goes where tests/run.sh says, never to
-- the user's real state directory.
if vim.env.WALKTHROUGH_STATE_DIR and vim.env.WALKTHROUGH_STATE_DIR ~= '' then
  require('walkthrough.state').config.state_dir = vim.env.WALKTHROUGH_STATE_DIR
end

-- A copy of the plugin installed on the packpath (a package manager, Nix)
-- would define :Walkthrough and the <Plug> mappings a second time, from its
-- own code, and the later definition wins. Only this checkout's plugin file
-- is sourced.
if vim.env.WALKTHROUGH_ROOT and vim.env.WALKTHROUGH_ROOT ~= '' then
  local root = vim.fs.normalize(vim.env.WALKTHROUGH_ROOT)
  vim.api.nvim_create_autocmd('SourceCmd', {
    pattern = '*/plugin/walkthrough.lua',
    callback = function(ev)
      if vim.startswith(vim.fs.normalize(vim.fn.fnamemodify(ev.file, ':p')), root .. '/') then
        dofile(ev.file)
      end
    end,
  })
end

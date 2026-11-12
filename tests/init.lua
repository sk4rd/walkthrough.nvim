-- Minimal init for the tests: no user config, but start packages (gitsigns
-- if installed) still load. The plugin itself comes first on the runtimepath
-- (tests/run.sh), so this checkout wins over an installed copy.
vim.o.swapfile = false
vim.o.autoread = true

-- How much of the reviewed group is staged, over all files of a tour.
local git = require('walkthrough.git')
local tour = require('walkthrough.tour')

local M = {}

--- Count the lines of the reviewed group's ranges in every file of `t`:
--- `total` differ from HEAD, `staged` of those no longer differ from the
--- index. A shown deletion counts as one line, on the line it is shown on.
--- Two `git diff` calls per file. Returns { staged, total, files }, where
--- `files` maps the absolute path of each counted file to its own
--- { staged, total } (the map panel shows them per entry), or nil when there
--- is nothing to count: no step lists ranges for a diff against HEAD, or the
--- files are not in a repository.
function M.compute(t)
  local order, files = {}, {}
  for _, step in ipairs(t.steps) do
    if step.hunks and step.diff == true then
      -- Edits since the ranges were written move them first.
      pcall(tour.sync, step)
      local abs = vim.fn.fnamemodify(step.file, ':p')
      if not files[abs] then
        files[abs] = {}
        table.insert(order, abs)
      end
      for _, r in ipairs(tour.group_ranges(step, true)) do
        for line = r.from, r.to do
          files[abs][line] = true
        end
      end
    end
  end

  local staged, total, counted = 0, 0, false
  local per_file = {}
  for _, abs in ipairs(order) do
    local head = git.hunks(abs, 'HEAD')
    local index = head and git.hunks(abs, nil)
    if index then
      counted = true
      local last = #vim.fn.readfile(abs)
      local changed = git.unstaged_set(head, last)
      local unstaged = git.unstaged_set(index, last)
      local file_staged, file_total = 0, 0
      for line in pairs(files[abs]) do
        if changed[line] then
          file_total = file_total + 1
          if not unstaged[line] then
            file_staged = file_staged + 1
          end
        end
      end
      per_file[abs] = { staged = file_staged, total = file_total }
      staged, total = staged + file_staged, total + file_total
    end
  end
  if not counted then
    return nil
  end
  return { staged = staged, total = total, files = per_file }
end

return M

-- Positions that follow edits. A tour stores absolute line numbers; this
-- module moves them along when the file they refer to changes. Pure logic on
-- tables of lines: no windows, no buffers, no files.
--
-- A step keeps `_snap`, the lines of its file that its numbers refer to. To
-- sync, the lines now on disk are diffed against `_snap`, every number is
-- translated through that diff, and `_snap` is replaced.
local M = {}

-- vim.text.diff exists from Neovim 0.12; vim.diff before that.
local diff = (vim.text and vim.text.diff) or vim.diff

-- Compare lines without their whitespace changes. xdiff's own option does not
-- see a line gaining indentation from none ("a" -> "  a"), so lines are
-- normalised here as well; the line count stays the same.
local function normalise(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = vim.trim((l:gsub('%s+', ' ')))
  end
  return out
end

local function as_text(lines)
  return #lines == 0 and '' or (table.concat(lines, '\n') .. '\n')
end

--- Hunks { a_start, a_count, b_start, b_count } turning `old_lines` into
--- `new_lines`. For a count of 0 the start is the line before the gap (0 at
--- the top of the file).
function M.diff(old_lines, new_lines)
  return diff(as_text(normalise(old_lines)), as_text(normalise(new_lines)), {
    result_type = 'indices',
    ignore_whitespace_change = true,
  })
end

--- Where `line` is after the change. The second result is true when the line
--- itself was rewritten or deleted; it then maps to the nearest line (for a
--- deletion, the line the deletion is shown on, see git.removed_anchor).
function M.map_line(hunks, line)
  local delta = 0
  for _, h in ipairs(hunks) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    if a_count == 0 then
      -- An insertion after old line a_start moves what comes after it.
      if line <= a_start then
        break
      end
      delta = delta + b_count
    else
      if line < a_start then
        break
      end
      if line >= a_start + a_count then
        delta = delta + b_count - a_count
      elseif b_count == 0 then
        return math.max(b_start, 1), true
      else
        return b_start + math.min(line - a_start, b_count - 1), true
      end
    end
  end
  return line + delta, false
end

--- Where the range `from`..`to` (a group's lines) is after the change. A
--- change inside the range resizes it; lines inserted directly before or
--- after it are not part of it; a change reaching over its edge makes it
--- stale (its ends are then only a best guess). A range whose lines were all
--- deleted collapses onto the line the deletion is shown on; the fourth
--- result says so.
function M.map_range(hunks, from, to)
  local above, inside, stale = 0, 0, false
  for _, h in ipairs(hunks) do
    local a_start, a_count, b_count = h[1], h[2], h[4]
    local a_end = a_start + a_count - 1
    if a_count == 0 then
      if a_start < from then
        above = above + b_count
      elseif a_start < to then
        inside = inside + b_count
      end
    elseif a_end < from then
      above = above + b_count - a_count
    elseif a_start > to then
      break
    elseif a_start >= from and a_end <= to then
      inside = inside + b_count - a_count
    else
      stale = true
    end
  end
  if stale then
    local new_from = M.map_line(hunks, from)
    local new_to = M.map_line(hunks, to)
    return new_from, math.max(new_from, new_to), true, false
  end
  local new_from, new_to = from + above, to + above + inside
  if new_to < new_from then
    -- new_from - 1 is the line before the gap, where the deletion is shown.
    new_from = math.max(new_from - 1, 1)
    return new_from, new_from, false, true
  end
  return new_from, new_to, false, false
end

--- Move every position of `step` from the lines in `step._snap` to
--- `new_lines`, in place, and make `new_lines` the new `_snap`. Notes whose
--- line changed, comments whose code was rewritten and hunk ranges hit by an
--- edit get `stale = true` (never cleared here). Returns whether a position or flag changed.
function M.sync_step(step, new_lines)
  local old_lines = step._snap
  step._snap = vim.list_slice(new_lines)
  if not old_lines then
    return false
  end
  local hunks = M.diff(old_lines, new_lines)
  if #hunks == 0 then
    return false
  end

  local last = math.max(#new_lines, 1)
  local changed = false
  local function set(t, key, value)
    if t[key] ~= value then
      t[key], changed = value, true
    end
  end

  -- The focus is best effort and never stale.
  if step.from then
    local from = M.map_line(hunks, step.from)
    local to = M.map_line(hunks, step.to or step.from)
    from = math.min(from, last)
    set(step, 'from', from)
    if step.to ~= nil then
      set(step, 'to', math.max(from, math.min(to, last)))
    end
  end

  for _, note in ipairs(step.notes or {}) do
    local line, stale = M.map_line(hunks, note.line)
    set(note, 'line', math.min(line, last))
    if stale then
      set(note, 'stale', true)
    end
  end

  -- A comment is about the code on its lines: a rewrite or a deletion of any
  -- of them makes it stale, lines inserted inside only widen it.
  for _, c in ipairs(step.comments or {}) do
    local rewritten = false
    for _, h in ipairs(hunks) do
      local a_start, a_count = h[1], h[2]
      if a_count > 0 and a_start <= c.to and a_start + a_count - 1 >= c.from then
        rewritten = true
      end
    end
    local from, to = M.map_range(hunks, c.from, c.to)
    from, to = math.min(from, last), math.min(to, last)
    set(c, 'from', from)
    set(c, 'to', math.max(from, to))
    if rewritten then
      set(c, 'stale', true)
    end
  end

  local collapsed = {}
  for _, h in ipairs(step.hunks or {}) do
    local from, to, stale, gone = M.map_range(hunks, h.from, h.to or h.from)
    from, to = math.min(from, last), math.min(to, last)
    set(h, 'from', from)
    if h.to ~= nil or to ~= from then
      set(h, 'to', to)
    end
    if stale then
      set(h, 'stale', true)
    end
    collapsed[h] = gone
  end

  -- A range whose lines were all deleted sits on the line before the gap. If
  -- that line belongs to another range, the deletion is shown as part of that
  -- one, and two ranges on one line would contradict each other: drop it.
  if next(collapsed) then
    local kept = {}
    for _, h in ipairs(step.hunks) do
      local taken = false
      if collapsed[h] then
        for _, o in ipairs(step.hunks) do
          if o ~= h and not collapsed[o] and not o.stale and h.from >= o.from and h.from <= (o.to or o.from) then
            taken = true
            break
          end
        end
      end
      if taken then
        changed = true
      else
        table.insert(kept, h)
      end
    end
    step.hunks = kept
  end
  return changed
end

return M

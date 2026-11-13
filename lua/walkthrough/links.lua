-- Links in what was written on a line: an answer of the agent often points at
-- documentation. The text under a line is virtual, so the cursor cannot go to
-- a URL there; `open` takes the links of the thread or finding under the
-- cursor instead: one is opened at once, of several one is picked.
local M = {}

local trailing = '[%.,;:!%?\'"%*_]$'

-- Count of the plain character `ch` in `s`.
local function count(s, ch)
  return select(2, s:gsub('%' .. ch, ''))
end

--- The links in `text`, in order and each once: `{ { url, label } }`. A URL
--- ends at white space; punctuation that closes the sentence, and a bracket
--- that closes one opened before the URL, are not part of it. `label` is the
--- text of a Markdown link (`[label](url)`), else nil.
function M.find(text)
  local out, seen = {}, {}
  local init = 1
  while true do
    local s, e = text:find('https?://[^%s<>"`]+', init)
    if not s then
      break
    end
    local url = text:sub(s, e)
    local before
    repeat
      before = url
      url = url:gsub(trailing, '')
      for _, pair in ipairs({ { '(', ')' }, { '[', ']' } }) do
        if url:sub(-1) == pair[2] and count(url, pair[2]) > count(url, pair[1]) then
          url = url:sub(1, -2)
        end
      end
    until url == before
    local label = text:sub(s - 2, s - 1) == '](' and text:sub(1, s - 3):match('%[([^%[%]]*)$') or nil
    if not seen[url] and url:match('^https?://.') then
      seen[url] = true
      table.insert(out, { url = url, label = label ~= '' and label or nil })
    end
    init = e + 1
  end
  return out
end

--- The links of a target (see feedback.here): of the messages of its thread,
--- the newest first, and of the text and detail of its finding.
function M.of(target)
  local texts = {}
  if target.thread then
    for i = #target.thread.messages, 1, -1 do
      local text = target.thread.messages[i].text
      table.insert(texts, type(text) == 'table' and table.concat(text, '\n') or tostring(text or ''))
    end
  end
  if target.note then
    for _, text in ipairs({ target.note.text, target.note.detail }) do
      table.insert(texts, type(text) == 'table' and table.concat(text, '\n') or tostring(text or ''))
    end
  end
  return M.find(table.concat(texts, '\n'))
end

local function open_url(url)
  local ok, _, err = pcall(vim.ui.open, url)
  if not ok or err then
    vim.notify('walkthrough: could not open ' .. url, vim.log.levels.WARN)
  end
end

--- Open a link of `target`: the only one at once; of several, the one picked
--- in |vim.ui.select()|. Says so when there is none.
function M.open(target)
  if not (target.thread or target.note) then
    return vim.notify('walkthrough: no thread or finding on this line', vim.log.levels.INFO)
  end
  local links = M.of(target)
  if #links == 0 then
    return vim.notify('walkthrough: no link in this ' .. (target.thread and 'thread' or 'finding'), vim.log.levels.INFO)
  end
  if #links == 1 then
    return open_url(links[1].url)
  end
  vim.ui.select(links, {
    prompt = 'Open link',
    format_item = function(link)
      return link.label and ('%s  %s'):format(link.label, link.url) or link.url
    end,
  }, function(link)
    if link then
      open_url(link.url)
    end
  end)
end

return M

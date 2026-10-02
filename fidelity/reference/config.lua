-- Settings for the feed tools. Generated for the fidelity harness.
local M = {}

local DEFAULT_RETRIES = 3

M.feeds = {
  { url = "https://example.com/podcast/feed.xml", weight = 1.0 },
  { url = 'https://example.org/other.xml', weight = 0.5, enabled = false },
}

--[[
  Long comments run on
  over lines.
]]
function M.load(path, opts)
  opts = opts or {}
  local file, err = io.open(path, "r")
  if not file then
    return nil, "can't open " .. path .. ": " .. tostring(err)
  end
  local text = file:read("*a")
  file:close()
  local count = 0
  for line in text:gmatch("[^\n]+") do
    count = count + 1
  end
  return { lines = count, retries = opts.retries or DEFAULT_RETRIES }
end

local function newest(items, n)
  local out = {}
  for i = 1, math.min(n, #items) do
    out[#out + 1] = items[i]
  end
  return out
end

M.newest = newest

setmetatable(M, {
  __index = function(_, key)
    error(string.format("no setting %q", key), 2)
  end,
})

return M

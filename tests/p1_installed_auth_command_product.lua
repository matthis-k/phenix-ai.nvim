-- Native ACP command acceptance, using an isolated temporary store.
local notifications = {}
vim.notify = function(value)
  notifications[#notifications + 1] = tostring(value)
end
local phase, opened = "api", false
vim.ui.select = function(items, options, callback)
  local prompt = options and options.prompt or ""
  if prompt:find("Phenix provider", 1, true) then
    for _, value in ipairs(items) do
      if value.id == "openai" then return callback(value) end
    end
  elseif prompt:find("Authenticate ", 1, true) then
    for _, value in ipairs(items) do
      if value.connection_id == phase then return callback(value) end
    end
  elseif prompt:find("API key source", 1, true) then
    phase = "api-source-reached"
    return callback(nil)
  end
  error("unexpected auth selection: " .. prompt)
end
vim.ui.open = function(_)
  opened = true
  return true, nil
end
vim.cmd("runtime plugin/phenix.lua")
assert(vim.fn.exists(":Phenix") == 2)
require("phenix_nvim").setup({ auto_connect = false })
vim.cmd("Phenix auth")
assert(vim.wait(30000, function() return phase == "api-source-reached" end, 10),
  "API-key chooser failed: " .. table.concat(notifications, " | "))
phase = "chatgpt"
vim.cmd("Phenix auth")
assert(vim.wait(30000, function() return opened end, 10),
  "OAuth browser challenge failed: " .. table.concat(notifications, " | "))
for _, value in ipairs(notifications) do
  assert(not value:lower():find("invalid param", 1, true), value)
end
require("phenix_nvim.runtime").disconnect()
print("native Phenix auth picker, key-source, and OAuth challenge reached")

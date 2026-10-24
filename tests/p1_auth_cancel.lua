-- The normal-mode dismiss action cancels exactly one provider-owned OAuth
-- attempt, stops local polling, and ignores in-flight success from a stale UI.
local runtime = require("phenix_nvim.runtime")
local ui = require("phenix_nvim.ui.auth")
local util = require("phenix_nvim.util")
local actions = require("phenix_nvim.actions")
local original = {
  methods = runtime.list_authentication_methods,
  providers = runtime.list_providers,
  select = ui.select,
  authenticate = runtime.authenticate,
  poll = runtime.poll_authentication,
  cancel = runtime.cancel_authentication,
  open = vim.ui.open,
  pending = ui.pending,
  notify = util.notify,
  defer = vim.defer_fn,
}
local method = {
  provider_id = "openai", connection_id = "chatgpt",
  method_id = "oauth", kind = "OAuthAuthorizationCode",
  provider_name = "OpenAI", label = "ChatGPT",
}
local opened, started, cancelled, closed, tasks, notices, cancel_view
local observed_poll
local function reset()
  opened, started, cancelled, closed, tasks, notices = {}, {}, {}, 0, {}, {}
  cancel_view, observed_poll = nil, nil
end
reset()

runtime.list_authentication_methods = function(callback)
  callback({ methods = { vim.deepcopy(method) } }, nil)
end
runtime.list_providers = function(callback)
  callback({ revision = 1, providers = {{
    id = "openai", label = "OpenAI",
    connections = {{ id = "chatgpt", auth_methods = {
      { id = "oauth", kind = "OAuthAuthorizationCode" },
    } }},
  }} }, nil)
end
ui.select = function(items, options, callback)
  assert(options.prompt == "Phenix provider (declared, not authenticated)")
  assert(#items == 1 and items[1].id == "openai")
  callback(items[1])
end
runtime.authenticate = function(identity, secret, callback)
  assert(secret == nil, "OAuth must not ask Lua for a secret")
  started[#started + 1] = identity
  callback({
    kind = "openbrowser", url = "https://auth.openai.com/authorize",
    attempt_id = "attempt-1", provider_id = identity.provider_id,
    connection_id = identity.connection_id, method_id = identity.method_id,
  }, nil)
end
runtime.poll_authentication = function(identity, attempt, callback)
  assert(identity.provider_id == "openai" and identity.connection_id == "chatgpt"
    and attempt == "attempt-1")
  observed_poll = callback
end
runtime.cancel_authentication = function(identity, attempt, callback)
  assert(identity.provider_id == "openai" and identity.connection_id == "chatgpt"
    and attempt == "attempt-1", "cancel must preserve provider/connection/attempt")
  cancelled[#cancelled + 1] = attempt
  callback({ kind = "cancelled" }, nil)
end
ui.pending = function(title, on_cancel)
  assert(title:find("openai", 1, true))
  cancel_view = on_cancel
  return { close = function() closed = closed + 1 end }
end
vim.ui.open = function(url)
  opened[#opened + 1] = url
  return true
end
vim.defer_fn = function(fn, millis)
  assert(millis == 1000)
  tasks[#tasks + 1] = fn
end
util.notify = function(message)
  notices[#notices + 1] = tostring(message)
end
local function has_success()
  for _, value in ipairs(notices) do
    if value:find("authentication completed", 1, true) then return true end
  end
  return false
end
local function drive()
  assert(#tasks > 0)
  table.remove(tasks, 1)()
end

actions.authenticate()
assert(#started == 1 and #opened == 1 and type(cancel_view) == "function")
drive()
assert(observed_poll ~= nil)
cancel_view() -- actual normal-mode q/Esc keymap delegates here
assert(#cancelled == 1 and closed == 1)
observed_poll({ kind = "authenticated", verified = true })
assert(not has_success(), "late provider response must not resurrect canceled auth")
assert(#tasks == 0, "canceled attempt must not schedule more polls")

reset()
actions.authenticate()
drive()
observed_poll({ kind = "authenticated", verified = true })
assert(has_success() and closed == 1)
assert(#cancelled == 0, "successful login must not call provider cancel")
assert(#tasks == 0)

for name, value in pairs(original) do
  if name == "methods" then runtime.list_authentication_methods = value
  elseif name == "providers" then runtime.list_providers = value
  elseif name == "select" then ui.select = value
  elseif name == "authenticate" then runtime.authenticate = value
  elseif name == "poll" then runtime.poll_authentication = value
  elseif name == "cancel" then runtime.cancel_authentication = value
  elseif name == "open" then vim.ui.open = value
  elseif name == "pending" then ui.pending = value
  elseif name == "notify" then util.notify = value
  elseif name == "defer" then vim.defer_fn = value end
end
print("Normal-mode OAuth cancellation and late-completion isolation accepted")

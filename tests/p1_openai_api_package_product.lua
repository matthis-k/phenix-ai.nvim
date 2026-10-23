-- Installed Neovim client -> native ACP -> real provider plugin.
-- This test intentionally does not send a key or contact a live API.
-- The runtime's deterministic HTTPS fixture owns verified-login/inference tests.
local binary = assert(vim.env.PHENIX_P1_OPENAI_API_BIN, "packaged OpenAI API runtime required")
local backend = require("phenix_client.acp").new({ command = binary })
local client = require("phenix_client").new(backend)

local function receive(invoke, label, expect_error)
  local done, result, failure = false, nil, nil
  invoke(function(value, err)
    assert(not done, label .. " callback invoked more than once")
    done, result, failure = true, value, err
  end)
  assert(vim.wait(30000, function() return done end, 10), label .. " timed out")
  if expect_error then
    assert(failure ~= nil, label .. " unexpectedly succeeded")
    return failure
  end
  assert(failure == nil, label .. ": " .. vim.inspect(failure))
  assert(result ~= nil, label .. " returned no result")
  return result
end

receive(function(cb) client:start(cb) end, "native ACP initialize")
local catalog = receive(function(cb) client:list_providers(cb) end, "native provider catalog")
local provider
for _, item in ipairs(catalog.providers or {}) do
  if item.id == "openai" then provider = item end
end
assert(provider, "installed provider catalog must expose OpenAI")
local connection
for _, item in ipairs(provider.connections or {}) do
  if item.id == "api" then connection = item end
end
assert(connection, "installed OpenAI provider must expose its API connection")
local method
for _, item in ipairs(connection.auth_methods or {}) do
  if item.kind == "ApiKey" then method = item end
end
assert(method and method.id == "api-key", "generic provider auth must declare API-key method")

local status = receive(function(cb)
  client:get_provider_auth_status("openai", "api", cb)
end, "unconfigured account status")
assert(status.profiles and status.profiles[1], "provider profile status missing")
assert(status.profiles[1].status.Unavailable,
  "unconfigured account cannot claim authenticated status")

local started = receive(function(cb)
  client:begin_provider_auth("openai", "api", method.id, cb)
end, "API-key authentication attempt")
local attempt = started.ApiKeyInput and started.ApiKeyInput.attempt_id
assert(type(attempt) == "string" and attempt ~= "", "API-key challenge ID required")

local pending = receive(function(cb)
  client:poll_provider_auth("openai", "api", attempt, cb)
end, "pending authentication")
assert(pending == "Pending", "no credential must not complete authentication")

local cancelled = receive(function(cb)
  client:cancel_provider_auth("openai", "api", attempt, cb)
end, "cancel authentication")
assert(cancelled == "Cancelled", "cancelled challenge must remain terminal")
receive(function(cb)
  client:poll_provider_auth("openai", "api", attempt, cb)
end, "replayed cancelled challenge", true)

client:close()
print("Installed OpenAI API ACP client auth lifecycle passed")

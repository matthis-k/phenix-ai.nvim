local frontend = require("phenix_nvim")
local runtime = require("phenix_nvim.runtime")

frontend.setup({ auto_connect = false })

local function await(invoke, label)
  local value = nil
  local failure = nil
  invoke(function(result, error)
    value = result
    failure = error
  end)
  assert(vim.wait(10000, function()
    return value ~= nil or failure ~= nil
  end, 10), label .. " timed out")
  assert(failure == nil, vim.inspect(failure))
  return value
end

local function connect()
  local connected = false
  local failure = nil
  frontend.connect(function(_, error)
    failure = error
    connected = true
  end)
  assert(vim.wait(10000, function()
    return connected
  end, 10), "packaged Phenix connection timed out")
  assert(failure == nil, vim.inspect(failure))
end

local function presentation_kind(item)
  local presentation = item and item.presentation
  if type(presentation) == "table" then
    return string.lower(tostring(presentation.kind or ""))
  end
  return string.lower(tostring(presentation or ""))
end

local function selections()
  return await(function(callback)
    runtime.list_selections(callback)
  end, "application model discovery")
end

local function auth_methods()
  return await(function(callback)
    runtime.list_authentication_methods(callback)
  end, "authentication discovery")
end

local function find_model(result, provider, model, thinking)
  for _, item in ipairs(result.available or {}) do
    if presentation_kind(item) == "model"
      and item.provider == provider
      and (model == nil or item.model == model)
      and (thinking == nil or item.thinking == thinking)
    then
      return item
    end
  end
  return nil
end

local function find_auth(result, provider, kind)
  for _, method in ipairs(result.methods or {}) do
    if method.provider == provider and (kind == nil or method.kind == kind) then
      return method
    end
  end
  return nil
end

connect()

-- Model discovery and selection are application-scoped. No session exists yet.
assert(runtime.active_session() == nil, "model discovery test must start without a session")
local initial = selections()
assert(type(initial.available) == "table" and #initial.available > 0, "no model selections exposed")
assert(type(initial.selected) == "string" and initial.selected ~= "", "default selection is missing")

local xai = assert(find_model(initial, "xai", "grok-4.6", "high"), "xAI grok-4.6/high route is missing")
local open_router = assert(
  find_model(initial, "open-router", "openrouter/auto", "high"),
  "OpenRouter auto/high route is missing"
)
assert(type(xai.model) == "string" and type(xai.thinking) == "string", "structured model metadata is missing")
assert(type(xai.authenticated) == "boolean", "model authentication state is missing")
assert(type(open_router.authenticated) == "boolean", "OpenRouter authentication state is missing")

local methods = auth_methods()
local expected_api_providers = {
  "anthropic",
  "deepseek",
  "fireworks",
  "gemini",
  "groq",
  "mistral",
  "open-router",
  "openai-api",
  "opencode-go",
  "opencode-zen",
  "together",
  "xai",
}
for _, provider in ipairs(expected_api_providers) do
  local method = assert(find_auth(methods, provider, "api_token"), provider .. " API-key auth is not discoverable")
  assert(type(method.id) == "string" and method.id ~= "", provider .. " auth method id is missing")
end
assert(find_auth(methods, "openai-codex", "oauth") ~= nil, "ChatGPT OAuth is not discoverable")

-- API keys are submitted to Phenix, not installed in the Neovim child environment.
local xai_auth = assert(find_auth(methods, "xai", "api_token"))
local authenticated = await(function(callback)
  runtime.authenticate(xai_auth.id, "test-xai-key", callback)
end, "xAI API-key authentication")
assert(string.lower(tostring(authenticated.kind or "")) == "authenticated", "xAI API key was not accepted")

local after_auth = selections()
xai = assert(find_model(after_auth, "xai", "grok-4.6", "high"))
assert(xai.authenticated == true, "stored xAI credential was not reflected in discovery")

-- Persist the default before a session exists.
local selected = await(function(callback)
  runtime.select(xai.id, callback)
end, "default model selection")
assert(selected.selected == xai.id, "application default selection did not update")
assert(runtime.active_session() == nil, "model selection must not create a session")

-- Both the selected model and provider credential survive a process reconnect.
frontend.disconnect()
connect()
local restored = selections()
assert(restored.selected == xai.id, "persistent model selection did not survive reconnect")
local restored_xai = assert(find_model(restored, "xai", "grok-4.6", "high"))
assert(restored_xai.authenticated == true, "provider credential did not survive reconnect")

-- A new session inherits the persistent application default.
local created = await(function(callback)
  runtime.new_session(callback)
end, "session creation")
assert(created.session_id ~= nil, "new session did not return an id")
local session = assert(runtime.active_session_object(), "new session did not become active")
local session_selections = await(function(callback)
  local ok, request = pcall(session.selections, session)
  assert(ok, tostring(request))
  runtime.track(request, callback)
end, "session model discovery")
assert(session_selections.selected == xai.id, "new session did not inherit the persistent model selection")

frontend.disconnect()
print("persistent model and provider authentication regressions passed")

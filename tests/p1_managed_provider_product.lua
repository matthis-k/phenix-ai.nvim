-- Installed managed Basic host, real official ACP SDK JSON-RPC and native
-- provider plugin. This is an integration test, not a mocked Lua backend.
local binary = assert(vim.env.PHENIX_P1_MANAGED_BIN)
local backend = require("phenix_client.acp").new({ command = binary })
local client = require("phenix_client").new(backend)
local function await_result(invoke, label)
  local done, result, failure = false
  invoke(function(value, err)
    assert(not done, label .. " callback completed twice")
    done, result, failure = true, value, err
  end)
  assert(vim.wait(30000, function() return done end, 10), label .. " timed out")
  assert(not failure, label .. ": " .. vim.inspect(failure))
  assert(result ~= nil, label .. " returned no value")
  return result
end

await_result(function(cb) client:start(cb) end, "ACP initialize")
local page = await_result(function(cb) client:list_providers(cb) end, "provider catalog")
assert(type(page.revision) == "number" and page.revision > 0)
local identities = {}
for _, provider in ipairs(page.providers) do
  assert(type(provider.id) == "string" and type(provider.connections) == "table")
  identities[provider.id] = provider
end
for _, name in ipairs({
  "openai", "openrouter", "anthropic", "opencode-zen", "opencode-go", "zai",
}) do
  assert(identities[name], "native provider omitted " .. name)
end
local openai = {}
for _, account in ipairs(identities.openai.connections) do
  openai[account.id] = account
end
assert(openai.api.auth_methods[1].kind == "ApiKey")
assert(openai.chatgpt.auth_methods[1].kind == "OAuthAuthorizationCode")
assert(not client:capabilities().management.provider_authentication,
  "discovery must not enable credential mutation")
local session = await_result(function(cb) client:new_session(cb) end, "new Basic session")
assert(type(session.session_id) == "string")
local models = await_result(function(cb)
  client:list_models(session.session_id, cb)
end, "Basic model options")
assert(models.selected == "phenix.model.scripted")
assert(#models.models == 1 and models.models[1].id == models.selected,
  "read-only discovery must not change available Basic models")
local completion = await_result(function(cb)
  client:send(session.session_id, "managed-provider-smoke", cb)
end, "Basic model continuation")
assert(completion.stop_reason == "end_turn",
  "native managed host must preserve the scripted Basic graph")
client:close()
print("Managed ACP native provider discovery and Basic session coexist")

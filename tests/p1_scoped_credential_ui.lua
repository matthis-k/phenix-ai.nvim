-- P1 offers API-key UI only for a launcher-admitted account, not
-- because a provider is registered or a key is already stored.
local grant
local listed = 0
local imported = {}
local client = {}
function client:on() return function() end end
function client:start(callback)
  callback({ session_operations = {}, management = {} }, nil)
end
function client:close() end
function client:credential_capabilities(callback)
  if not grant then
    callback(nil, { kind = "unsupported", message = "no authorized credential manager" })
  else
    callback(vim.deepcopy(grant), nil)
  end
end
function client:list_providers(callback)
  listed = listed + 1
  callback({ revision = 1, providers = {
    { id = "openai", label = "OpenAI", connections = {
      { id = "api", label = "OpenAI API", auth_methods = {
        { id = "api-key", label = "API key", kind = "ApiKey" },
        { id = "oauth", label = "OAuth", kind = "OAuthAuthorizationCode" },
      } },
      { id = "chatgpt", label = "ChatGPT", auth_methods = {
        { id = "oauth", label = "OAuth", kind = "OAuthAuthorizationCode" },
      } },
    } },
    { id = "anthropic", label = "Anthropic", connections = {
      { id = "api", label = "Anthropic API", auth_methods = {
        { id = "api-key", label = "API key", kind = "ApiKey" },
      } },
    } },
  } }, nil)
end
local reported_status
function client:get_provider_auth_status(provider, connection, callback)
  assert(provider == "openai" and connection == "api")
  callback({ provider_id = provider, connection_id = connection, profiles =
    reported_status and {{
      id = "personal", label = "Personal", method_id = "api-key",
      status = reported_status,
    }} or {},
  }, nil)
end
function client:import_credential(provider, connection, profile, secret, callback)
  imported[#imported + 1] = { provider, connection, profile }
  assert(type(secret) == "string" and #secret > 0)
  callback({ stored = true, authenticated = false }, nil)
end

package.loaded["phenix_client"] = { new = function() return client end }
package.loaded["phenix_client.acp"] = { new = function() return {} end }
local runtime = require("phenix_nvim.runtime_p1")
runtime.configure({ backend = "p1", command = "mock-acp" })

local methods, failure
local function read()
  methods, failure = nil, nil
  runtime.list_authentication_methods(function(value, err)
    methods, failure = value, err
  end)
end
read()
assert(methods == nil and failure and failure.kind == "unsupported")
assert(listed == 0, "no grant must not enumerate actionable auth methods")

grant = { provider_id = "openai", connection_id = "api",
  profile_id = "personal", import = true, revoke = true }
read()
assert(not failure and #methods.methods == 1)
local entry = methods.methods[1]
assert(entry.provider_id == "openai" and entry.connection_id == "api")
assert(entry.profile_id == "personal" and entry.kind == "ApiKey")
assert(entry.authenticated == false)
reported_status = { Unavailable = { reason = "not yet verified" } }
read()
assert(not failure and methods.methods[1].authenticated == false,
  "Stored-but-unverified account must remain unavailable")
reported_status = "Authenticated"
read()
assert(not failure and methods.methods[1].authenticated == true,
  "Only provider-owned Authenticated variant grants UI readiness")
reported_status = nil
read()
assert(not failure and methods.methods[1].authenticated == false,
  "Absent current auth status removes the readiness projection")

local result, problem
runtime.authenticate({ provider_id = "openai", connection_id = "api",
  profile_id = "work", kind = "ApiKey" }, "local-test-secret", function(v, e)
    result, problem = v, e
  end)
assert(result == nil and problem and problem.kind == "denied")
assert(#imported == 0, "unadmitted account must not send the key")

runtime.authenticate({ provider_id = "openai", connection_id = "api",
  profile_id = "personal", kind = "ApiKey" }, "local-test-secret", function(v, e)
    result, problem = v, e
  end)
assert(not problem and result.kind == "stored")
assert(result.verified == false and result.authenticated == false)
assert(vim.deep_equal(imported[1], { "openai", "api", "personal" }))
runtime.disconnect()
print("P1 credential admission controls auth picker before secret submission")

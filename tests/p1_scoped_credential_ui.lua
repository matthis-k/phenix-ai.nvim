-- P1 offers API-key UI only for a launcher-admitted account, not
-- because a provider is registered or a key is already stored.
local grant
local capability_failure = false
local listed = 0
local imported, bound = {}, {}
local client = {}
function client:on() return function() end end
function client:start(callback)
  callback({ session_operations = {}, management = {} }, nil)
end
function client:close() end
function client:credential_capabilities(callback)
  if capability_failure then
    callback(nil, { kind = "remote", code = -32602, message = "Invalid params" })
  elseif not grant then
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
local oauth_status
local work_status
local anthropic_status
function client:get_provider_auth_status(provider, connection, callback)
  assert((provider == "openai" and (connection == "api" or connection == "chatgpt"))
    or (provider == "anthropic" and connection == "api"))
  local profiles = {}
  if provider == "openai" and connection == "chatgpt" then
    for _, status in ipairs(oauth_status or {}) do
      profiles[#profiles + 1] = vim.deepcopy(status)
    end
  elseif provider == "openai" then
    if reported_status then profiles[#profiles + 1] = {
      id = "personal", label = "Personal", method_id = "api-key",
      status = reported_status,
    } end
    if work_status then profiles[#profiles + 1] = {
      id = "work", label = "Work", method_id = "api-key",
      status = work_status,
    } end
  elseif anthropic_status then
    profiles[#profiles + 1] = {
      id = "team", label = "Team", method_id = "api-key",
      status = anthropic_status,
    }
  end
  callback({ provider_id = provider, connection_id = connection, profiles = profiles }, nil)
end
function client:import_credential(provider, connection, profile, secret, callback)
  imported[#imported + 1] = { provider, connection, profile }
  assert(type(secret) == "string" and #secret > 0)
  callback({ stored = true, authenticated = false }, nil)
end
function client:bind_credential_environment(provider, connection, profile, variable, callback)
  bound[#bound + 1] = { provider, connection, profile, variable }
  callback({ stored = true }, nil)
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
assert(not failure and #methods.methods == 2,
  "OAuth methods must not require an API-key credential grant")
assert(listed == 1)
capability_failure = true
read()
assert(not failure and #methods.methods == 2,
  "invalid-params credential query cannot hide declared OAuth methods")
capability_failure = false
grant = { provider_id = "anthropic", connection_id = "api", profile_id = "team",
  import = false, revoke = true }
read()
assert(not failure and #methods.methods == 2,
  "revoke-only grants must not expose API-key import as an auth option")

-- Exact environment binding is independent of direct-secret import.
grant = { provider_id = "anthropic", connection_id = "api",
  profile_id = "team", import = false, bind_environment = true, revoke = false }
read()
assert(not failure and #methods.methods == 3)
local env_method
for _, method in ipairs(methods.methods) do
  if method.provider_id == "anthropic" then env_method = method end
end
assert(env_method and env_method.can_import == false
  and env_method.can_bind_environment == true)
local source_result, source_error
runtime.authenticate({ provider_id = "anthropic", connection_id = "api",
  profile_id = "team", kind = "ApiKey" }, "forbidden-import",
  function(value, issue) source_result, source_error = value, issue end)
assert(source_result == nil and source_error and source_error.kind == "denied")
assert(#imported == 0, "env-only profile must not forward a direct secret")
runtime.bind_auth_environment({ provider_id = "anthropic", connection_id = "api",
  profile_id = "team", kind = "ApiKey" }, "ANTHROPIC_API_KEY",
  function(value, issue) source_result, source_error = value, issue end)
assert(not source_error and source_result.kind == "stored")
assert(vim.deep_equal(bound[1],
  { "anthropic", "api", "team", "ANTHROPIC_API_KEY" }))

-- Direct-only grants cannot be used to bind a variable name. Both source
-- choices must follow separate runtime-published operations.
grant.import, grant.bind_environment = true, false
read()
assert(not failure and #methods.methods == 3)
for _, method in ipairs(methods.methods) do
  if method.provider_id == "anthropic" then
    assert(method.can_import and not method.can_bind_environment)
  end
end
runtime.bind_auth_environment({ provider_id = "anthropic", connection_id = "api",
  profile_id = "team", kind = "ApiKey" }, "ANTHROPIC_API_KEY",
  function(value, issue) source_result, source_error = value, issue end)
assert(source_result == nil and source_error and source_error.kind == "denied")
assert(#bound == 1, "direct-only profile must not bind environment source")

grant = nil
for _, method in ipairs(methods.methods) do
  assert(method.kind == "OAuthAuthorizationCode")
end

-- OAuth has no pre-login profile ID. Verified accounts returned by the
-- provider must be displayed by method and exact resulting account, not
-- silently dropped by comparison with nil.
local function find_oauth_method()
  read()
  assert(not failure)
  for _, value in ipairs(methods.methods) do
    if value.provider_id == "openai" and value.connection_id == "chatgpt" then
      return value
    end
  end
  error("ChatGPT OAuth registration not displayed")
end
oauth_status = {
  { id = "sso-user", label = "SSO user", method_id = "oauth",
    status = "Authenticated" },
}
local oauth_method = find_oauth_method()
assert(oauth_method.authenticated and #oauth_method.profiles == 1
  and oauth_method.profiles[1].id == "sso-user",
  "verified OAuth method must surface its resulting named account")
oauth_status[1].status = { Unavailable = { reason = "revoked" } }
assert(not find_oauth_method().authenticated,
  "revoked OAuth account cannot remain authenticated")
oauth_status = {
  { id = "sso-user", label = "SSO user", method_id = "oauth",
    status = "Authenticated" },
  { id = "sso-work", label = "SSO work", method_id = "oauth",
    status = "Authenticated" },
}
oauth_method = find_oauth_method()
assert(oauth_method.authenticated and #oauth_method.profiles == 2,
  "multiple verified OAuth accounts must keep separate identities")
oauth_status[2].id = "sso-user"
assert(not find_oauth_method().authenticated,
  "duplicate OAuth account identities cannot prove authentication")
oauth_status = nil

grant = { provider_id = "openai", connection_id = "api",
  profile_id = "personal", import = true, revoke = true }
read()
assert(not failure and #methods.methods == 3)
local entry = methods.methods[1]
assert(entry.provider_id == "openai" and entry.connection_id == "api")
assert(entry.profile_id == "personal" and entry.kind == "ApiKey")
assert(entry.can_import and entry.can_bind_environment,
  "legacy single-account capability remains supported")
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

-- The fresh provider status, not storage, decides authentication.
reported_status = "Authenticated"
runtime.authenticate({ provider_id = "openai", connection_id = "api",
  profile_id = "personal", method_id = "api-key", kind = "ApiKey" },
  "second-test-key", function(v, e) result, problem = v, e end)
assert(not problem and result.kind == "authenticated" and result.verified
  and result.authenticated)

reported_status = { Unavailable = { reason = "revoked" } }
runtime.authenticate({ provider_id = "openai", connection_id = "api",
  profile_id = "personal", method_id = "api-key", kind = "ApiKey" },
  "third-test-key", function(v, e) result, problem = v, e end)
assert(not problem and result.kind == "stored" and not result.verified,
  "unverified key cannot authenticate merely because it was stored")
-- Credential onboarding is permitted before a session exists, but
-- the model picker must not attempt an ACP catalog request for nil session.
local choices, choice_problem
runtime.list_selections(function(value, err)
  choices, choice_problem = value, err
end)
assert(choices == nil and choice_problem and choice_problem.kind == "not_found",
  "pre-session model selection must give an actionable error")
assert(choice_problem.message:find(":Phenix new", 1, true),
  "tell the user how to create the required session")
-- New runtimes return all separately admitted accounts; the old single
-- capability shape remains supported. Provider status from personal must
-- never authenticate work, and an unrelated provider must be queried.
grant = { profiles = {
  { provider_id = "openai", connection_id = "api", profile_id = "personal",
    import = true, revoke = true },
  { provider_id = "openai", connection_id = "api", profile_id = "work",
    import = true, revoke = true },
  { provider_id = "anthropic", connection_id = "api", profile_id = "team",
    import = true, revoke = true },
} }
reported_status = "Authenticated"
work_status = { Unavailable = { reason = "not verified" } }
anthropic_status = "Authenticated"
read()
assert(not failure and #methods.methods == 5)
local by_id = {}
for _, method in ipairs(methods.methods) do
  if method.profile_id ~= nil then
    by_id[method.provider_id .. "/" .. method.profile_id] = method
  else
    assert(method.kind == "OAuthAuthorizationCode",
      "only OAuth methods may appear without a named profile")
  end
end
assert(by_id["openai/personal"].authenticated)
assert(not by_id["openai/work"].authenticated,
  "verified sibling account must not authenticate work")
assert(by_id["anthropic/team"].authenticated,
  "unrelated authorized provider should be selectable")
runtime.authenticate({ provider_id = "openai", connection_id = "api",
  profile_id = "work", kind = "ApiKey" },
  "different-work-secret", function(v, e) result, problem = v, e end)
assert(not problem and result.profile_id == "work")
assert(vim.deep_equal(imported[#imported], { "openai", "api", "work" }))
runtime.authenticate({ provider_id = "openai", connection_id = "api",
  profile_id = "unauthorized", kind = "ApiKey" },
  "unauthorized-secret", function(v, e) result, problem = v, e end)
assert(result == nil and problem and problem.kind == "denied")
local oauth_polls = 0
function client:begin_provider_auth(provider_id, connection_id, method_id, callback)
  assert(provider_id == "openai" and connection_id == "chatgpt" and method_id == "oauth")
  callback({ OpenBrowser = {
    attempt_id = "authorized-attempt-1", url = "https://auth.example.test/login",
  } }, nil)
end
function client:poll_provider_auth(provider_id, connection_id, attempt_id, callback)
  assert(provider_id == "openai" and connection_id == "chatgpt")
  assert(attempt_id == "authorized-attempt-1")
  oauth_polls = oauth_polls + 1
  if oauth_polls == 1 then
    callback({ AwaitingInput = { challenge = { OpenBrowser = {
      attempt_id = "authorized-attempt-1", url = "https://auth.example.test/login",
    } } } }, nil)
  elseif oauth_polls == 2 then
    callback("Pending", nil)
  else
    callback({ Completed = { profile = {
      id = "sso-user", label = "SSO user", method_id = "oauth",
    } } }, nil)
  end
end
local oauth_result, oauth_error
runtime.authenticate({
  provider_id = "openai", connection_id = "chatgpt",
  method_id = "oauth", kind = "OAuthAuthorizationCode",
}, nil, function(v, e) oauth_result, oauth_error = v, e end)
assert(not oauth_error and oauth_result.kind == "openbrowser")
assert(oauth_result.attempt_id == "authorized-attempt-1")
runtime.poll_authentication(oauth_result, oauth_result.attempt_id,
  function(v, e) oauth_result, oauth_error = v, e end)
assert(not oauth_error and oauth_result.kind == "awaiting_input"
  and oauth_result.url == "https://auth.example.test/login",
  "a provider-issued awaiting-input challenge is not a failure or login")
runtime.poll_authentication(oauth_result, oauth_result.attempt_id,
  function(v, e) oauth_result, oauth_error = v, e end)
assert(not oauth_error and oauth_result.kind == "pending")
runtime.poll_authentication({
  provider_id = "openai", connection_id = "chatgpt", method_id = "oauth",
}, "authorized-attempt-1", function(v, e)
  oauth_result, oauth_error = v, e
end)
assert(not oauth_error and oauth_result.kind == "authenticated"
  and oauth_result.profile_id == "sso-user",
  "only the completed provider attempt verifies OAuth authentication")

-- A forged or mismatched method in a completed attempt is not success.
function client:poll_provider_auth(_, _, _, callback)
  callback({ Completed = { profile = {
    id = "sso-user", label = "SSO user", method_id = "another-method",
  } } }, nil)
end
runtime.poll_authentication({
  provider_id = "openai", connection_id = "chatgpt", method_id = "oauth",
}, "authorized-attempt-1", function(v, e)
  oauth_result, oauth_error = v, e
end)
assert(oauth_result == nil and oauth_error and oauth_error.kind == "protocol",
  "a completed login for the wrong method cannot authenticate this selection")
runtime.disconnect()
print("P1 scoped credentials and OAuth provider-owned attempt lifecycle verified")

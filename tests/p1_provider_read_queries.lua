-- ACP provider read operations remain separate from model/session selection.
-- A successful credential import is never inferred from metadata alone.
local sdk = require("phenix_client")
local transport = require("phenix_client.acp").new({ command = "fake-acp" })
local outgoing
transport.state = "ready"
transport.features = { session_operations = {}, management = {
  models = false, model_selection = false, provider_authentication = false,
} }
transport.job = 1
transport._write = function(_, frame)
  outgoing = frame
  return true
end
local client = sdk.new(transport)
client:start(function(_, err) assert(not err) end)

local status, failure
client:get_provider_auth_status("openai", "api", function(value, err)
  status, failure = value, err
end)
assert(outgoing.method == "_phenix/providers/auth/status")
assert(outgoing.params.scope == "user")
assert(outgoing.params.provider_id == "openai")
assert(outgoing.params.connection_id == "api")
assert(outgoing.params.secret == nil)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { provider_id = "openai", connection_id = "api", profiles = {
    { id = "personal", label = "Personal", method_id = "api-key",
      valid = false, reason = "not verified" },
  } },
})
assert(not failure and status.profiles[1].valid == false)
assert(not client:capabilities().management.provider_authentication)

local invalid, protocol_problem
client:get_provider_auth_status("openai", "api", function(value, err)
  invalid, protocol_problem = value, err
end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { provider_id = "anthropic", connection_id = "api", profiles = {} },
})
assert(invalid == nil and protocol_problem.kind == "protocol")

client:get_provider_auth_status("openai", "api", function(value, err)
  invalid, protocol_problem = value, err
end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { provider_id = "openai", connection_id = "api", profiles = {
    { id = "one", method_id = "key", valid = true },
    { id = "one", method_id = "key", valid = true },
  } },
})
assert(invalid == nil and protocol_problem.kind == "protocol",
  "duplicate credential profile IDs cannot become selectable")

client:get_provider_auth_status("openai", "api", function(value, err)
  invalid, protocol_problem = value, err
end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  error = { code = -32601, message = "Method not found" },
})
assert(invalid == nil and protocol_problem.kind == "unsupported",
  "older ACP hosts must fail closed")

local models, models_error
client:get_provider_models("openai", "api", function(value, err)
  models, models_error = value, err
end)
assert(outgoing.method == "_phenix/providers/models")
assert(outgoing.params.scope == "user" and outgoing.params.limit == 64)
assert(outgoing.params.profile_id == nil)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  error = { code = -32602, message = "Invalid params", data = {
    format = "phenix.provider.error.v1", code = "AuthenticationRequired",
    message = "MALICIOUS_PROVIDER_BODY_MUST_NOT_BE_SHOWN",
  } },
})
assert(models == nil and models_error.provider_code == "AuthenticationRequired")
assert(not tostring(models_error.message):find("MALICIOUS_PROVIDER_BODY", 1, true))

client:get_provider_models("openai", "api", { profile_id = "personal", limit = 2 },
  function(value, err) models, models_error = value, err end)
assert(outgoing.params.profile_id == "personal")
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { profile_id = "personal", revision = 11, next_cursor = vim.NIL,
    models = { {
      id = "example-model", label = "Example Model", connection_id = "api",
      protocol_id = "openai-responses", endpoint_id = "responses",
      capabilities = {}, origin = "Discovered", selectable = false,
    } },
  },
})
assert(not models_error and models.revision == 11)
assert(models.models[1].selectable == false)
assert(not client:capabilities().management.model_selection,
  "provider model discovery does not authorize ACP model selection")

client:get_provider_models("openai", "api",
  function(value, err) models, models_error = value, err end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { profile_id = vim.NIL, revision = 13, next_cursor = vim.NIL,
    models = {} },
})
assert(not models_error and #models.models == 0,
  "explicit JSON null is an absent optional profile/cursor")

client:get_provider_models("openai", "api",
  function(value, err) models, models_error = value, err end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { profile_id = vim.NIL, revision = 14, next_cursor = vim.NIL,
    models = { {
      id = "cross-connection", label = "Forged", connection_id = "chatgpt",
      protocol_id = "openai-responses", endpoint_id = "other",
      origin = "Declared", selectable = true,
    } } },
})
assert(models == nil and models_error.kind == "protocol",
  "foreign connection model identities cannot become client choices")

-- A trusted host may disclose its exact granted account, not a token.
local granted, problem
client:credential_capabilities(function(value, err) granted, problem = value, err end)
assert(outgoing.method == "_phenix/credentials/capabilities")
transport:_response({ jsonrpc = "2.0", id = outgoing.id, result = {
  provider_id = "openai", connection_id = "api", profile_id = "personal",
  import = true, revoke = true,
} })
assert(not problem and granted.profile_id == "personal")
assert(not client:capabilities().management.provider_authentication)

client:credential_capabilities(function(value, err) granted, problem = value, err end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  error = { code = -32601, message = "Method not found" } })
assert(granted == nil and problem.kind == "unsupported")
-- Credential import/revoke are separate host grants. Acknowledgement is
-- storage-only and must never become an authenticated provider status.
local imported, imported_error
local secret = "fake-test-key-DO-NOT-LOG"
client:import_credential("openai", "api", "personal", secret, function(value, err)
  imported, imported_error = value, err
end)
assert(outgoing.method == "_phenix/credentials/import")
assert(outgoing.params.provider_id == "openai"
  and outgoing.params.connection_id == "api"
  and outgoing.params.profile_id == "personal")
assert(outgoing.params.secret == secret)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { ok = true } })
assert(not imported_error and imported.stored and imported.authenticated == false)
assert(not client:capabilities().management.provider_authentication)

local revoked, revoke_error
client:revoke_credential("openai", "api", "personal", function(value, err)
  revoked, revoke_error = value, err
end)
assert(outgoing.method == "_phenix/credentials/revoke")
assert(outgoing.params.secret == nil)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { ok = true } })
assert(not revoke_error and revoked.revoked and revoked.authenticated == false)

client:import_credential("openai", "api", "work", secret, function(value, err)
  imported, imported_error = value, err
end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  error = { code = -32602, message = "fake-test-key-DO-NOT-LOG", data = {
    format = "phenix.provider.error.v1", code = "Denied",
    message = "fake-test-key-DO-NOT-LOG",
  } },
})
assert(imported == nil and imported_error.provider_code == "Denied")
assert(not imported_error.message:find(secret, 1, true))

client:import_credential("openai", "api", "personal", secret, function(value, err)
  imported, imported_error = value, err
end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  error = { code = -32601, message = "Method not found" },
})
assert(imported == nil and imported_error.kind == "unsupported")

client:revoke_credential("openai", "api", "personal", function(value, err)
  revoked, revoke_error = value, err
end)
transport:_response({ jsonrpc = "2.0", id = outgoing.id,
  result = { ok = false } })
assert(revoked == nil and revoke_error.kind == "protocol")

client:close()
print("Provider read queries and scoped credential calls validated without granting authority")

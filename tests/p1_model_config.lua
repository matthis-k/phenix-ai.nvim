-- Session-local overrides use ACP; pre-session defaults use Phenix control state.
local backend = require("phenix_client.acp").new({ command = "unused" })
backend.state = "ready"
backend.features = { management = { models = false, model_selection = false } }

local function model_option(selected)
  return { id = "model", category = "model", type = "select",
    currentValue = selected, options = {
      { name = "Runtime One", value = "provider/one" },
      { name = "Runtime Two", value = "provider/two" },
    } }
end

backend:_catalog("s1", { model_option("provider/one") })
assert(backend.features.management.models)
assert(backend.features.management.model_selection)
local sent, selected, failure
backend._request = function(_, method, params, callback)
  sent = { method = method, params = params }
  callback({ configOptions = { model_option("provider/two") } }, nil)
end
backend:call("models.select", { session_id = "s1", model_id = "provider/two" }, function(v, err)
  selected, failure = v, err
end)
assert(failure == nil, vim.inspect(failure))
assert(selected.selected == "provider/two")
assert(sent.method == "session/set_config_option")
assert(sent.params.sessionId == "s1" and sent.params.configId == "model")
assert(sent.params.value == "provider/two")
assert(backend.catalogs.s1.selected == "provider/two")

-- Never send a forged model to the runtime or report a local optimistic switch.
sent = nil
backend:call("models.select", { session_id = "s1", model_id = "forged" }, function(v, err)
  assert(v == nil and err.kind == "denied")
end)
assert(sent == nil and backend.catalogs.s1.selected == "provider/two")

backend._request = function(_, _, _, callback)
  callback(nil, { kind = "denied", message = "runtime denied" })
end
backend:call("models.select", { session_id = "s1", model_id = "provider/one" }, function(v, err)
  assert(v == nil and err.kind == "denied")
end)
assert(backend.catalogs.s1.selected == "provider/two")

backend._request = function(_, _, _, callback)
  callback({ configOptions = { model_option("provider/one") } }, nil)
end
backend:call("models.select", { session_id = "s1", model_id = "provider/two" }, function(v, err)
  assert(v == nil and err.kind == "protocol")
end)
assert(backend.catalogs.s1.selected == "provider/one",
  "projection follows runtime response, never requested input")
-- Selection cannot inherit the last-active session if several catalogs are
-- available. The SDK must supply a stable session ID for each mutation.
backend:_catalog("s2", { model_option("provider/two") })
backend._request = function(_, method, params, callback)
  assert(method == "_phenix/control/state")
  callback({ format = "phenix.control.state.v1", phase = "ready",
    models = {}, actions = {}, selected = vim.NIL }, nil)
end
backend:call("models.list", {}, function(value, problem)
  assert(not problem and #value.models == 0,
    "no-session model discovery must not borrow a session catalog")
end)

-- A failed ChatGPT OAuth model catalog must keep its typed failure code,
-- without displaying any provider-controlled response or requiring a session.
backend._request = function(_, method, _, callback)
  assert(method == "_phenix/control/state")
  callback({
    format = "phenix.control.state.v1", phase = "ready",
    models = {}, actions = {}, selected = vim.NIL,
    model_denials = {
      { provider_id = "openai", connection_id = "chatgpt",
        code = "catalog_unauthorized", message = "sensitive provider prose" },
    },
  }, nil)
end
backend:call("models.list", {}, function(value, problem)
  assert(not problem and #value.models == 0)
  assert(#value.denials == 1 and value.denials[1].code == "catalog_unauthorized")
  assert(value.denials[1].message == nil, "untrusted provider message escaped ACP")
end)
local picker_result, picker_error
require("phenix_client.nvim").choose_model({
  list_models = function(_, session, cb)
    assert(session == nil, "no session was expected for catalog diagnosis")
    backend:call("models.list", {}, cb)
  end,
}, nil, function(value, problem)
  picker_result, picker_error = value, problem
end, function()
  error("unauthorized catalog must not show a model picker")
end)
assert(picker_result == nil and picker_error
  and picker_error.message:find("sign in with ChatGPT again", 1, true)
  and not picker_error.message:find("sensitive provider prose", 1, true),
  "ChatGPT catalog denial did not surface a safe actionable reason")

backend:call("models.list", { session_id = "s1" }, function(value, problem)
  assert(not problem and value.selected == "provider/one")
end)
local attempts = 0
backend._request = function(_, method, params, callback)
  attempts = attempts + 1
  assert(method == "session/set_config_option")
  assert(params.sessionId == "s1")
  callback({ configOptions = { model_option("provider/two") } }, nil)
end
-- Pre-session selection never uses an arbitrary previously active session.
-- This synthetic response rejects an invalid default ID without consulting
-- the session/config mutation path.
backend._request = function(_, method, params, callback)
  assert(method == "_phenix/models/select" and params.value == "provider/two")
  callback(nil, { kind = "denied", message = "Model was not offered" })
end
backend:call("models.select", { model_id = "provider/two" }, function(value, problem)
  assert(value == nil and problem.kind == "denied")
end)
assert(attempts == 0, "default request must not mutate any session")
backend._request = function(_, method, params, callback)
  attempts = attempts + 1
  assert(method == "session/set_config_option")
  assert(params.sessionId == "s1")
  callback({ configOptions = { model_option("provider/two") } }, nil)
end
backend:call("models.select", {
  session_id = "s1", model_id = "provider/two",
}, function(value, problem)
  assert(value and not problem)
end)
assert(attempts == 1, "explicit session was not used")

-- Removal of a runtime model option is a revocation, not silence. Only
-- the affected session loses its catalog; other sessions remain selectable.
local updates = {}
local stop_updates = backend:subscribe(function(event)
  if event.type == "models.changed" then
    updates[#updates + 1] = event
  end
end)
backend:_catalog("s1", {})
assert(backend.catalogs.s1 == nil, "removed runtime catalog must not remain cached")
assert(#updates == 1 and updates[1].session_id == "s1"
  and updates[1].catalog == nil,
  "removing the model option must notify subscribers of revocation")
assert(backend.features.management.models and backend.features.management.model_selection,
  "revoking one session must not revoke another session's model capability")
backend:call("models.list", { session_id = "s1" }, function(value, problem)
  assert(value == nil and problem.kind == "unsupported",
    "revoked models must not remain discoverable")
end)
backend:call("models.list", { session_id = "s2" }, function(value, problem)
  assert(not problem and value.selected == "provider/two",
    "another session's catalog must remain available")
end)
backend:call("models.select", {
  session_id = "s1", model_id = "provider/one",
}, function(value, problem)
  assert(value == nil and problem.kind == "unsupported",
    "revoked model must not be submitted to ACP")
end)
assert(attempts == 1, "revoked selection escaped into ACP")

-- A malformed replacement (selected value no longer offered) also revokes.
backend:_catalog("s2", { model_option("retired") })
assert(backend.catalogs.s2 == nil)
assert(#updates == 2 and updates[2].session_id == "s2"
  and updates[2].catalog == nil, "invalidated catalog must publish revocation")
assert(not backend.features.management.models
  and not backend.features.management.model_selection,
  "the last revoked catalog must remove the model capabilities")
backend:_catalog("s2", {})
assert(#updates == 2, "an already absent catalog must not emit duplicate revocation")

-- ACP v1 pushes the complete config option set through session/update,
-- including concurrent selection changes and entitlement revocation.
local function config_update(options)
  backend:_response({ jsonrpc = "2.0", method = "session/update",
    params = { sessionId = "s2", update = {
      sessionUpdate = "config_option_update", configOptions = options,
    } },
  })
end
config_update({ model_option("provider/one") })
assert(backend.catalogs.s2.selected == "provider/one")
assert(#updates == 3 and updates[3].catalog.selected == "provider/one",
  "a pushed model configuration must refresh the session catalog")
config_update({})
assert(backend.catalogs.s2 == nil)
assert(#updates == 4 and updates[4].catalog == nil,
  "a pushed empty option set must retract the model selection")
assert(not backend.features.management.models,
  "an ACP revocation must clear aggregate model capability")
backend:_response({ jsonrpc = "2.0", method = "session/update",
  params = { sessionId = "s2", update = {
    sessionUpdate = "config_option_update", configOptions = "invalid",
  } },
})
assert(#updates == 4, "malformed notifications must not mutate the catalog")

-- A late set_config_option reply is not newer than a pushed runtime update.
-- Never let that reply restore choices revoked while the request was pending.
backend:_catalog("s1", { model_option("provider/one") })
local pending, result, selection_error
backend._request = function(_, method, params, callback)
  assert(method == "session/set_config_option" and params.sessionId == "s1")
  pending = callback
end
backend:call("models.select", {
  session_id = "s1", model_id = "provider/two",
}, function(value, problem)
  result, selection_error = value, problem
end)
assert(pending ~= nil and result == nil)
backend:_response({ jsonrpc = "2.0", method = "session/update",
  params = { sessionId = "s1", update = {
    sessionUpdate = "config_option_update", configOptions = {},
  } },
})
assert(backend.catalogs.s1 == nil)
pending({ configOptions = { model_option("provider/two") } }, nil)
assert(result == nil and selection_error and selection_error.kind == "conflict",
  "late selection reply must reject after runtime revoked a catalog")
assert(backend.catalogs.s1 == nil and backend.catalogs.s2 == nil,
  "late selection reply resurrected revoked choices")

-- Notifications for an unrelated session must not invalidate this session's
-- in-flight operation. Both catalogs are scoped to their own session.
backend:_catalog("s1", { model_option("provider/one") })
backend:_catalog("s2", { model_option("provider/one") })
pending, result, selection_error = nil, nil, nil
backend:call("models.select", {
  session_id = "s1", model_id = "provider/two",
}, function(value, problem)
  result, selection_error = value, problem
end)
assert(pending ~= nil)
backend:_catalog("s2", { model_option("provider/two") })
pending({ configOptions = { model_option("provider/two") } }, nil)
assert(result and result.selected == "provider/two" and selection_error == nil,
  "an unrelated session update incorrectly blocked a verified response")

-- Two outstanding replies can complete in reverse order. A later accepted
-- response must not be rolled back by the first request's old snapshot.
backend:_catalog("s1", { model_option("provider/one") })
local callbacks, results = {}, {}
backend._request = function(_, _, params, callback)
  assert(params.sessionId == "s1")
  callbacks[#callbacks + 1] = callback
end
backend:call("models.select", {
  session_id = "s1", model_id = "provider/two",
}, function(value, problem)
  results[1] = { value = value, problem = problem }
end)
backend:call("models.select", {
  session_id = "s1", model_id = "provider/one",
}, function(value, problem)
  results[2] = { value = value, problem = problem }
end)
assert(#callbacks == 2)
callbacks[2]({ configOptions = { model_option("provider/one") } }, nil)
callbacks[1]({ configOptions = { model_option("provider/two") } }, nil)
assert(results[2].value and results[2].problem == nil)
assert(results[1].value == nil and results[1].problem.kind == "conflict",
  "out-of-order selection reply must not overwrite a later response")
assert(backend.catalogs.s1.selected == "provider/one")
-- Ambiguous runtime model config must revoke the whole selection, not
-- retain a first-match option or let two entries share the same model ID.
backend:_catalog("s1", { model_option("provider/one") })
local duplicate_choices = model_option("provider/one")
duplicate_choices.options[#duplicate_choices.options + 1] = {
  name = "Spoofed duplicate", value = "provider/one",
}
backend:_catalog("s1", { duplicate_choices })
assert(backend.catalogs.s1 == nil,
  "duplicate model IDs must revoke the authoritative catalog")

backend:_catalog("s1", {
  model_option("provider/one"), model_option("provider/two"),
})
assert(backend.catalogs.s1 == nil,
  "two model options must not let the first response win")
backend:_catalog("s1", {
  { id = "model", category = "model", type = "text" },
  model_option("provider/one"),
})
assert(backend.catalogs.s1 == nil,
  "invalid model option followed by valid one must fail closed")
local malformed = model_option("provider/one")
malformed.options[2] = { name = "Missing model ID" }
backend:_catalog("s1", { malformed })
assert(backend.catalogs.s1 == nil,
  "invalid model entry must not be silently skipped")

local unauthorized_requests = 0
backend._request = function()
  unauthorized_requests = unauthorized_requests + 1
end
backend:call("models.select", {
  session_id = "s1", model_id = "provider/one",
}, function(value, problem)
  assert(value == nil and problem.kind == "unsupported",
    "ambiguous/revoked model must not become a mutating ACP request")
end)
assert(unauthorized_requests == 0)
backend:_catalog("s1", { model_option("provider/one") })
assert(backend.catalogs.s1.selected == "provider/one",
  "a subsequent unique authoritative catalog must restore only that selection")

-- The runtime may supply opaque, complete native HTTP selection IDs.
-- A model name alone cannot alias different provider account identities;
-- Neovim must preserve the exact runtime ID rather than decoding it or
-- authorizing a locally synthesized provider/model pairing.
local account_a = 'phenix.native-model@1:{"provider_id":"fixture","profile_id":"personal","model_id":"same-model"}'
local account_b = 'phenix.native-model@1:{"provider_id":"fixture","profile_id":"work","model_id":"same-model"}'
local opaque_option = {
  id = "model", category = "model", type = "select",
  currentValue = account_a,
  options = {
    { value = account_a, name = "Fixture / Personal / Same Model" },
    { value = account_b, name = "Fixture / Work / Same Model" },
  },
}
backend:_catalog("opaque-session", { opaque_option })
backend:call("models.list", { session_id = "opaque-session" }, function(value, problem)
  assert(not problem and #value.models == 2)
  assert(value.models[1].id ~= value.models[2].id,
    "model labels must not collapse distinct native selection identities")
end)
local opaque_requests = 0
backend._request = function(_, method, params, callback)
  opaque_requests = opaque_requests + 1
  assert(method == "session/set_config_option")
  assert(params.sessionId == "opaque-session" and params.value == account_b)
  local selected_option = vim.deepcopy(opaque_option)
  selected_option.currentValue = account_b
  callback({ configOptions = { selected_option } }, nil)
end
backend:call("models.select", {
  session_id = "opaque-session", model_id = account_b,
}, function(value, problem)
  assert(not problem and value.selected == account_b)
end)
assert(opaque_requests == 1)
backend:call("models.select", {
  session_id = "opaque-session",
  model_id = 'phenix.native-model@1:{"provider_id":"fixture","profile_id":"forged","model_id":"same-model"}',
}, function(value, problem)
  assert(not value and problem.kind == "denied",
    "client must not submit an unadvertised native selection identity")
end)
assert(opaque_requests == 1)

-- The runtime CAS advances the session revision after selecting a model.
-- It returns a new opaque ID, preserving the exact selected model identity.
local function native_id(model, revision)
  return "phenix.native-model@1:" .. vim.json.encode({
    provider_id = "fixture", connection_id = "local", profile_id = vim.NIL,
    model_id = model, protocol_id = "openai-chat", endpoint_id = "chat",
    catalog_revision = 7, session_revision = revision,
  })
end
local function revision_option(model, revision)
  return {
    id = "model", category = "model", type = "select",
    currentValue = native_id(model, revision),
    options = {
      { value = native_id("a", revision), name = "Model A" },
      { value = native_id("b", revision), name = "Model B" },
    },
  }
end
backend:_catalog("rev-session", { revision_option("a", 0) })
backend._request = function(_, method, params, callback)
  assert(method == "session/set_config_option")
  assert(params.value == native_id("b", 0))
  callback({ configOptions = { revision_option("b", 1) } }, nil)
end
backend:call("models.select", {
  session_id = "rev-session", model_id = native_id("b", 0),
}, function(value, problem)
  assert(not problem and value.selected == native_id("b", 1),
    "confirmed selected ID must rotate to the next session revision")
end)
assert(backend.catalogs["rev-session"].selected == native_id("b", 1))
backend._request = function(_, _, params, callback)
  assert(params.value == native_id("a", 1))
  callback({ configOptions = { revision_option("a", 3) } }, nil)
end
backend:call("models.select", {
  session_id = "rev-session", model_id = native_id("a", 1),
}, function(value, problem)
  assert(value == nil and problem.kind == "protocol",
    "a skipped session revision is not a confirmed ACP CAS response")
end)
backend:_catalog("rev-session", { revision_option("b", 1) })
backend._request = function(_, _, params, callback)
  assert(params.value == native_id("a", 1))
  callback({ configOptions = { revision_option("b", 2) } }, nil)
end
backend:call("models.select", {
  session_id = "rev-session", model_id = native_id("a", 1),
}, function(value, problem)
  assert(value == nil and problem.kind == "protocol",
    "different returned model identity is not a confirmed selection")
end)

stop_updates()

print("ACP model selection rejects ambiguous, stale and invalid revision choices")

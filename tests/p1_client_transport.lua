-- Stable ACP v1 transport, independent of the Neovim presentation.
local sent, process, killed = {}, nil, false
vim.fn.jobstart = function(argv, opts)
  assert(argv[1] == "phenix-basic-acp")
  process = opts
  return 21
end
vim.fn.chansend = function(job, raw)
  assert(job == 21)
  sent[#sent + 1] = vim.json.decode(raw)
  return #raw
end
vim.fn.jobstop = function(job)
  assert(job == 21)
  killed = true
  return 1
end
local backend = require("phenix_client.acp").new({ command = "phenix-basic-acp" })
local sdk = require("phenix_client").new(backend)
local notifications = {}
sdk:on("session.updated", function(event)
  notifications[#notifications + 1] = event
end)
local function receive(data)
  process.on_stdout(21, { vim.json.encode(data), "" })
end

local ready
sdk:start(function(value, err)
  assert(not err)
  ready = value
end)
assert(sent[1].method == "initialize")
assert(sent[1].params.protocolVersion == 1)
receive({ jsonrpc = "2.0", id = sent[1].id,
  result = { protocolVersion = 1, agentCapabilities = { loadSession = true } } })
assert(ready and ready.session_operations.new and ready.session_operations.load)
assert(ready.management.models == true)
assert(#sent == 1, "ACP extensions remain runtime-authorized per request")

local id
sdk:new_session(function(value, err)
  assert(not err)
  id = value.session_id
end)
assert(sent[2].method == "session/new")
receive({ jsonrpc = "2.0", id = sent[2].id, result = {
  sessionId = "s1",
  configOptions = { {
    id = "model", name = "Model", category = "model", type = "select",
    currentValue = "phenix.model.scripted",
    options = { { value = "phenix.model.scripted", name = "Scripted model" } },
  } },
} })
assert(id == "s1")
local catalog
sdk:list_models("s1", function(value, err)
  assert(not err)
  catalog = value
end)
assert(catalog and catalog.session_id == "s1")
assert(catalog.selected == "phenix.model.scripted")
assert(#catalog.models == 1 and catalog.models[1].name == "Scripted model")
assert(#sent == 2, "model query reads runtime-advertised ACP config, not a custom request")
local denied
sdk:set_model("s1", "unknown", function(value, err)
  denied = err
end)
assert(denied and denied.kind == "denied", "unadvertised model IDs must be rejected before ACP dispatch")
local finish
sdk:send(id, "hello", function(value, err)
  assert(not err)
  finish = value
end)
assert(sent[3].method == "session/prompt")
assert(sent[3].params.sessionId == id)
assert(sent[3].params.prompt[1].text == "hello")
receive({ jsonrpc = "2.0", method = "session/update",
  params = { sessionId = id,
    update = { sessionUpdate = "agent_message_chunk",
      content = { type = "text", text = "mock:hello" } } } })
assert(#notifications == 1 and notifications[1].session_id == id)
receive({ jsonrpc = "2.0", id = sent[3].id, result = { stopReason = "end_turn" } })
assert(finish.stop_reason == "end_turn")

local cancelled = false
sdk:cancel(id, function(value, err)
  assert(not err)
  cancelled = value == true
end)
assert(cancelled and sent[4].method == "session/cancel" and sent[4].id == nil)

-- Two open sessions can advertise different runtime-selected models. A
-- selector for s1 must never silently show s2's last observed state.
local other
sdk:new_session(function(value, err)
  assert(not err)
  other = value.session_id
end)
assert(sent[5].method == "session/new")
receive({ jsonrpc = "2.0", id = sent[5].id, result = {
  sessionId = "s2",
  configOptions = { {
    id = "model", name = "Model", category = "model", type = "select",
    currentValue = "phenix.model.second",
    options = { { value = "phenix.model.second", name = "Second" } },
  } },
} })
assert(other == "s2")
local first_catalog, second_catalog
sdk:list_models("s1", function(value, err)
  assert(not err)
  first_catalog = value
end)
sdk:list_models("s2", function(value, err)
  assert(not err)
  second_catalog = value
end)
assert(first_catalog.selected == "phenix.model.scripted")
assert(second_catalog.selected == "phenix.model.second")
assert(#sent == 5, "model snapshots are already returned by Phenix")

-- Input data is forwarded to the runtime as ACP content, without Neovim
-- implementing the resource or model semantics.
local rich_result
sdk:send_content("s1", {
  { type = "text", text = "reference" },
  { type = "resource_link", name = "notes", uri = "file:///tmp/notes.md" },
}, function(value, err)
  assert(not err)
  rich_result = value
end)
assert(sent[6].method == "session/prompt")
assert(sent[6].params.sessionId == "s1")
assert(sent[6].params.prompt[2].uri == "file:///tmp/notes.md")
receive({ jsonrpc = "2.0", id = sent[6].id,
  result = { stopReason = "end_turn" } })
assert(rich_result.stop_reason == "end_turn")

-- A new session without model config cannot hide the catalog previously
-- advertised for another session. Availability is scoped to catalog data,
-- not to whichever session supplied the last ACP response.
local no_model_session
sdk:new_session(function(value, err)
  assert(not err)
  no_model_session = value.session_id
end)
assert(sent[7].method == "session/new")
receive({ jsonrpc = "2.0", id = sent[7].id,
  result = { sessionId = "s3", configOptions = {} } })
assert(no_model_session == "s3")
local retained, absent
sdk:list_models("s1", function(value, err)
  assert(not err)
  retained = value
end)
sdk:list_models("s3", function(_, err) absent = err end)
assert(retained and retained.selected == "phenix.model.scripted")
assert(absent and absent.kind == "unsupported")
assert(#sent == 7, "per-session model discovery must not add custom ACP RPCs")

-- The ACP controller places the safe Storage failure in error.data, not
-- necessarily in message. Preserve its actionable diagnosis in the UI.
local storage_error
sdk:send("s1", "diagnostic", function(_, err) storage_error = err end)
assert(sent[8].method == "session/prompt")
receive({ jsonrpc = "2.0", id = sent[8].id, error = {
  code = -32603, message = "Internal error",
  data = "PHENIX_BASIC_SQLITE_PATH is required for session ownership",
} })
assert(storage_error and storage_error.kind == "remote")
assert(storage_error.message:find("PHENIX_BASIC_SQLITE_PATH", 1, true))

-- An unknown provider's error data is not trusted as UI diagnostic text.
local remote_error
sdk:send("s1", "provider-error", function(_, err) remote_error = err end)
assert(sent[9].method == "session/prompt")
receive({ jsonrpc = "2.0", id = sent[9].id, error = {
  code = -32603, message = "Internal error",
  data = "opaque provider response",
} })
assert(remote_error and remote_error.message == "Internal error")
assert(remote_error.data == nil, "opaque provider error data escaped into UI callers")

local auth_failure
sdk:send("s1", "invalid credential", function(_, err) auth_failure = err end)
assert(sent[10].method == "session/prompt")
receive({ jsonrpc = "2.0", id = sent[10].id, error = {
  code = -32603, message = "Internal error",
  data = "ModelFailed: HTTP model status 401",
} })
assert(auth_failure and auth_failure.message:find("HTTP model status 401", 1, true),
  "the user must see the actionable credential failure")

-- New runtimes preserve the BasicError enum code in standard JSON-RPC
-- error.data. Never infer the code from provider-controlled message text.
local typed_storage
sdk:send("s1", "storage failed", function(_, err) typed_storage = err end)
receive({ jsonrpc = "2.0", id = sent[11].id, error = {
  code = -32603, message = "Internal error",
  data = { format = "phenix.basic.error.v1", code = "StorageFailed",
    message = "SQLite database cannot be opened" },
} })
assert(typed_storage and typed_storage.basic_code == "StorageFailed")
assert(typed_storage.message == "SQLite database cannot be opened")
assert(typed_storage.data == nil, "typed Basic error exposes normalized code, not raw payload")

local forged_error
sdk:send("s1", "forged error", function(_, err) forged_error = err end)
receive({ jsonrpc = "2.0", id = sent[12].id, error = {
  code = -32603, message = "Internal error",
  data = { format = "other.protocol", code = "StorageFailed",
    message = "exfiltrate sensitive information" },
} })
assert(forged_error and forged_error.basic_code == nil
  and forged_error.message == "Internal error" and forged_error.data == nil,
  "unknown error payloads must not override ACP diagnostics")

local nested_error
sdk:send("s1", "nested error", function(_, err) nested_error = err end)
receive({ jsonrpc = "2.0", id = sent[13].id, error = {
  code = -32603, message = "Internal error",
  data = { format = "phenix.basic.error.v1", code = "ModelFailed",
    message = "HTTP model status 401\nTOKEN=secret" },
} })
assert(nested_error and nested_error.message == "Internal error",
  "multiline provider data must not become a frontend notification")
assert(nested_error.data == nil, "untrusted multiline provider data leaked to callbacks")
assert(not vim.inspect(nested_error):find("TOKEN=secret", 1, true),
  "UI inspection must never reveal untrusted error data")

-- A typed OAuth sign-out result says local removal succeeded but the
-- issuer's remote revocation could not be confirmed. Preserve only the
-- enumerated provider code; never expose raw provider response text.
local remote_logout
sdk:revoke_credential("openai", "chatgpt", "personal", function(_, err)
  remote_logout = err
end)
local request_id = sent[#sent].id
assert(sent[#sent].method == "_phenix/credentials/revoke")
receive({ jsonrpc = "2.0", id = request_id, error = {
  code = -32602, message = "Invalid params",
  data = {
    format = "phenix.provider.error.v1",
    code = "RemoteRevocationUnconfirmed",
    message = "SECRET=untrusted-provider-body",
  },
} })
assert(remote_logout and remote_logout.provider_code == "RemoteRevocationUnconfirmed")
assert(remote_logout.message == "Phenix credential operation rejected")
assert(not vim.inspect(remote_logout):find("SECRET=", 1, true))

local forged_provider_error
sdk:revoke_credential("openai", "chatgpt", "personal", function(_, err)
  forged_provider_error = err
end)
receive({ jsonrpc = "2.0", id = sent[#sent].id, error = {
  code = -32602, message = "Invalid params",
  data = { format = "phenix.provider.error.v1", code = "ForgedRevocationSucceeded" },
} })
assert(forged_provider_error and forged_provider_error.provider_code == nil,
  "undocumented provider error must not become an authoritative state")

sdk:close()
assert(killed)

-- ACP stderr may contain provider output, request dumps or credentials.
-- A failing process must not forward those bytes into any UI callback.
local exit_failure
local leaking = require("phenix_client.acp").new({ command = "phenix-basic-acp" })
leaking:start(function(_, err) exit_failure = err end)
process.on_stderr(21, { "provider stderr TOKEN=secret", "" })
process.on_exit(21, 1)
assert(exit_failure and exit_failure.kind == "transport")
assert(exit_failure.message:find("exited (1)", 1, true))
assert(not vim.inspect(exit_failure):find("TOKEN=secret", 1, true),
  "ACP process stderr reached an error callback")
leaking:close()

-- An invalid executable is an ordinary transport failure, even when
-- Neovim throws E475 rather than returning a negative job ID. All startup
-- waiters must finish and the caller remains free to build a fresh client.
vim.fn.jobstart = function()
  error("Vim:E475: Invalid value for argument cmd: executable not found")
end
local broken = require("phenix_client.acp").new({ command = "/missing/phenix-acp" })
local failed, startup_error = 0, nil
broken:start(function(value, err)
  assert(value == nil)
  failed = failed + 1
  startup_error = err
end)
assert(failed == 1 and startup_error and startup_error.kind == "transport")
assert(broken.state == "failed")
assert(startup_error.message:find("/missing/phenix-acp", 1, true))
broken:close()
assert(failed == 1, "closing a failed launch cannot settle the waiter twice")
print("P1 client transport contract passed")

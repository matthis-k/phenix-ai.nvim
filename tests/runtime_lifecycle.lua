-- Deterministic lifecycle boundary: control native completion/event order explicitly.
local clients = {}
local next_client
local connect_count = 0
local function pending()
  return { poll = function() return false end }
end
local function completed(value)
  return { poll = function() return true, value, nil end }
end
local function failed(error)
  return { poll = function() return true, nil, error end }
end
local function client()
  local value = {
    events = {},
    closed = 0,
    creates = 0,
    session_closes = 0,
    default_selection = "model.old",
    default_selection_calls = {},
  }
  value.session = {
    id = function() return "session.test" end,
    info = function() return { session_id = "session.test" } end,
    projection = function() return nil end,
    close = function()
      value.session_closes = value.session_closes + 1
      return completed({})
    end,
  }
  value.sessions_api = {
    create = function()
      value.creates = value.creates + 1
      return completed(value.session)
    end,
    cached = function() return value.session end,
    list = function() return pending() end,
  }
  function value:sessions() return self.sessions_api end
  function value:selections()
    return completed({ selected = self.default_selection, available = {} })
  end
  function value:select(selection_id)
    self.default_selection = selection_id
    table.insert(self.default_selection_calls, selection_id)
    return completed({ selected = selection_id, available = {} })
  end
  function value:features() return self.features_value or {} end
  function value:status() return { state = self.phase or "connecting" } end
  function value:pump()
    if self.pump_error then error(self.pump_error) end
    local events = self.events
    self.events = {}
    return events
  end
  function value:close() self.closed = self.closed + 1 end
  function value:status_event(phase, err)
    self.phase = phase
    table.insert(self.events, { kind = "status", data = { state = phase, error = err } })
  end
  clients[#clients + 1] = value
  return value
end
package.loaded.phenix = { application = { connect = function()
  connect_count = connect_count + 1
  return next_client
end } }
local runtime = require("phenix_nvim.runtime")
local frontend = require("phenix_nvim")
local config = require("phenix_nvim.config")
runtime.configure(config.setup({ auto_connect = false, poll_interval_ms = 60000 }))

local function result()
  local value = { calls = 0 }
  function value.callback(response, err)
    value.calls = value.calls + 1
    value.response = response
    value.error = err
  end
  return value
end

-- Early requests share one bootstrap and become usable only after ready.
next_client = client()
local first, second = result(), result()
frontend.new_session(first.callback)
runtime.new_session(second.callback)
assert(connect_count == 1 and first.calls == 0 and next_client.creates == 0)
next_client:status_event("ready")
runtime.tick()
assert(first.calls == 1 and second.calls == 1 and first.error == nil)
assert(next_client.creates == 2)
runtime.disconnect()

-- Session event bursts fetch one projection per touched session per poll rather
-- than rebuilding the same full projection for every event.
next_client = client()
local projection_calls = 0
next_client.session.projection = function()
  projection_calls = projection_calls + 1
  return {
    session = { session_id = "session.test" },
    through_sequence = 0,
    updates = {},
  }
end
runtime.connect()
next_client:status_event("ready")
runtime.tick()
table.insert(next_client.events, { kind = "session_update", data = { session_id = "session.test" } })
table.insert(next_client.events, { kind = "session_update", data = { session_id = "session.test" } })
runtime.tick()
assert(projection_calls == 1, "one poll must refresh a touched session projection once")
runtime.disconnect()

-- Every queued waiter gets the original structured startup error exactly once.
next_client = client()
local bootstrap, waiting = result(), result()
runtime.connect(bootstrap.callback)
runtime.new_session(waiting.callback)
local failure = { kind = "transport", code = "transport", message = "routing startup failed" }
next_client:status_event("failed", failure)
runtime.tick()
assert(bootstrap.calls == 1 and waiting.calls == 1)
assert(bootstrap.error == failure and waiting.error == failure)
assert(runtime.status().connection == "failed" and runtime.status().error == failure)
assert(next_client.closed == 1)
runtime.tick()
assert(waiting.calls == 1)

-- A failed pump also settles already-issued requests and clears stale sessions.
next_client = client()
runtime.connect()
next_client:status_event("ready")
runtime.tick()
runtime.new_session()
runtime.tick()
local inflight = result()
runtime.list_sessions(inflight.callback)
next_client.pump_error = failure
runtime.tick()
assert(inflight.calls == 1 and inflight.error == failure)
assert(runtime.active_session() == nil and next_client.closed == 1)

-- Explicit disconnect cancels both bootstrap waiters and native requests.
next_client = client()
local cancelled = result()
runtime.new_session(cancelled.callback) -- failed state retains its cause
assert(cancelled.error == failure)
local waiting_disconnect = result()
runtime.connect()
runtime.new_session(waiting_disconnect.callback)
runtime.disconnect()
assert(waiting_disconnect.calls == 1 and waiting_disconnect.error.kind == "cancelled")
next_client = client()
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local cancelled_request = result()
runtime.list_sessions(cancelled_request.callback)
runtime.disconnect()
assert(cancelled_request.calls == 1 and cancelled_request.error.kind == "cancelled")

-- A callback can reconnect; remaining events from the old pump cannot fail it.
local old = client()
next_client = old
local replacement = client()
runtime.connect(function()
  runtime.disconnect()
  next_client = replacement
  runtime.connect()
end)
local stale_waiter = result()
runtime.new_session(stale_waiter.callback)
old:status_event("ready")
old:status_event("failed", failure)
runtime.tick()
assert(runtime.status().connection == "connecting" and replacement.closed == 0)
assert(stale_waiter.calls == 1 and stale_waiter.error.kind == "cancelled")
replacement:status_event("ready")
runtime.tick()
assert(runtime.status().connection == "ready")
runtime.disconnect()

-- A closed native connection must settle waiters rather than wait forever.
next_client = client()
local closed = result()
runtime.connect(closed.callback)
next_client:status_event("closed")
runtime.tick()
assert(closed.calls == 1 and closed.error.message:find("closed"))

-- A sessions facade exception must not strand the connection in connecting.
next_client = client()
function next_client:sessions() error(failure) end
local facade_error = result()
runtime.connect(facade_error.callback)
assert(facade_error.calls == 1 and facade_error.error == failure and next_client.closed == 1)

-- Synchronous native accessor errors must settle their public callbacks.
next_client = client()
runtime.connect()
next_client:status_event("ready")
runtime.tick()
function next_client.sessions_api:cached() error("cache failed") end
local close_error, prompt_error = result(), result()
runtime.close_session("session.test", close_error.callback)
runtime.prompt("session.test", { { kind = "text", text = "test" } }, prompt_error.callback)
assert(close_error.calls == 1 and close_error.error.message:find("cache failed"))
assert(prompt_error.calls == 1 and prompt_error.error.message:find("cache failed"))
runtime.disconnect()

-- Projection failure after create must close the otherwise orphaned session.
next_client = client()
function next_client.session:info() error("info failed") end
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local info_error = result()
runtime.new_session(info_error.callback)
runtime.tick()
runtime.tick()
assert(info_error.calls == 1 and info_error.error.message:find("info failed"))
assert(next_client.session_closes == 1 and runtime.active_session() == nil)
runtime.disconnect()

-- Session creation no longer waits on frontend routing reconciliation.
next_client = client()
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local created = result()
runtime.new_session(created.callback)
runtime.tick()
assert(created.calls == 1 and created.error == nil)
assert(runtime.active_session() == "session.test")
runtime.disconnect()

-- An active-session selection restores the persistent default if the session update fails.
next_client = client()
next_client.features_value = { selection = true }
next_client.session.selections = function()
  return completed({ selected = "model.old", available = {} })
end
local session_selection_error = { kind = "failed", message = "session selection rejected" }
next_client.session.select = function()
  return failed(session_selection_error)
end
runtime.connect()
next_client:status_event("ready")
runtime.tick()
runtime.new_session()
runtime.tick()
local selection_result = result()
runtime.select("model.new", selection_result.callback)
for _ = 1, 6 do runtime.tick() end
assert(selection_result.calls == 1 and selection_result.error == session_selection_error)
assert(next_client.default_selection == "model.old", "failed session selection changed the persistent default")
assert(
  table.concat(next_client.default_selection_calls, ",") == "model.new,model.old",
  "failed session selection did not compensate the default mutation"
)
runtime.disconnect()

-- A stale selection rollback must not reconnect and mutate a replacement client.
next_client = client()
next_client.session.select = function()
  return pending()
end
runtime.connect()
next_client:status_event("ready")
runtime.tick()
runtime.new_session()
runtime.tick()
local interrupted_selection = result()
runtime.select("model.new", interrupted_selection.callback)
runtime.tick() -- selection discovery
runtime.tick() -- persistent default update; session update remains pending
assert(next_client.default_selection == "model.new")
local overlapping_selection = result()
runtime.select("model.other", overlapping_selection.callback)
assert(overlapping_selection.calls == 1)
assert(overlapping_selection.error.code == "selection_in_progress")
assert(
  table.concat(next_client.default_selection_calls, ",") == "model.new",
  "overlapping selection mutated the persistent default"
)
local connects_before_disconnect = connect_count
runtime.disconnect()
assert(interrupted_selection.calls == 1)
assert(interrupted_selection.error.kind == "partial_failure")
assert(interrupted_selection.error.code == "selection_rollback_connection_changed")
assert(connect_count == connects_before_disconnect, "stale rollback reconnected Phenix")
assert(
  table.concat(next_client.default_selection_calls, ",") == "model.new",
  "stale rollback mutated the disconnected client"
)

-- Child-session lifecycle events must not clear the controller or poison the connection.
-- Model-side orchestration can create/close sessions that the frontend never selected.
next_client = client()
next_client.session.projection = function()
  return {
    session = { session_id = "session.test" },
    through_sequence = 1,
    updates = {},
  }
end
runtime.connect()
next_client:status_event("ready")
runtime.tick()
runtime.new_session()
runtime.tick()
local controller_session = assert(runtime.active_session())
assert(controller_session == "session.test")
table.insert(next_client.events, {
  kind = "session_update",
  data = { session_id = "session.child" },
})
runtime.tick()
assert(runtime.active_session() == controller_session, "child update replaced or cleared the active controller")
assert(runtime.status().connection == "ready", "child update poisoned the Phenix connection")
assert(next_client.closed == 0, "child update closed the native client")
runtime.disconnect()

-- A Phenix/model failure settles only that prompt. It does not poison the
-- transport connection, and the next prompt gets a fresh request.
next_client = client()
local model_failure = {
  kind = "failed",
  code = "provider_failed",
  message = "model provider failed",
}
local prompt_calls = 0
next_client.session.prompt = function()
  prompt_calls = prompt_calls + 1
  if prompt_calls == 1 then
    return failed(model_failure)
  end
  return completed({ execution_id = "execution-2" })
end
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local failed_prompt = result()
runtime.prompt("session.test", { { kind = "text", text = "first" } }, failed_prompt.callback)
runtime.tick()
assert(failed_prompt.calls == 1 and failed_prompt.error == model_failure)
assert(runtime.status().connection == "ready" and next_client.closed == 0)

local recovered_prompt = result()
runtime.prompt("session.test", { { kind = "text", text = "second" } }, recovered_prompt.callback)
runtime.tick()
assert(recovered_prompt.calls == 1 and recovered_prompt.error == nil)
assert(prompt_calls == 2 and runtime.status().connection == "ready")
runtime.disconnect()

-- Application requests have no frontend deadline. Phenix owns execution limits
-- and settles model/provider failures. The plugin only fails requests when the
-- native process or transport reports a connection failure.
next_client = client()
next_client.session.prompt = pending
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local long_prompt = result()
runtime.prompt("session.test", { { kind = "text", text = "test" } }, long_prompt.callback)
for _ = 1, 4 do
  runtime.tick()
end
assert(long_prompt.calls == 0, "frontend imposed a deadline on a pending Phenix prompt")
assert(next_client.closed == 0 and runtime.status().connection == "ready")

local process_failure = {
  kind = "transport",
  code = "transport",
  message = "phenix process exited",
}
next_client:status_event("failed", process_failure)
runtime.tick()
assert(long_prompt.calls == 1 and long_prompt.error == process_failure)
assert(next_client.closed == 1 and runtime.status().connection == "failed")

for _, key in ipairs({ "connect_timeout_ms", "request_timeout_ms", "prompt_timeout_ms" }) do
  assert(
    not pcall(config.setup, { [key] = 100 }),
    key .. " must be configured in Phenix rather than phenix-ai.nvim"
  )
end
print("runtime lifecycle regressions passed")

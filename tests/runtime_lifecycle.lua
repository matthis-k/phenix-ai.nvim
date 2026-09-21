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
local function client()
  local value = { events = {}, closed = 0, creates = 0, session_closes = 0 }
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
runtime.configure(config.setup({ auto_connect = false, selection = false, poll_interval_ms = 60000 }))

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

-- Session activation waits until route reconciliation is complete.
next_client = client()
next_client.features_value = { selection = true }
local selection_complete = false
next_client.session.selections = function()
  return completed({ selected = "default", available = { { id = "router.test" } } })
end
next_client.session.select = function()
  return { poll = function() return selection_complete, {}, nil end }
end
runtime.set_preferred_selection("router.test")
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local routed = result()
runtime.new_session(routed.callback)
runtime.tick()
runtime.tick()
assert(runtime.active_session() == nil and routed.calls == 0)
selection_complete = true
runtime.tick()
assert(runtime.active_session() == "session.test" and routed.calls == 1 and routed.error == nil)
runtime.disconnect()
-- Missing preferred routes must fail bootstrap instead of activating a default.
next_client = client()
next_client.features_value = { selection = true }
next_client.session.selections = function()
  return completed({ selected = "default", available = { { id = "default" } } })
end
runtime.configure(config.setup({ selection = "auto", poll_interval_ms = 60000 }))
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local missing = result()
runtime.new_session(missing.callback)
runtime.tick()
runtime.tick()
runtime.tick()
assert(missing.calls == 1 and missing.error.message:find("unavailable"))
assert(runtime.active_session() == nil and next_client.session_closes == 1)
runtime.disconnect()
-- Advance a monotonic clock without sleeping or relying on test-runner limits.
-- Provider identity comes from typed metadata even when descriptions contradict it.
for _, same_provider in ipairs({ false, true }) do
  next_client = client()
  next_client.features_value = { selection = true }
  local selected_count = 0
  next_client.session.selections = function()
    return completed({ selected = "fixed", available = {
      { id = "fixed", presentation = "model", provider = same_provider and "codex" or "api", description = "codex misleading display text" },
      { id = "router.test", presentation = "router", provider = "codex", description = "api other display text" },
    } })
  end
  next_client.session.select = function()
    selected_count = selected_count + 1
    return completed({})
  end
  runtime.set_preferred_selection("router.test")
  runtime.connect()
  next_client:status_event("ready")
  runtime.tick()
  local routed = result()
  runtime.new_session(routed.callback)
  runtime.tick()
  runtime.tick()
  runtime.tick()
  assert(routed.calls == 1 and routed.error == nil)
  assert(selected_count == (same_provider and 0 or 1))
  runtime.disconnect()
end

local uv = vim.uv or vim.loop
local original_hrtime = uv.hrtime
local clock = 0
uv.hrtime = function() return clock * 1000000 end
runtime.configure(config.setup({ selection = false, poll_interval_ms = 60000,
  connect_timeout_ms = 100, request_timeout_ms = 200, prompt_timeout_ms = 1000 }))
next_client = client()
local timed_connect, timed_create = result(), result()
runtime.connect(timed_connect.callback)
runtime.new_session(timed_create.callback)
clock = 100
runtime.tick()
assert(timed_connect.calls == 1 and timed_connect.error.kind == "timeout")
assert(timed_create.calls == 1 and timed_create.error == timed_connect.error)
assert(next_client.closed == 1 and runtime.status().connection == "failed")
next_client:status_event("ready")
runtime.tick()
assert(timed_connect.calls == 1 and runtime.status().connection == "failed")

next_client = client()
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local timed_request = result()
runtime.list_sessions(timed_request.callback)
clock = 299
runtime.tick()
assert(timed_request.calls == 0)
clock = 300
runtime.tick()
assert(timed_request.calls == 1 and timed_request.error.code == "timeout")
assert(next_client.closed == 1)
runtime.tick()
assert(timed_request.calls == 1)

-- A fresh connection gets fresh deadlines; prompts have a separate longer limit.
next_client = client()
next_client.session.prompt = pending
runtime.connect()
next_client:status_event("ready")
runtime.tick()
local timed_prompt = result()
runtime.prompt("session.test", { { kind = "text", text = "test" } }, timed_prompt.callback)
clock = 501
runtime.tick()
assert(timed_prompt.calls == 0 and next_client.closed == 0)
clock = 1300
runtime.tick()
assert(timed_prompt.calls == 1 and timed_prompt.error.kind == "timeout")
runtime.disconnect()
uv.hrtime = original_hrtime
for _, value in ipairs({ 0, -1, math.huge, "100" }) do
  assert(not pcall(config.setup, { request_timeout_ms = value }))
end
print("runtime lifecycle regressions passed")

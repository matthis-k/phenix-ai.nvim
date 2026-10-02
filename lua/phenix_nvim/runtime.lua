local native = require("phenix")
local config_api = require("phenix_nvim.config")
local interaction = require("phenix_nvim.interaction")
local tool_templates = require("phenix_nvim.tools")
local util = require("phenix_nvim.util")

local M = {}
local uv = vim.uv or vim.loop

local state = {
  config = nil,
  client = nil,
  sessions = nil,
  active_session = nil,
  session_state = { sessions = {} },
  connection = "disconnected",
  error = nil,
  timer = nil,
  pending = {},
  listeners = {},
  connect_callbacks = {},
  context_generation = 0,
  selection_inflight = false,
  tool_session = nil,
  tool_revision = -1,
  tool_stops = {},
  tool_syncing = false,
  tool_waiters = {},
}

local function emit(kind, value)
  for _, listener in ipairs(vim.deepcopy(state.listeners)) do
    util.safe_call(listener, kind, value)
  end
end

local function stop_timer()
  if state.timer ~= nil then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function settle_connect_callbacks(value, error)
  local callbacks = state.connect_callbacks
  local client = state.client
  state.connect_callbacks = {}
  for _, callback in ipairs(callbacks) do
    if value ~= nil and state.client ~= client then
      util.safe_call(callback, nil, { kind = "cancelled", message = "Phenix connection changed" })
    else
      util.safe_call(callback, value, error)
    end
  end
end

local function terminate(connection, error)
  stop_timer()
  local client = state.client
  local pending = state.pending
  local callbacks = state.connect_callbacks
  local tool_waiters = state.tool_waiters
  state.client = nil
  state.sessions = nil
  state.active_session = nil
  state.session_state = { sessions = {} }
  state.pending = {}
  state.connect_callbacks = {}
  state.tool_session = nil
  state.tool_revision = -1
  state.tool_stops = {}
  state.tool_syncing = false
  state.tool_waiters = {}
  state.context_generation = state.context_generation + 1
  state.connection = connection
  state.error = connection == "failed" and error or nil
  if client ~= nil then
    pcall(client.close, client)
  end
  emit("sessions", state.session_state)
  emit("status", M.status())
  for _, callback in ipairs(callbacks) do
    util.safe_call(callback, nil, error)
  end
  for _, item in ipairs(pending) do
    util.safe_call(item.callback, nil, error)
  end
  for _, waiter in ipairs(tool_waiters) do
    util.safe_call(waiter.callback, nil, error)
  end
end

local function fail(error)
  terminate("failed", type(error) == "table" and error or { message = tostring(error) })
end

local function start_timer()
  stop_timer()
  local timer = uv.new_timer()
  state.timer = timer
  local interval = state.config.poll_interval_ms
  local client = state.client
  timer:start(interval, interval, vim.schedule_wrap(function()
    if state.client == client then
      M.tick()
    end
  end))
end

local function active_id()
  if state.active_session == nil then
    return nil
  end
  local ok, id = pcall(state.active_session.id, state.active_session)
  return ok and id or nil
end

local function remove_tool_admissions(stops, callback)
  local pending = {}
  for _, stop in pairs(stops or {}) do
    table.insert(pending, stop)
  end
  if #pending == 0 then
    callback(nil)
    return
  end

  local remaining = #pending
  local first_error
  local function settled(error)
    first_error = first_error or error
    remaining = remaining - 1
    if remaining == 0 then
      callback(first_error)
    end
  end

  for _, stop in ipairs(pending) do
    local ok, request = pcall(stop)
    if not ok then
      settled({ message = tostring(request) })
    elseif request == nil then
      settled(nil)
    else
      M.track(request, function(_, error)
        settled(error)
      end)
    end
  end
end

local function register_tool_templates(client, session_id, templates, callback)
  local tools_method = client and client.tools
  if type(tools_method) ~= "function" then
    callback({}, nil)
    return
  end

  local ok, native_tools = pcall(tools_method, client)
  if not ok or type(native_tools) ~= "table" or type(native_tools.register) ~= "function" then
    callback({}, nil)
    return
  end

  local stops = {}
  local index = 1
  local function register_next()
    local template = templates[index]
    if template == nil then
      callback(stops, nil)
      return
    end

    local definition = vim.deepcopy(template.definition)
    definition.session_id = session_id
    local registered, request = pcall(native_tools.register, definition, template.handler)
    if not registered then
      remove_tool_admissions(stops, function()
        callback(nil, { message = tostring(request) })
      end)
      return
    end
    M.track(request, function(stop, error)
      if error ~= nil then
        remove_tool_admissions(stops, function()
          callback(nil, error)
        end)
        return
      end
      if type(stop) ~= "function" then
        remove_tool_admissions(stops, function()
          callback(nil, { message = "Phenix client tool registration returned no removal handle" })
        end)
        return
      end
      stops[template.id] = stop
      index = index + 1
      register_next()
    end)
  end

  register_next()
end

local function ensure_client_tools(session_id, callback)
  local revision = tool_templates._revision()
  if state.tool_session == session_id
    and state.tool_revision == revision
    and not state.tool_syncing
  then
    util.safe_call(callback, true, nil)
    return
  end

  if state.tool_syncing then
    table.insert(state.tool_waiters, { session_id = session_id, callback = callback })
    return
  end

  state.tool_syncing = true
  local client = state.client
  local previous_session = state.tool_session
  local previous_stops = state.tool_stops
  state.tool_stops = {}

  local function finish(value, error)
    if state.client == client then
      state.tool_syncing = false
      if error == nil then
        state.tool_session = session_id
        state.tool_revision = revision
        state.tool_stops = value or {}
      else
        state.tool_session = nil
        state.tool_revision = -1
        state.tool_stops = {}
      end
    end
    util.safe_call(callback, error == nil and true or nil, error)

    local waiters = state.tool_waiters
    state.tool_waiters = {}
    for _, waiter in ipairs(waiters) do
      ensure_client_tools(waiter.session_id, waiter.callback)
    end
  end

  remove_tool_admissions(previous_stops, function(removal_error)
    if state.client ~= client then
      finish(nil, removal_error or { kind = "cancelled", message = "Phenix connection changed" })
      return
    end
    if removal_error ~= nil and previous_session == session_id then
      finish(nil, removal_error)
      return
    end
    register_tool_templates(client, session_id, tool_templates._templates(), function(stops, error)
      finish(stops, error)
    end)
  end)
end

local function refresh_projection(session_id)
  if state.sessions == nil or session_id == nil then
    return nil
  end
  local ok, session = pcall(state.sessions.cached, state.sessions, session_id)
  if not ok or session == nil then
    return nil
  end
  local projection_ok, projection = pcall(session.projection, session)
  if not projection_ok or projection == nil then
    return nil
  end
  state.session_state.sessions[session_id] = projection
  emit("sessions", state.session_state)
  return projection
end

local function refresh_active_context()
  local session = state.active_session
  if session == nil then
    return
  end
  state.context_generation = state.context_generation + 1
  local generation = state.context_generation
  local function ignore_stale(_value, _error)
    if generation ~= state.context_generation then
      return
    end
    emit("status", M.status())
  end
  local features = state.client and state.client:features() or {}
  if features.selection then
    local ok, request = pcall(session.selections, session)
    if ok then
      M.track(request, ignore_stale)
    end
  end
end

local function set_active(session)
  state.active_session = session
  local session_id = active_id()
  if session_id ~= nil then
    refresh_projection(session_id)
    refresh_active_context()
  end
  emit("status", M.status())
end

local function application_content(segments)
  local content = {}
  for _, segment in ipairs(segments) do
    if segment.kind == "text" then
      table.insert(content, { kind = "text", text = segment.text })
    elseif segment.kind == "resource" or segment.kind == "location" or segment.kind == "selection" then
      local source = segment.source or {}
      if type(source.uri) ~= "string" or source.uri == "" then
        return nil, "resource is missing a source URI"
      end
      table.insert(content, {
        kind = "resource",
        uri = source.uri,
        mime_type = segment.snapshot and "text/plain" or nil,
        text = segment.snapshot,
      })
    elseif segment.kind == "image" then
      table.insert(content, {
        kind = "image",
        mime_type = segment.mime_type,
        data = segment.bytes,
      })
    else
      return nil, "unsupported compose item " .. tostring(segment.kind)
    end
  end
  return content
end

local function handle_event(event, dirty_sessions)
  if type(event) ~= "table" then
    return
  end
  local kind = event.kind
  local data = event.data
  if kind == "status" then
    if data and (data.state == "failed" or data.state == "closed") then
      fail(data.error or { message = "Phenix connection " .. data.state })
      return
    end
    state.connection = data and data.state or state.connection
    state.error = data and data.error or nil
    if state.connection == "ready" then
      settle_connect_callbacks(state, nil)
    end
    emit("status", M.status())
    return
  end
  if kind == "session_snapshot" or kind == "session_update" then
    local session_id = data and (data.session_id or (data.session and data.session.session_id))
    if session_id ~= nil then
      dirty_sessions[session_id] = true
    end
    emit("update", event)
    return
  end
  emit("update", event)
end

function M.configure(config)
  state.config = vim.deepcopy(config)
end

function M.on_event(listener)
  local registered = function(...) listener(...) end
  table.insert(state.listeners, registered)
  return function()
    for index, current in ipairs(state.listeners) do
      if current == registered then
        table.remove(state.listeners, index)
        return
      end
    end
  end
end

function M.track(request, callback)
  if request == nil then
    util.safe_call(callback, nil, { message = "native request was not created" })
    return
  end
  table.insert(state.pending, {
    request = request,
    callback = callback,
  })
end

function M.tick()
  local client = state.client
  if client == nil then
    return
  end

  local ok, events = pcall(client.pump, client, state.config.poll_budget)
  if not ok then
    fail(events)
    return
  end
  local dirty_sessions = {}
  for _, event in ipairs(events or {}) do
    handle_event(event, dirty_sessions)
    if state.client ~= client then
      return
    end
  end
  local active_session_id = active_id()
  local active_session_changed = false
  for session_id in pairs(dirty_sessions) do
    refresh_projection(session_id)
    if session_id == active_session_id then
      active_session_changed = true
    end
  end
  if active_session_changed then
    emit("status", M.status())
  end

  for index = #state.pending, 1, -1 do
    local item = state.pending[index]
    local poll_ok, complete, value, error = pcall(util.request_poll, item.request)
    if not poll_ok then
      table.remove(state.pending, index)
      util.safe_call(item.callback, nil, complete)
    elseif complete then
      table.remove(state.pending, index)
      util.safe_call(item.callback, value, error)
    end
    if state.client ~= client then
      return
    end
  end
end

function M.connect(callback)
  if state.connection == "ready" then
    util.safe_call(callback, state, nil)
    return
  end
  if callback ~= nil then
    table.insert(state.connect_callbacks, callback)
  end
  if state.client ~= nil and state.connection == "connecting" then
    return
  end

  local config = state.config or require("phenix_nvim.config").get()
  state.config = config
  state.connection = "connecting"
  state.error = nil

  local facade = native.application and native.application.connect
  if type(facade) ~= "function" then
    fail({ message = "native Phenix binding does not expose the application facade" })
    return
  end

  local ok, client = pcall(facade, {
    command = config.command,
    args = config.args,
    env = config_api.runtime_env(config),
    interactions = {
      permission = function(request, reply)
        vim.schedule(function()
          local interaction_ok, error = pcall(interaction.permission, request, reply)
          if not interaction_ok then
            pcall(reply.cancel, reply)
            util.notify(error, vim.log.levels.ERROR)
          end
        end)
      end,
      elicitation = function(request, reply)
        vim.schedule(function()
          local interaction_ok, error = pcall(interaction.elicitation, request, reply)
          if not interaction_ok then
            pcall(reply.cancel, reply)
            util.notify(error, vim.log.levels.ERROR)
          end
        end)
      end,
    },
  })
  if not ok then
    fail(client)
    return
  end

  state.client = client
  local sessions_ok, sessions = pcall(client.sessions, client)
  if not sessions_ok or sessions == nil then
    fail(sessions or { message = "native sessions facade was not created" })
    return
  end
  state.sessions = sessions
  start_timer()
  emit("status", M.status())
end

function M.disconnect()
  terminate("disconnected", { kind = "cancelled", message = "Phenix disconnected" })
end

local function is_ready()
  return state.client ~= nil and state.sessions ~= nil and state.connection == "ready"
end

local function ensure_ready(callback, continuation)
  if is_ready() then
    continuation()
    return
  end
  if state.connection == "failed" then
    util.safe_call(callback, nil, state.error or { message = "Phenix connection failed" })
    return
  end
  M.connect(function(_, error)
    if error ~= nil then
      util.safe_call(callback, nil, error)
      return
    end
    if not is_ready() then
      util.safe_call(callback, nil, { message = "Phenix connection did not become ready" })
      return
    end
    continuation()
  end)
end

local function close_created_session(session, error, callback)
  local ok, request = pcall(session.close, session)
  if not ok then
    util.safe_call(callback, nil, error)
    return
  end
  M.track(request, function()
    util.safe_call(callback, nil, error)
  end)
end

function M.new_session(callback)
  ensure_ready(callback, function()
    local ok, request = pcall(state.sessions.create, state.sessions, {
      working_directory = vim.fn.getcwd(),
      title = nil,
    })
    if not ok then
      util.safe_call(callback, nil, { message = tostring(request) })
      return
    end
    M.track(request, function(session, error)
      if error ~= nil then
        util.safe_call(callback, nil, error)
        return
      end
      local info_ok, info = pcall(session.info, session)
      if not info_ok then
        close_created_session(session, { message = tostring(info) }, callback)
        return
      end
      set_active(session)
      util.safe_call(callback, info, nil)
    end)
  end)
end

function M.resume_session(session_id, callback)
  ensure_ready(callback, function()
    local ok, request = pcall(state.sessions.resume, state.sessions, session_id)
    if not ok then
      util.safe_call(callback, nil, { message = tostring(request) })
      return
    end
    M.track(request, function(session, error)
      if error ~= nil then
        util.safe_call(callback, nil, error)
        return
      end
      local projection_ok, projection = pcall(session.projection, session)
      if not projection_ok then
        util.safe_call(callback, nil, { message = tostring(projection) })
        return
      end
      if projection == nil then
        local info_ok, info = pcall(session.info, session)
        if not info_ok then
          util.safe_call(callback, nil, { message = tostring(info) })
          return
        end
        projection = info
      end
      set_active(session)
      util.safe_call(callback, projection, nil)
    end)
  end)
end

function M.activate_session(session_id, callback)
  if session_id == nil then
    state.active_session = nil
    state.context_generation = state.context_generation + 1
    emit("status", M.status())
    util.safe_call(callback, nil, nil)
    return
  end
  if active_id() == session_id then
    util.safe_call(callback, state.session_state.sessions[session_id], nil)
    return
  end
  ensure_ready(callback, function()
    local cached_ok, session = pcall(state.sessions.cached, state.sessions, session_id)
    if not cached_ok then
      util.safe_call(callback, nil, { message = tostring(session) })
      return
    end
    if session == nil then
      M.resume_session(session_id, callback)
      return
    end
    set_active(session)
    util.safe_call(callback, state.session_state.sessions[session_id], nil)
  end)
end

function M.list_sessions(callback)
  ensure_ready(callback, function()
    local ok, request = pcall(state.sessions.list, state.sessions, {})
    if not ok then
      util.safe_call(callback, nil, { message = tostring(request) })
      return
    end
    M.track(request, callback)
  end)
end

function M.close_session(session_id, callback)
  ensure_ready(callback, function()
    local cached_ok, session = pcall(state.sessions.cached, state.sessions, session_id)
    if not cached_ok then
      util.safe_call(callback, nil, { message = tostring(session) })
      return
    end
    if session == nil then
      util.safe_call(callback, nil, { message = "unknown Phenix session " .. tostring(session_id) })
      return
    end
    local close_ok, request = pcall(session.close, session)
    if not close_ok then
      util.safe_call(callback, nil, { message = tostring(request) })
      return
    end
    M.track(request, function(result, error)
      if error == nil then
        state.session_state.sessions[session_id] = nil
        if active_id() == session_id then
          state.active_session = nil
          state.context_generation = state.context_generation + 1
        end
        emit("sessions", state.session_state)
        emit("status", M.status())
      end
      util.safe_call(callback, result, error)
    end)
  end)
end

function M.refresh_client_tools(callback)
  local session_id = active_id()
  if session_id == nil then
    util.safe_call(callback, true, nil)
    return
  end
  ensure_client_tools(session_id, callback)
end

function M.active_session()
  return active_id()
end

function M.active_session_object()
  return state.active_session
end

function M.prompt(session_id, segments, callback)
  ensure_ready(callback, function()
    local cached_ok, session = pcall(state.sessions.cached, state.sessions, session_id)
    if not cached_ok then
      util.safe_call(callback, nil, { message = tostring(session) })
      return
    end
    if session == nil then
      util.safe_call(callback, nil, { message = "unknown Phenix session " .. tostring(session_id) })
      return
    end
    ensure_client_tools(session_id, function(_, tool_error)
      if tool_error ~= nil then
        util.safe_call(callback, nil, tool_error)
        return
      end
      local content, content_error = application_content(segments)
      if content == nil then
        util.safe_call(callback, nil, { message = content_error })
        return
      end
      local ok, request = pcall(session.prompt, session, content)
      if not ok then
        util.safe_call(callback, nil, { message = tostring(request) })
        return
      end
      M.track(request, function(result, error)
        if error == nil then
          refresh_projection(session_id)
          local features_ok, features = pcall(state.client.features, state.client)
          if features_ok and features.provenance and result and result.execution_id then
            local provenance_ok, provenance = pcall(session.provenance, session, result.execution_id)
            if provenance_ok then
              M.track(provenance, function()
                emit("status", M.status())
              end)
            end
          end
        end
        util.safe_call(callback, result, error)
      end)
    end)
  end)
end

local unpack_args = table.unpack or unpack

local function client_request(method, callback, ...)
  local args = { n = select("#", ...), ... }
  ensure_ready(callback, function()
    local callable = state.client[method]
    if type(callable) ~= "function" then
      util.safe_call(callback, nil, { message = "Phenix client does not support " .. method })
      return
    end
    local ok, request = pcall(callable, state.client, unpack_args(args, 1, args.n))
    if not ok then
      util.safe_call(callback, nil, { message = tostring(request) })
      return
    end
    M.track(request, function(result, error)
      if error == nil then
        refresh_active_context()
        emit("status", M.status())
      end
      util.safe_call(callback, result, error)
    end)
  end)
end

function M.logs(options, callback)
  client_request("logs", callback, options or {})
end

function M.log_reference(reference, callback)
  client_request("log_reference", callback, reference)
end

function M.list_authentication_methods(callback)
  client_request("authentication_methods", callback)
end

function M.authenticate(method_id, secret, callback)
  client_request("authenticate", callback, method_id, secret)
end

function M.list_selections(callback)
  client_request("selections", callback)
end

local function selection_rollback_failure(original_error, rollback_error, code, message)
  return {
    kind = "partial_failure",
    code = code or "selection_rollback_failed",
    message = message or "session model selection failed and the previous default could not be restored",
    cause = original_error,
    rollback_error = rollback_error,
  }
end

local function restore_default_selection(previous_selection, original_error, callback, expected_client)
  if previous_selection == nil then
    util.safe_call(callback, nil, original_error)
    return
  end
  if state.client ~= expected_client or not is_ready() then
    util.safe_call(callback, nil, selection_rollback_failure(
      original_error,
      { kind = "cancelled", message = "Phenix connection changed before selection rollback" },
      "selection_rollback_connection_changed",
      "session model selection did not settle and the previous default was not restored because the Phenix connection changed"
    ))
    return
  end
  local callable = expected_client.select
  if type(callable) ~= "function" then
    util.safe_call(callback, nil, selection_rollback_failure(
      original_error,
      { message = "Phenix client does not support select" }
    ))
    return
  end
  local ok, request = pcall(callable, expected_client, previous_selection)
  if not ok then
    util.safe_call(callback, nil, selection_rollback_failure(
      original_error,
      { message = tostring(request) }
    ))
    return
  end
  M.track(request, function(_, rollback_error)
    if rollback_error == nil then
      refresh_active_context()
      emit("status", M.status())
      util.safe_call(callback, nil, original_error)
      return
    end
    util.safe_call(callback, nil, selection_rollback_failure(original_error, rollback_error))
  end)
end

function M.select(selection_id, callback)
  if state.selection_inflight then
    util.safe_call(callback, nil, {
      kind = "busy",
      code = "selection_in_progress",
      message = "another Phenix model selection is still in progress",
    })
    return
  end
  state.selection_inflight = true
  local settled = false
  local function finish(value, error)
    if settled then
      return
    end
    settled = true
    state.selection_inflight = false
    util.safe_call(callback, value, error)
  end

  local session = state.active_session
  if session == nil then
    client_request("select", finish, selection_id)
    return
  end

  client_request("selections", function(before, discovery_error)
    if discovery_error ~= nil then
      finish(nil, discovery_error)
      return
    end
    local previous_selection = before and before.selected or nil
    local transaction_client = state.client
    client_request("select", function(global_result, global_error)
      if global_error ~= nil then
        finish(nil, global_error)
        return
      end
      if state.client ~= transaction_client or state.active_session ~= session then
        restore_default_selection(previous_selection, {
          kind = "cancelled",
          message = state.client ~= transaction_client
            and "Phenix connection changed during model selection"
            or "active Phenix session changed during model selection",
        }, finish, transaction_client)
        return
      end
      local ok, request = pcall(session.select, session, selection_id)
      if not ok then
        restore_default_selection(previous_selection, { message = tostring(request) }, finish, transaction_client)
        return
      end
      M.track(request, function(session_result, session_error)
        if session_error == nil then
          finish(session_result or global_result, nil)
          return
        end
        restore_default_selection(previous_selection, session_error, finish, transaction_client)
      end)
    end, selection_id)
  end)
end

function M.cancel_active()
  local session = state.active_session
  if session == nil then
    return
  end
  local ok, request = pcall(session.cancel, session)
  if not ok then
    util.notify(tostring(request), vim.log.levels.ERROR)
    return
  end
  M.track(request, function(_, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
    end
  end)
end

function M.decide_review(review, decision, callback)
  ensure_ready(callback, function()
    local normalized = string.lower(decision or "")
    local ok, request = pcall(state.client.decide_review, state.client, review, normalized)
    if not ok then
      util.safe_call(callback, nil, { message = tostring(request) })
      return
    end
    M.track(request, callback)
  end)
end

function M.refresh_session_state(callback)
  local session_id = active_id()
  local projection = refresh_projection(session_id)
  util.safe_call(callback, projection, projection == nil and { message = "no active session projection" } or nil)
end

function M.status(session_id)
  session_id = session_id == nil and active_id() or session_id
  local result = {
    connection = state.connection,
    error = state.error,
    session_id = session_id,
  }
  if state.client ~= nil then
    local ok, client_status = pcall(state.client.status, state.client)
    if ok and type(client_status) == "table" then
      result.connection = client_status.state or result.connection
      result.error = client_status.error or result.error
    end
  end
  local session = state.active_session
  if session_id ~= nil and session_id ~= active_id() and state.sessions ~= nil then
    local cached_ok, cached = pcall(state.sessions.cached, state.sessions, session_id)
    if cached_ok then
      session = cached
    end
  end
  if session ~= nil then
    local ok, session_status = pcall(session.status, session)
    if ok and type(session_status) == "table" then
      for key, value in pairs(session_status) do
        result[key] = value
      end
    end
  end
  return result
end

function M.session_state()
  return state.session_state
end

return M

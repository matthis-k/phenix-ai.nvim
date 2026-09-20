local native = require("phenix")
local config_api = require("phenix_nvim.config")
local interaction = require("phenix_nvim.interaction")
local util = require("phenix_nvim.util")

local M = {}
local uv = vim.uv or vim.loop

local state = {
  config = nil,
  preferred_selection = nil,
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
  state.connect_callbacks = {}
  for _, callback in ipairs(callbacks) do
    util.safe_call(callback, value, error)
  end
end

local function fail(error)
  state.connection = "failed"
  state.error = type(error) == "table" and error or { message = tostring(error) }
  stop_timer()
  settle_connect_callbacks(nil, state.error)
  emit("status", M.status())
end

local function start_timer()
  stop_timer()
  local timer = uv.new_timer()
  state.timer = timer
  local interval = state.config.poll_interval_ms
  timer:start(interval, interval, vim.schedule_wrap(function()
    M.tick()
  end))
end

local function active_id()
  if state.active_session == nil then
    return nil
  end
  local ok, id = pcall(state.active_session.id, state.active_session)
  return ok and id or nil
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

local function handle_event(event)
  if type(event) ~= "table" then
    return
  end
  local kind = event.kind
  local data = event.data
  if kind == "status" then
    state.connection = data and data.state or state.connection
    state.error = data and data.error or nil
    if state.connection == "ready" then
      settle_connect_callbacks(state, nil)
    elseif state.connection == "failed" then
      settle_connect_callbacks(nil, state.error or { message = "Phenix connection failed" })
    end
    emit("status", M.status())
    return
  end
  if kind == "session_snapshot" or kind == "session_update" then
    local session_id = data and (data.session_id or (data.session and data.session.session_id))
    if session_id ~= nil then
      refresh_projection(session_id)
      if session_id == active_id() then
        emit("status", M.status())
      end
    end
    emit("update", event)
    return
  end
  emit("update", event)
end

function M.configure(config)
  state.config = vim.deepcopy(config)
  state.preferred_selection = config_api.preferred_selection(state.config)
end

function M.on_event(listener)
  table.insert(state.listeners, listener)
  local index = #state.listeners
  return function()
    state.listeners[index] = function() end
  end
end

function M.track(request, callback)
  if request == nil then
    util.safe_call(callback, nil, { message = "native request was not created" })
    return
  end
  table.insert(state.pending, { request = request, callback = callback })
end

function M.tick()
  if state.client == nil then
    return
  end

  local ok, events = pcall(state.client.pump, state.client, state.config.poll_budget)
  if not ok then
    fail(events)
    return
  end
  for _, event in ipairs(events or {}) do
    handle_event(event)
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
  if state.preferred_selection == nil then
    state.preferred_selection = config_api.preferred_selection(config)
  end
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
  state.sessions = client:sessions()
  start_timer()
  emit("status", M.status())
end

function M.disconnect()
  stop_timer()
  if state.client ~= nil then
    pcall(state.client.close, state.client)
  end
  state.client = nil
  state.sessions = nil
  state.active_session = nil
  state.session_state = { sessions = {} }
  state.pending = {}
  state.connect_callbacks = {}
  state.context_generation = state.context_generation + 1
  state.connection = "disconnected"
  state.error = nil
  emit("sessions", state.session_state)
  emit("status", M.status())
end

local function require_ready(callback)
  if state.client == nil or state.sessions == nil or state.connection ~= "ready" then
    util.safe_call(callback, nil, { message = "Phenix is not ready" })
    return false
  end
  return true
end

local function selection_presentation(item)
  local presentation = item and item.presentation
  if type(presentation) == "table" then
    return string.lower(tostring(presentation.kind or ""))
  end
  return string.lower(tostring(presentation or ""))
end

local function selection_provider(item)
  if type(item) ~= "table" or type(item.description) ~= "string" then
    return nil
  end
  local provider = item.description:match("^%s*([^%s]+)")
  if provider == nil or provider == "" then
    return nil
  end
  return provider
end

local function apply_preferred_selection(session, callback)
  local selection = state.preferred_selection
  if selection == nil then
    util.safe_call(callback, session, nil)
    return
  end
  local features = state.client and state.client:features() or {}
  if not features.selection then
    util.safe_call(callback, session, nil)
    return
  end
  local ok, request = pcall(session.selections, session)
  if not ok then
    util.safe_call(callback, nil, { message = tostring(request) })
    return
  end
  M.track(request, function(result, error)
    if error ~= nil then
      util.safe_call(callback, nil, error)
      return
    end

    local preferred = nil
    local selected = nil
    for _, item in ipairs(result and result.available or {}) do
      if item.id == selection then
        preferred = item
      end
      if result and item.id == result.selected then
        selected = item
      end
    end

    if preferred == nil or (result and result.selected == selection) then
      util.safe_call(callback, session, nil)
      return
    end

    local should_reconcile = result == nil
      or result.selected == nil
      or result.selected == "default"
      or selected == nil

    if not should_reconcile
      and selection_presentation(selected) == "model"
      and selection_presentation(preferred) == "router"
    then
      local selected_provider = selection_provider(selected)
      local preferred_provider = selection_provider(preferred)
      should_reconcile = selected_provider ~= nil
        and preferred_provider ~= nil
        and selected_provider ~= preferred_provider
    end

    if not should_reconcile then
      util.safe_call(callback, session, nil)
      return
    end

    local select_ok, select_request = pcall(session.select, session, selection)
    if not select_ok then
      util.safe_call(callback, nil, { message = tostring(select_request) })
      return
    end
    M.track(select_request, function(_, select_error)
      util.safe_call(callback, select_error == nil and session or nil, select_error)
    end)
  end)
end

function M.new_session(callback)
  if not require_ready(callback) then
    return
  end
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
    set_active(session)
    apply_preferred_selection(session, function(_, selection_error)
      if selection_error ~= nil then
        util.safe_call(callback, nil, selection_error)
        return
      end
      util.safe_call(callback, session:info(), nil)
    end)
  end)
end

function M.resume_session(session_id, callback)
  if not require_ready(callback) then
    return
  end
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
    set_active(session)
    apply_preferred_selection(session, function(_, selection_error)
      if selection_error ~= nil then
        util.safe_call(callback, nil, selection_error)
        return
      end
      util.safe_call(callback, session:projection() or session:info(), nil)
    end)
  end)
end

function M.list_sessions(callback)
  if not require_ready(callback) then
    return
  end
  local ok, request = pcall(state.sessions.list, state.sessions, {})
  if not ok then
    util.safe_call(callback, nil, { message = tostring(request) })
    return
  end
  M.track(request, callback)
end

function M.close_session(session_id, callback)
  if not require_ready(callback) then
    return
  end
  local session = state.sessions:cached(session_id)
  if session == nil then
    util.safe_call(callback, nil, { message = "unknown Phenix session " .. tostring(session_id) })
    return
  end
  local request = session:close()
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
end

function M.active_session()
  return active_id()
end

function M.active_session_object()
  return state.active_session
end

function M.prompt(session_id, segments, callback)
  if not require_ready(callback) then
    return
  end
  local session = state.sessions:cached(session_id)
  if session == nil then
    util.safe_call(callback, nil, { message = "unknown Phenix session " .. tostring(session_id) })
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
      local features = state.client:features()
      if features.provenance and result and result.execution_id then
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
end

local function active_session_request(method, callback, ...)
  if not require_ready(callback) then
    return
  end
  local session = state.active_session
  if session == nil then
    util.safe_call(callback, nil, { message = "no active Phenix session" })
    return
  end
  local callable = session[method]
  if type(callable) ~= "function" then
    util.safe_call(callback, nil, { message = "Phenix session does not support " .. method })
    return
  end
  local ok, request = pcall(callable, session, ...)
  if not ok then
    util.safe_call(callback, nil, { message = tostring(request) })
    return
  end
  M.track(request, function(result, error)
    if error == nil then
      emit("status", M.status())
    end
    util.safe_call(callback, result, error)
  end)
end

local function client_request(method, callback, ...)
  if not require_ready(callback) then
    return
  end
  local callable = state.client[method]
  if type(callable) ~= "function" then
    util.safe_call(callback, nil, { message = "Phenix client does not support " .. method })
    return
  end
  local ok, request = pcall(callable, state.client, ...)
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
end

function M.has_environment(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  local configured = state.config and state.config.env and state.config.env[name]
  if type(configured) == "string" and configured ~= "" then
    return true
  end
  local inherited = vim.env[name]
  return type(inherited) == "string" and inherited ~= ""
end

function M.set_preferred_selection(selection_id)
  state.preferred_selection = selection_id
end

function M.reconnect_with_env(name, value, selection_id, callback)
  if type(name) ~= "string" or name == "" then
    util.safe_call(callback, nil, { message = "environment variable name must not be empty" })
    return
  end
  if type(value) ~= "string" or value == "" then
    util.safe_call(callback, nil, { message = "API key must not be empty" })
    return
  end
  local session_id = active_id()
  state.config = state.config or config_api.get()
  state.config.env = state.config.env or {}
  state.config.env[name] = value
  if selection_id ~= nil then
    state.preferred_selection = selection_id
  end

  M.disconnect()
  M.connect(function(_, connect_error)
    if connect_error ~= nil then
      util.safe_call(callback, nil, connect_error)
      return
    end
    if session_id == nil then
      util.safe_call(callback, { selection = state.preferred_selection }, nil)
      return
    end
    M.resume_session(session_id, function(result, resume_error)
      if resume_error ~= nil then
        util.safe_call(callback, nil, resume_error)
        return
      end
      if selection_id == nil then
        util.safe_call(callback, result, nil)
        return
      end
      M.select(selection_id, function(selected, select_error)
        util.safe_call(callback, select_error == nil and selected or nil, select_error)
      end)
    end)
  end)
end

function M.list_authentication_methods(callback)
  client_request("authentication_methods", callback)
end

function M.authenticate(method_id, callback)
  client_request("authenticate", callback, method_id)
end

function M.list_selections(callback)
  active_session_request("selections", callback)
end

function M.select(selection_id, callback)
  active_session_request("select", callback, selection_id)
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
  if state.client == nil or state.connection ~= "ready" then
    util.safe_call(callback, nil, { message = "Phenix is not ready" })
    return
  end
  local normalized = string.lower(decision or "")
  local ok, request = pcall(state.client.decide_review, state.client, review, normalized)
  if not ok then
    util.safe_call(callback, nil, { message = tostring(request) })
    return
  end
  M.track(request, callback)
end

function M.refresh_session_state(callback)
  local session_id = active_id()
  local projection = refresh_projection(session_id)
  util.safe_call(callback, projection, projection == nil and { message = "no active session projection" } or nil)
end

function M.status()
  local result = {
    connection = state.connection,
    error = state.error,
    session_id = active_id(),
  }
  if state.client ~= nil then
    local ok, client_status = pcall(state.client.status, state.client)
    if ok and type(client_status) == "table" then
      result.connection = client_status.state or result.connection
      result.error = client_status.error or result.error
    end
  end
  if state.active_session ~= nil then
    local ok, session_status = pcall(state.active_session.status, state.active_session)
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

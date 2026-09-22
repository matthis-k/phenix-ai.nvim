local buffer = require("phenix_nvim.transcript.buffer")
local model = require("phenix_nvim.transcript.model")
local runtime = require("phenix_nvim.runtime")

local M = {}
local views = setmetatable({}, { __mode = "k" })
local stop_listener

local function resolved_key(key)
  return key or buffer.default_key()
end

local function entry(key)
  key = resolved_key(key)
  local value = views[key]
  if value == nil then
    value = {
      key = key,
      session_id = nil,
      projection = model.new(nil),
    }
    views[key] = value
    buffer.render_projection(value.projection, key)
  end
  return value
end

local function empty_projection(view, session_id)
  view.projection = model.new(session_id)
  buffer.render_projection(view.projection, view.key)
end

local function session_projection(session_id)
  if session_id == nil then
    return nil
  end
  local state = runtime.session_state()
  if type(state) ~= "table" or type(state.sessions) ~= "table" then
    return nil
  end
  return state.sessions[session_id]
end

local function refresh_view(view)
  local session_id = view.session_id
  if session_id == nil then
    if view.projection.session_id ~= nil then
      empty_projection(view, nil)
    end
    return
  end

  local projection = session_projection(session_id)
  if projection == nil then
    if view.projection.session_id ~= session_id then
      empty_projection(view, session_id)
    end
    return
  end

  if view.projection.session_id ~= session_id then
    local rebuilt, err = model.rebuild(projection)
    if rebuilt == nil then
      runtime.refresh_session_state()
      return nil, err
    end
    view.projection = rebuilt
    buffer.render_projection(view.projection, view.key)
    return
  end

  local changed, err = model.sync(view.projection, projection)
  if changed == nil then
    local rebuilt, rebuild_error = model.rebuild(projection)
    if rebuilt == nil then
      runtime.refresh_session_state()
      return nil, rebuild_error or err
    end
    view.projection = rebuilt
    buffer.render_projection(view.projection, view.key)
    return
  end

  buffer.remember_projection(view.projection, view.key)
  for _, node_id in ipairs(changed) do
    buffer.render_node(view.projection.nodes[node_id], view.key)
  end
end

function M.bind(key, session_id)
  local view = entry(key)
  if view.session_id ~= session_id then
    view.session_id = session_id
    empty_projection(view, session_id)
  end
  return M.refresh(key)
end

function M.refresh(key)
  if key ~= nil then
    return refresh_view(entry(key))
  end
  local first_error
  for _, view in pairs(views) do
    local _, err = refresh_view(view)
    first_error = first_error or err
  end
  return first_error == nil and true or nil, first_error
end

function M.start()
  if stop_listener ~= nil then
    return
  end
  entry(buffer.default_key())
  stop_listener = runtime.on_event(function(kind)
    if kind == "sessions" or kind == "status" then
      M.refresh()
    end
  end)
  M.refresh()
end

function M.stop()
  if stop_listener ~= nil then
    stop_listener()
    stop_listener = nil
  end
  for _, view in pairs(views) do
    empty_projection(view, nil)
    view.session_id = nil
  end
end

function M.projection(key)
  return entry(key).projection
end

function M.session_id(key)
  return entry(key).session_id
end

return M

local buffer = require("phenix_nvim.transcript.buffer")
local model = require("phenix_nvim.transcript.model")
local runtime = require("phenix_nvim.runtime")

local M = {}
local projection = model.new(nil)
local stop_listener

local function empty_projection(session_id)
  projection = model.new(session_id)
  buffer.render_projection(projection)
end

local function selected_projection()
  local session_id = runtime.active_session()
  if session_id == nil then
    return nil, nil
  end
  local state = runtime.session_state()
  if type(state) ~= "table" or type(state.sessions) ~= "table" then
    return session_id, nil
  end
  return session_id, state.sessions[session_id]
end

function M.refresh()
  local session_id, session_projection = selected_projection()
  if session_id == nil then
    if projection.session_id ~= nil then
      empty_projection(nil)
    end
    return
  end
  if session_projection == nil then
    return
  end

  if projection.session_id ~= session_id then
    local rebuilt, err = model.rebuild(session_projection)
    if rebuilt == nil then
      runtime.refresh_session_state()
      return nil, err
    end
    projection = rebuilt
    buffer.render_projection(projection)
    return
  end

  local changed, err = model.sync(projection, session_projection)
  if changed == nil then
    local rebuilt, rebuild_error = model.rebuild(session_projection)
    if rebuilt == nil then
      runtime.refresh_session_state()
      return nil, rebuild_error or err
    end
    projection = rebuilt
    buffer.render_projection(projection)
    return
  end
  buffer.remember_projection(projection)
  for _, node_id in ipairs(changed) do
    buffer.render_node(projection.nodes[node_id])
  end
end

function M.start()
  if stop_listener ~= nil then
    return
  end
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
  empty_projection(nil)
end

function M.projection()
  return projection
end

return M

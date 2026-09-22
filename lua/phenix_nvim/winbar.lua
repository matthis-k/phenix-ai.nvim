local runtime = require("phenix_nvim.runtime")

local M = {}
local attached = {}
local stop_listener

local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function escape(value)
  return tostring(value or ""):gsub("%%", "%%%%")
end

local function short(value, limit)
  value = tostring(value or "")
  if #value <= limit then
    return value
  end
  return value:sub(1, math.max(1, limit - 1)) .. "…"
end

local function segment(group, text)
  if text == nil or text == "" then
    return ""
  end
  return "%#" .. group .. "#" .. escape(text) .. "%#WinBar#"
end

local function connection(status)
  if status.connection == "failed" then
    return "DiagnosticError", "× failed"
  end
  if status.connection == "connecting" then
    return "DiagnosticWarn", "◌ connecting"
  end
  if status.connection == "ready" then
    return "DiagnosticOk", "● ready"
  end
  return "Comment", "○ " .. tostring(status.connection or "offline")
end

local function surface_is_active(surface, status)
  return surface == nil or surface.session_id == nil or surface.session_id == status.session_id
end

local function execution(status, surface)
  if not surface_is_active(surface, status) then
    return nil, nil
  end
  local value = status.execution_state
  if value == "running" or value == "pending" then
    return "DiagnosticWarn", value
  end
  if value == "failed" then
    return "DiagnosticError", "failed"
  end
  if value == "cancelled" then
    return "Comment", "cancelled"
  end
  if status.session_id ~= nil and status.settled ~= false then
    return "DiagnosticOk", "settled"
  end
  return nil, nil
end

local function session_label(status, surface)
  if surface ~= nil and surface.session_id ~= nil and surface.session_id ~= status.session_id then
    return short(surface.session_id, 18)
  end
  if status.title ~= nil and status.title ~= "" then
    return short(status.title, 28)
  end
  local id = surface and surface.session_id or status.session_id
  if id ~= nil then
    return short(id, 18)
  end
  return nil
end

local function model_label(status, surface)
  if not surface_is_active(surface, status) then
    return nil
  end
  local value = status.model_name or status.model_id
  if value == nil or value == "" then
    return nil
  end
  return "model " .. short(value, 28)
end

local function routing_label(status, surface)
  if not surface_is_active(surface, status) then
    return nil
  end
  local value = status.routing_profile_name or status.routing_profile_id
  if value == nil or value == "" then
    return nil
  end
  return "route " .. short(value, 22)
end

local function context_count(surface)
  local count = 0
  local document = surface and surface.compose
  for _ in pairs(document and document.items or {}) do
    count = count + 1
  end
  return count
end

local function transcript_value(surface)
  local status = runtime.status()
  local connection_group, connection_text = connection(status)
  local execution_group, execution_text = execution(status, surface)
  local parts = {
    segment("Title", " Phenix "),
    " ",
    segment(connection_group, connection_text),
  }
  local session = session_label(status, surface)
  if session ~= nil then
    table.insert(parts, "  ·  ")
    table.insert(parts, segment("Identifier", session))
  end
  if execution_text ~= nil then
    table.insert(parts, "  ·  ")
    table.insert(parts, segment(execution_group, execution_text))
  end

  local right = {}
  local model = model_label(status, surface)
  local routing = routing_label(status, surface)
  if model ~= nil then
    table.insert(right, segment("Special", model))
  end
  if routing ~= nil then
    table.insert(right, segment("Comment", routing))
  end
  if #right > 0 then
    table.insert(parts, "%=")
    table.insert(parts, " ")
    table.insert(parts, table.concat(right, "  ·  "))
    table.insert(parts, " ")
  end
  return table.concat(parts)
end

local function compose_value(surface)
  local count = context_count(surface)
  local parts = { segment("Title", " Prompt ") }
  if count > 0 then
    table.insert(parts, "  ·  ")
    table.insert(parts, segment("Comment", string.format("%d context", count)))
  end
  local status = runtime.status()
  if status.connection ~= "ready" then
    local group, text = connection(status)
    table.insert(parts, "%=")
    table.insert(parts, " ")
    table.insert(parts, segment(group, text))
    table.insert(parts, " ")
  end
  return table.concat(parts)
end

local function refresh_window(win, view)
  if not valid(win) then
    attached[win] = nil
    return
  end
  vim.wo[win].winbar = view.role == "compose" and compose_value(view.surface) or transcript_value(view.surface)
end

local function maybe_stop_listener()
  if next(attached) == nil and stop_listener ~= nil then
    stop_listener()
    stop_listener = nil
  end
end

function M.refresh()
  for win, view in pairs(attached) do
    refresh_window(win, view)
  end
  maybe_stop_listener()
end

function M.attach(transcript, compose, surface)
  if valid(transcript) then
    attached[transcript] = { role = "transcript", surface = surface }
  end
  if valid(compose) then
    attached[compose] = { role = "compose", surface = surface }
  end
  if stop_listener == nil and next(attached) ~= nil then
    stop_listener = runtime.on_event(function(kind)
      if kind == "status" or kind == "sessions" then
        M.refresh()
      end
    end)
  end
  M.refresh()
end

function M.detach(transcript, compose)
  if transcript == nil and compose == nil then
    attached = {}
  else
    if transcript ~= nil then
      attached[transcript] = nil
    end
    if compose ~= nil then
      attached[compose] = nil
    end
  end
  maybe_stop_listener()
end

return M

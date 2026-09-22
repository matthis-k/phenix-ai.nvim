local runtime = require("phenix_nvim.runtime")
local state = require("phenix_nvim.state")

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

local function execution(status)
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

local function session_label(status)
  if status.title ~= nil and status.title ~= "" then
    return short(status.title, 28)
  end
  if status.session_id ~= nil then
    return short(status.session_id, 18)
  end
  return nil
end

local function model_label(status)
  local value = status.model_name or status.model_id
  if value == nil or value == "" then
    return nil
  end
  return "model " .. short(value, 28)
end

local function routing_label(status)
  local value = status.routing_profile_name or status.routing_profile_id
  if value == nil or value == "" then
    return nil
  end
  return "route " .. short(value, 22)
end

local function context_count()
  local count = 0
  for _ in pairs(state.compose.items or {}) do
    count = count + 1
  end
  return count
end

local function transcript_value()
  local status = runtime.status()
  local connection_group, connection_text = connection(status)
  local execution_group, execution_text = execution(status)
  local parts = {
    segment("Title", " Phenix "),
    " ",
    segment(connection_group, connection_text),
  }
  local session = session_label(status)
  if session ~= nil then
    table.insert(parts, "  ·  ")
    table.insert(parts, segment("Identifier", session))
  end
  if execution_text ~= nil then
    table.insert(parts, "  ·  ")
    table.insert(parts, segment(execution_group, execution_text))
  end

  local right = {}
  local model = model_label(status)
  local routing = routing_label(status)
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

local function compose_value()
  local count = context_count()
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

local function refresh_window(win, role)
  if not valid(win) then
    attached[win] = nil
    return
  end
  vim.wo[win].winbar = role == "compose" and compose_value() or transcript_value()
end

local function maybe_stop_listener()
  if next(attached) == nil and stop_listener ~= nil then
    stop_listener()
    stop_listener = nil
  end
end

function M.refresh()
  for win, role in pairs(attached) do
    refresh_window(win, role)
  end
  maybe_stop_listener()
end

function M.attach(transcript, compose)
  if valid(transcript) then
    attached[transcript] = "transcript"
  end
  if valid(compose) then
    attached[compose] = "compose"
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

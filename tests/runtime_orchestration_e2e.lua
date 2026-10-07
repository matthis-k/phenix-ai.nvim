local frontend = require("phenix_nvim")
local runtime = require("phenix_nvim.runtime")

local command = assert(vim.env.PHENIX_FIXTURE_ACP, "PHENIX_FIXTURE_ACP is required")
local state_db = assert(vim.env.PHENIX_STATE_DB, "PHENIX_STATE_DB is required")

local first_marker = "PHENIX_FIXTURE_CHILD_CLOSE_FIRST"
local first_done = "PHENIX_FIXTURE_CHILD_CLOSE_DONE"
local second_marker = "PHENIX_FIXTURE_CHILD_CLOSE_SECOND"
local second_done = "PHENIX_FIXTURE_SECOND_DONE"

frontend.setup({
  auto_connect = false,
  command = command,
  env = {
    PHENIX_STATE_DB = state_db,
  },
})

local connected = false
local connection_error = nil
frontend.connect(function(_, err)
  connection_error = err
  connected = true
end)
assert(vim.wait(10000, function()
  return connected
end, 10), "fixture connection timed out")
assert(connection_error == nil, vim.inspect(connection_error))

local created = nil
local create_error = nil
frontend.new_session(function(result, err)
  created = result
  create_error = err
end)
assert(vim.wait(10000, function()
  return created ~= nil or create_error ~= nil
end, 10), "controller session creation timed out")
assert(create_error == nil, vim.inspect(create_error))
local session_id = assert(runtime.active_session(), "controller session did not become active")

local function prompt(text)
  local result = nil
  local prompt_error = nil
  runtime.prompt(session_id, {
    { kind = "text", text = text },
  }, function(value, err)
    result = value
    prompt_error = err
  end)
  assert(vim.wait(10000, function()
    return result ~= nil or prompt_error ~= nil
  end, 10), "prompt timed out for " .. text)
  assert(prompt_error == nil, vim.inspect({
    error = prompt_error,
    controller_session = session_id,
    active_session = runtime.active_session(),
    controller_closed_in_projection = controller_is_closed(),
  }))
  assert(result ~= nil, "prompt completed without a result for " .. text)
  return result
end

local function normalized_kind(value)
  if type(value) == "table" then
    value = value.kind or value.tag
  end
  return string.lower(tostring(value or "")):gsub("_", "")
end

local function controller_projection()
  return runtime.session_state().sessions[session_id]
end

local function controller_is_closed()
  local projection = controller_projection()
  if projection == nil then
    return false
  end
  for _, entry in ipairs(projection.updates or {}) do
    local change = entry.update or {}
    if normalized_kind(change.kind) == "closed" then
      return true
    end
  end
  return false
end

local function has_assistant_text(expected)
  local projection = controller_projection()
  if projection == nil then
    return false
  end
  for _, entry in ipairs(projection.updates or {}) do
    local change = entry.update or {}
    if normalized_kind(change.kind) == "message"
        and change.message ~= nil
        and normalized_kind(change.message.role) == "assistant" then
      for _, item in ipairs(change.message.content or {}) do
        if normalized_kind(item.kind) == "text"
            and type(item.text) == "string"
            and item.text:find(expected, 1, true) ~= nil then
          return true
        end
      end
    end
  end
  return false
end

local first = prompt(first_marker)
assert(type(first.execution_id) == "string" and first.execution_id ~= "", "first orchestration omitted execution id")
assert(vim.wait(10000, function()
  return has_assistant_text(first_done)
end, 10), "child-session close orchestration did not reach its final response")
assert(runtime.active_session() == session_id, "child-session orchestration replaced the controller session")
assert(not controller_is_closed(), "child-session close projected Closed onto controller " .. session_id)
assert(runtime.status().connection == "ready", "child-session close left the Neovim client disconnected")

local second = prompt(second_marker)
assert(type(second.execution_id) == "string" and second.execution_id ~= "", "second prompt omitted execution id")
assert(second.execution_id ~= first.execution_id, "second prompt reused the completed controller execution")
assert(vim.wait(10000, function()
  return has_assistant_text(second_done)
end, 10), "controller session did not complete a prompt after child-session close")
assert(runtime.active_session() == session_id, "second prompt changed the active controller session")
assert(runtime.status().connection == "ready", "controller session was unusable after child-session close")

frontend.disconnect()
print("child-session close preserves the Neovim controller session")

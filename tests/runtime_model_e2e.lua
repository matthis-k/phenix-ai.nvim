local frontend = require("phenix_nvim")
local runtime = require("phenix_nvim.runtime")
local sidebar = require("phenix_nvim.sidebar")
local transcript = require("phenix_nvim.transcript.controller")
local transcript_buffer = require("phenix_nvim.transcript.buffer")

local command = assert(vim.env.PHENIX_FIXTURE_ACP, "PHENIX_FIXTURE_ACP is required")
local log_directory = assert(vim.env.PHENIX_NVIM_LOG_DIRECTORY, "PHENIX_NVIM_LOG_DIRECTORY is required")
local log_file = log_directory .. "/phenix.log"
local marker = "PHENIX_NVIM_E2E_MARKER"
local expected = "PHENIX_NVIM_E2E_RESPONSE"

frontend.setup({
  auto_connect = false,
  command = command,
  selection = "fixture.deterministic",
  log_directory = log_directory,
  env = {
    PHENIX_STATE_DB = assert(vim.env.PHENIX_STATE_DB, "PHENIX_STATE_DB is required"),
    PHENIX_FIXTURE_EXPECT_INPUT = marker,
    PHENIX_FIXTURE_RESPONSE = expected,
  },
})
vim.cmd.runtime("plugin/phenix.lua")

local connected = false
local connection_error = nil
local created_session = nil
local create_error = nil
frontend.connect(function(_, err)
  connection_error = err
  connected = true
end)
frontend.new_session(function(result, err)
  created_session = result
  create_error = err
end)
assert(vim.wait(10000, function()
  return connected and (created_session ~= nil or create_error ~= nil)
end, 10), "deterministic fixture connection/session bootstrap timed out")
assert(connection_error == nil, vim.inspect(connection_error))
assert(create_error == nil, vim.inspect(create_error))
assert(created_session ~= nil, "session request issued while connecting was dropped")
assert(vim.wait(10000, function()
  return vim.fn.filereadable(log_file) == 1 and vim.fn.getfsize(log_file) > 0
end, 10), "Neovim-configured Phenix root log was not created")
local initial_log = table.concat(vim.fn.readfile(log_file), "\n")
assert(initial_log:find('"kind":"debug_started"', 1, true) ~= nil, "runtime startup was not logged")
local initial_log_lines = #vim.fn.readfile(log_file)

local session_id = assert(runtime.active_session())

local selections = nil
local selection_error = nil
runtime.list_selections(function(result, err)
  selections = result
  selection_error = err
end)
assert(vim.wait(10000, function()
  return selections ~= nil or selection_error ~= nil
end, 10), "deterministic fixture selection discovery timed out")
assert(selection_error == nil, vim.inspect(selection_error))

local fixture = nil
local introspection_fixture = nil
for _, item in ipairs(selections.available or {}) do
  if item.id == "fixture.deterministic" then
    fixture = item
  elseif item.id == "fixture.introspection" then
    introspection_fixture = item
  end
end
assert(fixture ~= nil, "deterministic fixture route was not exposed by the packaged runtime")
assert(introspection_fixture ~= nil, "introspection fixture route was not exposed by the packaged runtime")

local selected = nil
local select_error = nil
runtime.select(fixture.id, function(result, err)
  selected = result
  select_error = err
end)
assert(vim.wait(10000, function()
  return selected ~= nil or select_error ~= nil
end, 10), "deterministic fixture selection timed out")
assert(select_error == nil, vim.inspect(select_error))
assert(selected.selected == fixture.id, "deterministic fixture route was not selected")

local function normalized_kind(value)
  if type(value) == "table" then
    value = value.kind or value.tag
  end
  return string.lower(tostring(value or "")):gsub("_", "")
end

local function text_content(content_items)
  local parts = {}
  for _, item in ipairs(content_items or {}) do
    if normalized_kind(item.kind) == "text" and type(item.text) == "string" then
      table.insert(parts, item.text)
    end
  end
  return table.concat(parts)
end

local function find_assistant_after(user_text, predicate)
  local projection = runtime.session_state().sessions[session_id]
  if projection == nil then
    return nil
  end

  local saw_user = false
  for _, entry in ipairs(projection.updates or {}) do
    local change = entry.update or {}
    if normalized_kind(change.kind) == "message" and change.message ~= nil then
      local role = normalized_kind(change.message.role)
      local text = text_content(change.message.content)
      if role == "user" then
        saw_user = text == user_text
      elseif saw_user and role == "assistant" and predicate(text) then
        return text
      end
    end
  end
  return nil
end

local function find_completed_turn(user_text, excluded)
  local projection = runtime.session_state().sessions[session_id]
  if projection == nil then
    return nil
  end

  local saw_user = false
  local saw_assistant = false
  local candidates = {}
  local states = {}

  for _, entry in ipairs(projection.updates or {}) do
    local change = entry.update or {}
    local change_kind = normalized_kind(change.kind)
    if change_kind == "message" and change.message ~= nil then
      local role = normalized_kind(change.message.role)
      if role == "user" and text_content(change.message.content) == user_text then
        saw_user = true
      elseif role == "assistant" and text_content(change.message.content) == expected then
        saw_assistant = true
      end
    elseif change_kind == "textdelta" and change.text == expected then
      local execution_id = change.execution_id
      if execution_id ~= nil and not excluded[execution_id] then
        candidates[execution_id] = true
      end
    elseif change_kind == "execution"
        and change.execution_id ~= nil
        and change.update ~= nil
        and normalized_kind(change.update.kind) == "state" then
      local execution_id = change.execution_id
      states[execution_id] = states[execution_id] or {}
      states[execution_id][normalized_kind(change.update.state)] = true
    end
  end

  if not saw_user or not saw_assistant then
    return nil
  end

  for execution_id in pairs(candidates) do
    local execution_states = states[execution_id] or {}
    if execution_states.running and execution_states.completed then
      return execution_id
    end
  end
  return nil
end

local function wait_for_completed_turn(user_text, excluded)
  local execution_id = nil
  assert(vim.wait(10000, function()
    execution_id = find_completed_turn(user_text, excluded)
    return execution_id ~= nil
  end, 10), "deterministic model turn timed out for " .. user_text)
  return assert(execution_id)
end

local function compose_text(text)
  local compose_win = sidebar.focus_compose()
  local _, compose_buffer = sidebar.buffers()
  vim.api.nvim_set_current_win(compose_win)
  vim.api.nvim_buf_set_lines(compose_buffer, 0, -1, false, { text })
  return compose_buffer
end

local function assert_compose_cleared(compose_buffer)
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(compose_buffer, 0, -1, false), { "" }),
    "successful send did not clear the compose buffer"
  )
  assert(not vim.bo[compose_buffer].modified, "successful send left the compose buffer modified")
end

local function assert_transcript(execution_id)
  transcript.refresh()
  local assistant_id = "session:" .. session_id .. ":execution:" .. execution_id .. ":assistant"
  local node = assert(transcript.projection().nodes[assistant_id], "transcript did not create the assistant node")
  assert(node.text == expected, "transcript changed the deterministic assistant response")
  assert(node.final == true, "transcript did not finalize the assistant node")

  local buffer = transcript_buffer.ensure()
  local rendered = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  assert(rendered:find(expected, 1, true) ~= nil, "rendered transcript does not contain the deterministic response")
  return assistant_id, buffer
end

local excluded = {}

local command_text = marker .. " command"
local compose_buffer = compose_text(command_text)
vim.cmd("Phenix send")
local first_execution_id = wait_for_completed_turn(command_text, excluded)
excluded[first_execution_id] = true
assert_compose_cleared(compose_buffer)
local first_assistant_id, rendered_buffer = assert_transcript(first_execution_id)

frontend.disconnect()

local reconnected = false
local reconnect_error = nil
frontend.connect(function(_, err)
  reconnect_error = err
  reconnected = true
end)
assert(vim.wait(10000, function()
  return reconnected
end, 10), "deterministic fixture reconnect timed out")
assert(reconnect_error == nil, vim.inspect(reconnect_error))
assert(vim.wait(10000, function()
  return #vim.fn.readfile(log_file) > initial_log_lines
end, 10), "reconnect did not append to the Phenix log file")
local reconnected_log = table.concat(vim.fn.readfile(log_file), "\n")
local _, startup_count = reconnected_log:gsub('"kind":"debug_started"', "")
assert(startup_count >= 2, "append log must retain both runtime startup records")

local resumed = false
local resume_error = nil
runtime.resume_session(session_id, function(snapshot, err)
  resume_error = err
  resumed = snapshot ~= nil
end)
assert(vim.wait(10000, function()
  return resumed or resume_error ~= nil
end, 10), "deterministic fixture session resume timed out")
assert(resume_error == nil, vim.inspect(resume_error))
assert(runtime.active_session() == session_id, "deterministic restart resumed the wrong session")

local recovered = assert(runtime.session_state().sessions[session_id], "restart lost the durable session projection")
local recovered_assistant = false
for _, entry in ipairs(recovered.updates or {}) do
  local change = entry.update or {}
  if normalized_kind(change.kind) == "message"
      and change.message ~= nil
      and normalized_kind(change.message.role) == "assistant"
      and text_content(change.message.content) == expected then
    recovered_assistant = true
    break
  end
end
assert(recovered_assistant, "restart lost the deterministic assistant message")

transcript.refresh()
local recovered_node = assert(
  transcript.projection().nodes[first_assistant_id],
  "restart did not reconstruct the assistant transcript node"
)
assert(recovered_node.text == expected, "restart changed the deterministic assistant response")
assert(recovered_node.final == true, "restart reconstructed the assistant node as unfinished")
local recovered_rendered = table.concat(vim.api.nvim_buf_get_lines(rendered_buffer, 0, -1, false), "\n")
assert(
  recovered_rendered:find(expected, 1, true) ~= nil,
  "restart did not render the recovered deterministic assistant response"
)

local write_text = marker .. " write"
compose_buffer = compose_text(write_text)
vim.cmd("write")
local second_execution_id = wait_for_completed_turn(write_text, excluded)
excluded[second_execution_id] = true
assert(second_execution_id ~= first_execution_id, "write send reused the previous durable execution id")
assert_compose_cleared(compose_buffer)
assert_transcript(second_execution_id)

local enter_text = marker .. " normal enter"
compose_buffer = compose_text(enter_text)
local enter_mapping = nil
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(compose_buffer, "n")) do
  if mapping.lhs == "<CR>" then
    enter_mapping = mapping
    break
  end
end
assert(enter_mapping ~= nil, "normal-mode Enter send mapping is missing")
assert(type(enter_mapping.callback) == "function", "normal-mode Enter mapping must call the send action")
enter_mapping.callback()
local third_execution_id = wait_for_completed_turn(enter_text, excluded)
excluded[third_execution_id] = true
assert(third_execution_id ~= second_execution_id, "normal Enter send reused the previous execution id")
assert_compose_cleared(compose_buffer)
assert_transcript(third_execution_id)

for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(compose_buffer, "i")) do
  assert(mapping.lhs ~= "<CR>", "insert-mode Enter must remain available for newlines")
end

local introspection_selected = nil
local introspection_select_error = nil
runtime.select(introspection_fixture.id, function(result, err)
  introspection_selected = result
  introspection_select_error = err
end)
assert(vim.wait(10000, function()
  return introspection_selected ~= nil or introspection_select_error ~= nil
end, 10), "introspection fixture selection timed out")
assert(introspection_select_error == nil, vim.inspect(introspection_select_error))
assert(
  introspection_selected.selected == introspection_fixture.id,
  "introspection fixture route was not selected"
)

local introspection_text = marker .. " introspection"
compose_buffer = compose_text(introspection_text)
vim.cmd("Phenix send")
assert_compose_cleared(compose_buffer)

local introspection_report = nil
assert(vim.wait(10000, function()
  local response = find_assistant_after(introspection_text, function(text)
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" or decoded.model ~= "fixture-introspection" then
      return false
    end
    introspection_report = decoded
    return true
  end)
  return response ~= nil and introspection_report ~= nil
end, 10), "introspection model turn timed out")

assert(type(introspection_report.tools) == "table", "introspection report omitted tools")
local bash_tool = nil
for _, tool in ipairs(introspection_report.tools) do
  if tool.id == "bash" then
    bash_tool = tool
    break
  end
end
assert(bash_tool ~= nil, "default runtime bash tool did not reach the model boundary")
assert(
  vim.inspect(bash_tool.input_schema):find("command", 1, true) ~= nil,
  "model-visible bash schema omitted the command field"
)
assert(type(introspection_report.skills) == "table", "introspection report omitted skills")
assert(
  type(introspection_report.instructions) == "table" and #introspection_report.instructions > 0,
  "normal Phenix instruction context did not reach the model boundary"
)
assert(
  type(introspection_report.request) == "string"
    and introspection_report.request:find(introspection_text, 1, true) ~= nil,
  "introspection report did not preserve the user request"
)

transcript.refresh()
local introspection_rendered = table.concat(vim.api.nvim_buf_get_lines(rendered_buffer, 0, -1, false), "\n")
assert(
  introspection_rendered:find('"fixture-introspection"', 1, true) ~= nil,
  "rendered transcript omitted the introspection model report"
)
assert(
  introspection_rendered:find('"bash"', 1, true) ~= nil,
  "rendered transcript omitted the model-visible bash tool"
)

frontend.disconnect()
print("phenix-ai.nvim command, write, normal Enter, model pipeline, introspection and restart passed")

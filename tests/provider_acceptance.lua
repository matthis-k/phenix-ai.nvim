local phase = assert(vim.env.PHENIX_ACCEPTANCE_PHASE, "PHENIX_ACCEPTANCE_PHASE is required")
local state_db = assert(vim.env.PHENIX_STATE_DB, "PHENIX_STATE_DB is required")
local session_id_file = assert(vim.env.PHENIX_SESSION_ID_FILE, "PHENIX_SESSION_ID_FILE is required")

local function pack(...)
  return { n = select("#", ...), ... }
end

local function sleep(milliseconds)
  vim.wait(milliseconds, function()
    return false
  end, milliseconds)
end

local function fail(label, error_value)
  if type(error_value) == "table" and error_value.message ~= nil then
    error(label .. ": " .. error_value.message)
  end
  error(label .. ": " .. tostring(error_value))
end

local function kind_is(value, raw, projected)
  return value == raw or value == projected
end

local function assert_realized_projection(projection, tool_id)
  local saw_call = false
  local saw_result = false
  local saw_assistant = false

  for _, entry in ipairs(projection.updates or {}) do
    local change = entry.update
    if change ~= nil and kind_is(change.kind, "Execution", "execution") then
      local execution = change.update
      if execution ~= nil
          and kind_is(execution.kind, "ToolCall", "tool_call")
          and execution.callable_id == tool_id then
        saw_call = true
      elseif execution ~= nil and kind_is(execution.kind, "ToolResult", "tool_result") then
        saw_result = true
      end
    elseif change ~= nil
        and kind_is(change.kind, "TextDelta", "text_delta")
        and type(change.text) == "string"
        and change.text ~= "" then
      saw_assistant = true
    end
  end

  assert(saw_call, "provider acceptance did not persist the client tool call")
  assert(saw_result, "provider acceptance did not persist the client tool result")
  assert(saw_assistant, "provider acceptance did not persist provider-backed assistant output")
end

if phase == "run" then
  local api_key = assert(vim.env.OPENAI_API_KEY, "OPENAI_API_KEY is required")
  assert(api_key ~= "", "OPENAI_API_KEY must not be empty")
  local phenix = require("phenix")
  local client = phenix.connect({
    command = assert(vim.env.PHENIX_ACCEPTANCE_PHENIX, "PHENIX_ACCEPTANCE_PHENIX is required"),
    args = { "--mode", "acp" },
    env = {
      PHENIX_STATE_DB = state_db,
      OPENAI_API_KEY = api_key,
    },
  })

  local function poll_client()
    local ok, error_value = pcall(client.poll, client)
    if not ok then
      fail("client poll", error_value)
    end
  end

  local function await(request, label)
    for _ = 1, 12000 do
      poll_client()
      local result = pack(request:poll())
      if result.n > 0 then
        if result[2] ~= nil then
          fail(label, result[2])
        end
        return result[1]
      end
      sleep(10)
    end
    error(label .. ": timed out")
  end

  local ready = false
  for _ = 1, 3000 do
    poll_client()
    local extensions = client:extensions()
    if extensions["phenix.application.prompt@1"] == true
        and extensions["phenix.application.client-tool-add@1"] == true
        and extensions["phenix.application.interaction-handlers-set@1"] == true then
      ready = true
      break
    end
    sleep(10)
  end
  assert(ready, "packaged Phenix ACP mode did not advertise provider acceptance operations")

  local application = client:application()
  local function operation(id)
    local descriptor = assert(phenix.descriptor.operations[id], "missing application operation " .. id)
    return assert(application[descriptor.name], "unsupported application operation " .. id)
  end

  local permission_calls = 0
  local elicitation_calls = 0
  await(operation("phenix.application.interaction-handlers-set@1")({
    handlers = {
      permission = function(request)
        permission_calls = permission_calls + 1
        assert(type(request.call_id) == "string")
        return { kind = "AllowOnce" }
      end,
      elicitation = function(_request)
        elicitation_calls = elicitation_calls + 1
        return { kind = "Declined" }
      end,
    },
  }), "interaction handler registration")

  local session = await(operation("phenix.application.session-create@1")({
    working_directory = vim.fn.getcwd(),
    title = "provider acceptance",
  }), "session create")
  local session_id = assert(session.session_id)
  assert(vim.fn.writefile({ session_id }, session_id_file) == 0, "could not persist acceptance session id")

  local tool_id = "acceptance_echo"
  local tool_calls = 0
  local registration = client:tools().register({
    session_id = session_id,
    id = tool_id,
    description = "Return the exact value supplied by the model. Provider acceptance requires calling this tool before answering.",
    input = {
      type = "map",
      value = { type = "string" },
    },
    output = { type = "string" },
    requires_permission = true,
  }, function(value)
    tool_calls = tool_calls + 1
    assert(type(value) == "table", "client tool input must be a table")
    assert(type(value.value) == "string", "client tool requires string field value")
    return "client-result:" .. value.value
  end)
  local remove_tool = await(registration, "client tool registration")
  assert(type(remove_tool) == "function")

  local listed = await(operation("phenix.application.callable-list@1")({
    session_id = session_id,
  }), "client tool listing")
  local visible = false
  for _, callable in ipairs(listed.callables or {}) do
    if callable.id == tool_id then
      visible = true
      break
    end
  end
  assert(visible, "admitted client tool is not visible through the ordinary callable surface")

  for attempt = 1, 3 do
    await(operation("phenix.application.prompt@1")({
      session_id = session_id,
      content = {
        {
          kind = "Text",
          text = string.format(
            "Provider acceptance attempt %d. You must call the tool %s exactly once with JSON arguments {\"value\":\"provider-proof\"}. After the tool returns, answer with a short confirmation. Do not answer before using the tool.",
            attempt,
            tool_id
          ),
        },
      },
    }), "provider-backed prompt")
    if tool_calls > 0 then
      break
    end
  end

  assert(tool_calls > 0, "real provider never called the admitted client tool")
  assert(permission_calls > 0, "client tool ran without exercising the permission callback")
  assert(elicitation_calls == 0, "provider tool flow unexpectedly invoked elicitation")

  local snapshot = await(operation("phenix.application.session-resume@1")({
    session_id = session_id,
  }), "session snapshot")
  assert_realized_projection({ updates = snapshot.updates or {} }, tool_id)

  await(remove_tool(), "client tool removal")
  print("provider acceptance live phase passed")
elseif phase == "resume" then
  local frontend = require("phenix_nvim")
  local runtime = require("phenix_nvim.runtime")
  frontend.setup({ auto_connect = false })

  local connected = false
  local connection_error = nil
  frontend.connect(function(_, error_value)
    connection_error = error_value
    connected = true
  end)
  assert(vim.wait(10000, function()
    return connected
  end, 10), "provider acceptance reconnect timed out")
  assert(connection_error == nil, vim.inspect(connection_error))

  local session_id = assert(vim.fn.readfile(session_id_file)[1], "missing provider acceptance session id")
  local resumed = false
  local resume_error = nil
  runtime.resume_session(session_id, function(snapshot, error_value)
    resume_error = error_value
    resumed = snapshot ~= nil
  end)
  assert(vim.wait(10000, function()
    return resumed or resume_error ~= nil
  end, 10), "provider acceptance resume timed out")
  assert(resume_error == nil, vim.inspect(resume_error))
  assert(runtime.active_session() == session_id, "provider acceptance resumed the wrong session")

  local state = assert(runtime.session_state(), "provider acceptance restart must publish session state")
  local projection = assert(state.sessions[session_id], "provider acceptance restart lost the durable session")
  assert_realized_projection(projection, "acceptance_echo")
  frontend.disconnect()
  print("provider acceptance restart phase passed")
else
  error("unknown PHENIX_ACCEPTANCE_PHASE: " .. phase)
end

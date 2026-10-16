-- Map runtime ACP events into the existing Neovim transcript projection.
-- This is render state only. Phenix's durable session and journal remain authoritative.
local M = {}
local Adapter = {}
Adapter.__index = Adapter

function M.new()
  return setmetatable({ sessions = {} }, Adapter)
end

local function text(content)
  if type(content) ~= "table" then return "" end
  if content.type == "text" then return tostring(content.text or "") end
  local chunks = {}
  for _, part in ipairs(content) do
    if type(part) == "table" then
      local block = part.content or part
      if type(block) == "table" and block.type == "text" then
        chunks[#chunks + 1] = tostring(block.text or "")
      end
    end
  end
  return table.concat(chunks, "\n")
end

function Adapter:_scope(session_id)
  local state = self.sessions[session_id]
  if state then return state end
  state = {
    current_run = nil,
    projection = {
      session = { session_id = session_id },
      through_sequence = 0,
      updates = {},
    },
  }
  self.sessions[session_id] = state
  return state
end

function Adapter:apply(event)
  if type(event) ~= "table" or event.type ~= "session.updated"
    or type(event.session_id) ~= "string" or event.session_id == ""
    or type(event.update) ~= "table"
  then return false end

  local update = event.update
  local state = self:_scope(event.session_id)
  local kind = update.sessionUpdate
  local converted
  if kind == "user_message_chunk" and type(update.content) == "table" then
    if type(update.messageId) == "string" then
      state.current_run = update.messageId:gsub(":user$", "")
    end
    converted = {
      kind = "message",
      message = { role = { kind = "user" },
        content = { { kind = "text", text = text(update.content) } } },
    }
  elseif kind == "agent_message_chunk" and type(update.content) == "table" then
    local run = update.messageId or state.current_run or "acp"
    converted = { kind = "text_delta", execution_id = run,
      text = text(update.content) }
  elseif kind == "tool_call" and type(update.toolCallId) == "string" then
    converted = {
      kind = "execution", execution_id = state.current_run or "acp",
      update = { kind = "tool_call", call_id = update.toolCallId,
        callable_id = update.title, input = update.rawInput },
    }
  elseif kind == "tool_call_update" and type(update.toolCallId) == "string" then
    local failed = update.status == "failed"
    converted = {
      kind = "execution", execution_id = state.current_run or "acp",
      update = { kind = failed and "tool_failed" or "tool_result",
        call_id = update.toolCallId,
        output = not failed and text(update.content) or nil,
        error = failed and text(update.content) or nil },
    }
  end
  if not converted then return false end
  local projection = state.projection
  local next_sequence = projection.through_sequence + 1
  projection.through_sequence = next_sequence
  projection.updates[#projection.updates + 1] = {
    session_id = event.session_id, sequence = next_sequence,
    update = converted,
  }
  return true
end

function Adapter:session(session_id)
  local state = self.sessions[session_id]
  return state and vim.deepcopy(state.projection) or nil
end

function Adapter:session_state()
  local projections = {}
  for id, state in pairs(self.sessions) do
    projections[id] = vim.deepcopy(state.projection)
  end
  return { sessions = projections }
end

function Adapter:restore(session_id, snapshot)
  assert(type(session_id) == "string")
  if not snapshot then
    self.sessions[session_id] = nil
    return
  end
  self.sessions[session_id] = { projection = vim.deepcopy(snapshot) }
end

function Adapter:clear(session_id)
  if session_id == nil then
    self.sessions = {}
  else
    self.sessions[session_id] = nil
  end
end

return M

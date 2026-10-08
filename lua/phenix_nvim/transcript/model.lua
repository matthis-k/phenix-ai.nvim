local M = {}

local function snake(value)
  if type(value) ~= "string" then
    return value
  end
  return value:gsub("(%l)(%u)", "%1_%2"):lower()
end

local function variant_kind(value)
  return type(value) == "table" and snake(value.kind) or nil
end

local function role_name(role)
  local kind = variant_kind(role)
  if type(kind) == "string" then
    return kind
  end
  return tostring(role or "unknown"):lower()
end

local function id(prefix, suffix)
  return prefix .. suffix
end

local function upsert(projection, node)
  if projection.nodes[node.id] == nil then
    table.insert(projection.order, node.id)
  end
  projection.nodes[node.id] = node
  return node.id
end

local function message_text(content)
  local parts = {}
  for _, part in ipairs(content or {}) do
    local kind = snake(part.kind)
    if kind == "text" then
      table.insert(parts, part.text or "")
    elseif kind == "resource" then
      local label = part.uri or "resource"
      if part.text ~= nil then
        table.insert(parts, part.text)
      else
        table.insert(parts, "[resource: " .. label .. "]")
      end
    elseif kind == "image" then
      table.insert(parts, "[image: " .. tostring(part.mime_type or "unknown") .. "]")
    end
  end
  return table.concat(parts)
end

local function message_id(projection, sequence)
  return id(projection.prefix, "sequence:" .. sequence)
end

local function assistant_id(projection, execution_id)
  return id(projection.prefix, "execution:" .. execution_id .. ":assistant")
end

local function execution_state_id(projection, execution_id)
  return id(projection.prefix, "execution:" .. execution_id .. ":state")
end

local function thinking_id(projection, execution_id)
  return id(projection.prefix, "execution:" .. execution_id .. ":thinking")
end

local function tool_id(projection, execution_id, call_id)
  return id(projection.prefix, "execution:" .. execution_id .. ":tool:" .. call_id)
end

local function diagnostic_id(projection, sequence)
  return id(projection.prefix, "sequence:" .. sequence .. ":diagnostic")
end

local function review_id(projection, review_id_value)
  return id(projection.prefix, "review:" .. review_id_value)
end

function M.new(session_id)
  local prefix = session_id and ("session:" .. session_id .. ":") or ""
  return {
    session_id = session_id,
    prefix = prefix,
    sequence = 0,
    order = {},
    nodes = {},
    streaming_execution_id = nil,
  }
end

local function apply_execution(projection, execution_id, change)
  local kind = variant_kind(change)
  if kind == "state" then
    local state = variant_kind(change.state) or "unknown"
    local node_id = execution_state_id(projection, execution_id)
    local changed = upsert(projection, {
      id = node_id,
      kind = "execution",
      execution_id = execution_id,
      state = state,
    })
    if state == "completed" or state == "cancelled" or state == "failed" then
      if projection.streaming_execution_id == execution_id then
        projection.streaming_execution_id = nil
      end
    end
    return changed
  end
  if kind == "tool_call" then
    return upsert(projection, {
      id = tool_id(projection, execution_id, change.call_id),
      kind = "tool",
      execution_id = execution_id,
      call_id = change.call_id,
      callable_id = change.callable_id,
      state = "running",
      input = change.input,
    })
  end
  if kind == "tool_result" or kind == "tool_failed" then
    local node_id = tool_id(projection, execution_id, change.call_id)
    local node = projection.nodes[node_id]
    if node == nil or node.kind ~= "tool" then
      return nil, "tool result targets unknown call " .. tostring(change.call_id)
    end
    node.state = kind == "tool_result" and "completed" or "failed"
    node.output = kind == "tool_result" and change.output or change.error
    return node_id
  end
  if kind == "tool_output_delta" then
    local node_id = tool_id(projection, execution_id, change.call_id)
    local node = projection.nodes[node_id]
    if node == nil or node.kind ~= "tool" then
      return nil, "tool output targets unknown call " .. tostring(change.call_id)
    end
    local stream = variant_kind(change.stream) or snake(change.stream)
    if stream ~= "stdout" and stream ~= "stderr" then
      return nil, "unknown tool output stream " .. tostring(stream)
    end
    node.output_streams = node.output_streams or { stdout = "", stderr = "" }
    node.output_streams[stream] = node.output_streams[stream] .. (change.text or "")
    return node_id
  end
  if kind == "progress" then
    local node_id = execution_state_id(projection, execution_id)
    local node = projection.nodes[node_id]
    if node == nil then
      node = {
        id = node_id,
        kind = "execution",
        execution_id = execution_id,
        state = "running",
      }
      upsert(projection, node)
    end
    node.message = change.message
    node.fraction = change.fraction
    return node_id
  end
  return nil, "unsupported execution change " .. tostring(kind)
end

function M.apply(projection, update)
  if type(update) ~= "table" or type(update.sequence) ~= "number" then
    return nil, "session update is missing a sequence"
  end
  if projection.session_id ~= nil and update.session_id ~= projection.session_id then
    return nil, "session update targets a different session"
  end
  local expected = projection.sequence + 1
  if update.sequence ~= expected then
    return nil, string.format("transcript sequence gap: expected %d, got %d", expected, update.sequence)
  end

  local change = update.update
  local kind = variant_kind(change)
  if kind == nil then
    return nil, "session update is missing a variant kind"
  end

  local changed
  local err
  if kind == "message" then
    local role = role_name(change.message and change.message.role)
    local text = message_text(change.message and change.message.content)
    if role == "assistant" and projection.streaming_execution_id ~= nil then
      local streaming_id = assistant_id(projection, projection.streaming_execution_id)
      local streaming = projection.nodes[streaming_id]
      if streaming ~= nil and streaming.kind == "message" then
        streaming.text = text
        streaming.content = change.message.content
        streaming.final = true
        changed = streaming_id
      end
    end
    if changed == nil then
      changed = upsert(projection, {
        id = message_id(projection, update.sequence),
        kind = "message",
        role = role,
        text = text,
        content = change.message and change.message.content or {},
        final = true,
      })
    end
  elseif kind == "reasoning_delta" then
    local node_id = thinking_id(projection, change.execution_id)
    local node = projection.nodes[node_id]
    if node == nil then
      node = {
        id = node_id,
        kind = "thinking",
        execution_id = change.execution_id,
        text = "",
      }
      upsert(projection, node)
    end
    node.text = node.text .. (change.text or "")
    changed = node_id
  elseif kind == "text_delta" then
    local node_id = assistant_id(projection, change.execution_id)
    local node = projection.nodes[node_id]
    if node == nil then
      node = {
        id = node_id,
        kind = "message",
        role = "assistant",
        text = "",
        content = {},
        final = false,
        execution_id = change.execution_id,
      }
      upsert(projection, node)
    end
    node.text = node.text .. (change.text or "")
    projection.streaming_execution_id = change.execution_id
    changed = node_id
  elseif kind == "execution" then
    changed, err = apply_execution(projection, change.execution_id, change.update)
  elseif kind == "diagnostic" then
    local diagnostic = change.diagnostic or {}
    changed = upsert(projection, {
      id = diagnostic_id(projection, update.sequence),
      kind = "diagnostic",
      severity = role_name(diagnostic.severity),
      code = diagnostic.code,
      message = diagnostic.message,
      resource = diagnostic.resource,
    })
  elseif kind == "review" then
    local review = change.review or {}
    if type(review.id) ~= "string" or review.id == "" then
      err = "review update is missing review id"
    else
      changed = upsert(projection, {
        id = review_id(projection, review.id),
        kind = "review",
        review = review,
      })
    end
  elseif kind == "renamed" or kind == "closed" then
    changed = false
  else
    err = "unsupported session change " .. tostring(kind)
  end

  if err ~= nil then
    return nil, err
  end
  projection.sequence = update.sequence
  return changed
end

function M.rebuild(session_projection)
  if type(session_projection) ~= "table" or type(session_projection.session) ~= "table" then
    return nil, "invalid session projection"
  end
  local session_id = session_projection.session.session_id
  if type(session_id) ~= "string" or session_id == "" then
    return nil, "session projection is missing session id"
  end
  local projection = M.new(session_id)
  for _, update in ipairs(session_projection.updates or {}) do
    local _, err = M.apply(projection, update)
    if err ~= nil then
      return nil, err
    end
  end
  if projection.sequence ~= (session_projection.through_sequence or 0) then
    return nil, string.format(
      "session projection watermark mismatch: reduced %d, expected %d",
      projection.sequence,
      session_projection.through_sequence or 0
    )
  end
  return projection
end

function M.sync(projection, session_projection)
  if projection.session_id ~= session_projection.session.session_id then
    return nil, "selected session changed"
  end
  local watermark = session_projection.through_sequence or 0
  if watermark < projection.sequence then
    return nil, "session projection moved backwards"
  end
  if watermark == projection.sequence then
    return {}
  end

  local changed = {}
  for _, update in ipairs(session_projection.updates or {}) do
    if update.sequence > projection.sequence then
      local node_id, err = M.apply(projection, update)
      if err ~= nil then
        return nil, err
      end
      if node_id then
        changed[node_id] = true
      end
    end
  end
  if projection.sequence ~= watermark then
    return nil, string.format("session projection suffix did not reach watermark %d", watermark)
  end
  local ordered = {}
  for _, node_id in ipairs(projection.order) do
    if changed[node_id] then
      table.insert(ordered, node_id)
    end
  end
  return ordered
end

return M

-- ACP notifications must feed the existing rich transcript model unchanged.
local adapter = require("phenix_client.transcript").new()
local model = require("phenix_nvim.transcript.model")
local function update(id, kind, fields)
  fields.sessionUpdate = kind
  assert(adapter:apply({ type = "session.updated", session_id = id, update = fields }))
end
update("s1", "user_message_chunk", {
  messageId = "run-1:user",
  content = { type = "text", text = "hello" },
})
update("s1", "tool_call", {
  toolCallId = "call-1", title = "echo", status = "pending",
})
update("s1", "tool_call_update", {
  toolCallId = "call-1", status = "completed",
  content = { { type = "content", content = { type = "text", text = "HELLO" } } },
})
update("s1", "agent_message_chunk", {
  messageId = "run-1",
  content = { type = "text", text = "mock:" },
})
update("s1", "agent_message_chunk", {
  messageId = "run-1",
  content = { type = "text", text = "HELLO" },
})
local snapshot = adapter:session("s1")
assert(snapshot.session.session_id == "s1")
assert(snapshot.through_sequence == #snapshot.updates)
local projection, err = model.rebuild(snapshot)
assert(projection and not err, tostring(err))
local nodes = {}
for _, key in ipairs(projection.order) do
  nodes[#nodes + 1] = projection.nodes[key]
end
assert(nodes[1].kind == "message" and nodes[1].role == "user")
assert(nodes[1].text == "hello")
local has_tool, assistant = false, nil
for _, node in ipairs(nodes) do
  if node.kind == "tool" then
    assert(node.call_id == "call-1" and node.state == "completed")
    has_tool = true
  elseif node.kind == "message" and node.role == "assistant" then
    assistant = node
  end
end
assert(has_tool)
assert(assistant and assistant.text == "mock:HELLO")
update("s2", "user_message_chunk", {
  messageId = "run-1:user",
  content = { type = "text", text = "separate" },
})
assert(adapter:session("s1").through_sequence == 5)
assert(adapter:session("s2").through_sequence == 1)
local snapshot2 = adapter:session("s2")
assert(model.rebuild(snapshot2) ~= nil)
assert(not adapter:apply({ type = "session.updated", session_id = "s1",
  update = { sessionUpdate = "unknown", content = {type = "text", text="x"} } }))
assert(adapter:session("s1").through_sequence == 5)
print("P1 ACP notifications project into existing rich transcript model")

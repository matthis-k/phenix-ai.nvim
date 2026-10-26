-- Real P1 product gate through the Lua client SDK. No fake backend here.
local client_api = require("phenix_client")
local acp = require("phenix_client.acp")
local transcript = require("phenix_client.transcript")
local renderer = require("phenix_nvim.transcript.model")
local binary = assert(vim.env.PHENIX_P1_BIN, "PHENIX_P1_BIN required")
local function until_true(predicate, title)
  assert(vim.wait(30000, predicate, 15), "timed out: " .. title)
end
local function new_client()
  local client = client_api.new(acp.new({ command = binary }))
  local updates = {}
  local projected = transcript.new()
  client:on("session.updated", function(event)
    updates[#updates + 1] = event
    projected:apply(event)
  end)
  local ready, err
  client:start(function(v, e) ready, err = v, e end)
  until_true(function() return ready ~= nil or err ~= nil end, "initialize")
  assert(ready and not err)
  assert(ready.management.models == false, "P1 must not claim model selection capability")
  return client, updates, projected
end

local first, updates, projected = new_client()
local id, err
first:new_session(function(v, e) id, err = v and v.session_id, e end)
until_true(function() return id ~= nil or err ~= nil end, "session/new")
assert(id and not err)

-- The catalogue is discovered from the actual composition via ACP's
-- session/new configOptions. This is not a Lua-maintained model list.
local catalog, catalog_error
first:list_models(id, function(value, e) catalog, catalog_error = value, e end)
until_true(function() return catalog ~= nil or catalog_error ~= nil end, "model catalog")
assert(not catalog_error and catalog.selected == "phenix.model.scripted", vim.inspect(catalog))
assert(#catalog.models == 1 and catalog.models[1].id == "phenix.model.scripted")
local denied
first:set_model(id, "uninstalled.provider", function(_, e) denied = e end)
assert(denied and denied.kind == "denied", "P1 must deny a model absent from the runtime catalog")
local unchanged
first:list_models(id, function(value, e)
  assert(not e)
  unchanged = value
end)
assert(unchanged and unchanged.selected == catalog.selected,
  "rejected selection must not mutate the authoritative catalog")

local function send(client, prompt)
  local response, failure
  client:send(id, prompt, function(v, e) response, failure = v, e end)
  until_true(function() return response ~= nil or failure ~= nil end, "session/prompt")
  assert(response and not failure and response.stop_reason == "end_turn")
end
send(first, "hello")
send(first, "tools:hello")
until_true(function()
  local output = vim.inspect(updates)
  return output:find("mock:hello", 1, true)
    and output:find("mock:call-1:HELLO|call-2:5", 1, true)
end, "P1 model and tool updates")
local rendered = assert(renderer.rebuild(assert(projected:session(id))))
local user_count, assistant_count, tool_count = 0, 0, 0
for _, key in ipairs(rendered.order) do
  local node = rendered.nodes[key]
  if node.kind == "message" and node.role == "user" then
    user_count = user_count + 1
  elseif node.kind == "message" and node.role == "assistant" then
    assistant_count = assistant_count + 1
  elseif node.kind == "tool" then
    tool_count = tool_count + 1
  end
end
assert(user_count == 2 and assistant_count >= 1 and tool_count == 2,
  "P1 must feed the existing rich transcript, including user prompts")
local content_response, content_error
first:send_content(id, {
  { type = "text", text = "reference" },
  { type = "resource_link", name = "notes", uri = "file:///tmp/notes.md" },
}, function(value, err)
  content_response, content_error = value, err
end)
until_true(function() return content_response ~= nil or content_error ~= nil end,
  "structured prompt")
assert(content_response and not content_error
  and content_response.stop_reason == "end_turn")
assert(vim.inspect(updates):find(
  "Resource link: notes (file:///tmp/notes.md)", 1, true),
  "resource link must reach the runtime, not be interpreted by Neovim")
first:close()

local restored, replay, replay_projection = new_client()
local loaded, load_error
restored:load_session(id, function(value, e) loaded, load_error = value, e end)
until_true(function() return loaded ~= nil or load_error ~= nil end, "session/load")
assert(loaded and not load_error)
local reloaded
restored:list_models(id, function(value, e)
  assert(not e)
  reloaded = value
end)
assert(reloaded and reloaded.selected == catalog.selected,
  "reloaded model state must come from Phenix")
until_true(function()
  return vim.inspect(replay):find("mock:hello", 1, true) ~= nil
end, "journal replay")
local projection = assert(renderer.rebuild(assert(replay_projection:session(id))))
local replayed_user = 0
for _, key in ipairs(projection.order) do
  local node = projection.nodes[key]
  if node.role == "user" then replayed_user = replayed_user + 1 end
end
assert(replayed_user == 3, "durable P1 replay must reconstruct input transcript")
restored:close()
print("P1 Lua client SDK product acceptance passed")

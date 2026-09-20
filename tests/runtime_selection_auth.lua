local frontend = require("phenix_nvim")
local runtime = require("phenix_nvim.runtime")

frontend.setup({ auto_connect = false })

local connected = false
local connection_error = nil
frontend.connect(function(_, err)
  connection_error = err
  connected = true
end)
assert(vim.wait(10000, function()
  return connected
end, 10), "packaged Phenix connection timed out")
assert(connection_error == nil, vim.inspect(connection_error))

frontend.new_session()
assert(vim.wait(10000, function()
  return runtime.active_session() ~= nil
end, 10), "packaged Phenix session creation timed out")

local selections = nil
local selection_error = nil
runtime.list_selections(function(result, err)
  selections = result
  selection_error = err
end)
assert(vim.wait(10000, function()
  return selections ~= nil or selection_error ~= nil
end, 10), "routing selection discovery timed out")
assert(selection_error == nil, vim.inspect(selection_error))
assert(type(selections.available) == "table" and #selections.available > 0, "no routing selections exposed")
assert(
  selections.selected == "router.chatgpt-plus",
  "new Neovim sessions must prefer ChatGPT OAuth when no API-key environment is configured"
)

local function presentation_kind(item)
  local presentation = item.presentation
  if type(presentation) == "table" then
    return string.lower(tostring(presentation.kind or ""))
  end
  return string.lower(tostring(presentation or ""))
end

local codex_model = nil
local api_model = nil
local router = nil
for _, item in ipairs(selections.available) do
  local kind = presentation_kind(item)
  if kind == "model" and type(item.description) == "string" then
    if item.description:find("openai%-codex", 1, false) and codex_model == nil then
      codex_model = item
    elseif item.description:find("openai%-api", 1, false) and api_model == nil then
      api_model = item
    end
  elseif kind == "router" and router == nil then
    router = item
  end
end
assert(codex_model ~= nil, "packaged runtime must expose an OpenAI Codex fixed model route")
assert(api_model ~= nil, "packaged runtime must expose an OpenAI API fixed model route")
assert(router ~= nil, "packaged runtime must expose at least one router")

local function select_route(selection_id)
  local selected = nil
  local select_error = nil
  runtime.select(selection_id, function(result, err)
    selected = result
    select_error = err
  end)
  assert(vim.wait(10000, function()
    return selected ~= nil or select_error ~= nil
  end, 10), "routing selection update timed out")
  assert(select_error == nil, vim.inspect(select_error))
  assert(selected.selected == selection_id, "selection response did not retain selected route")
end

local function current_selection()
  local refreshed = nil
  local refresh_error = nil
  runtime.list_selections(function(result, err)
    refreshed = result
    refresh_error = err
  end)
  assert(vim.wait(10000, function()
    return refreshed ~= nil or refresh_error ~= nil
  end, 10), "routing selection refresh timed out")
  assert(refresh_error == nil, vim.inspect(refresh_error))
  return refreshed.selected
end

local function reconnect_and_resume(session_id)
  frontend.disconnect()

  local reconnected = false
  local reconnect_error = nil
  frontend.connect(function(_, err)
    reconnect_error = err
    reconnected = true
  end)
  assert(vim.wait(10000, function()
    return reconnected
  end, 10), "packaged Phenix reconnect timed out")
  assert(reconnect_error == nil, vim.inspect(reconnect_error))

  local resumed = nil
  local resume_error = nil
  runtime.resume_session(session_id, function(result, err)
    resumed = result
    resume_error = err
  end)
  assert(vim.wait(10000, function()
    return resumed ~= nil or resume_error ~= nil
  end, 10), "packaged Phenix resume timed out")
  assert(resume_error == nil, vim.inspect(resume_error))
end

local session_id = assert(runtime.active_session(), "active session disappeared")

select_route(codex_model.id)
assert(current_selection() == codex_model.id, "compatible fixed model selection was not persisted")
reconnect_and_resume(session_id)
assert(
  current_selection() == codex_model.id,
  "compatible OpenAI Codex fixed model must survive resume"
)

select_route(api_model.id)
assert(current_selection() == api_model.id, "incompatible fixed model setup failed")
reconnect_and_resume(session_id)
assert(
  current_selection() == "router.chatgpt-plus",
  "resumed OpenAI API fixed model must migrate to the ChatGPT OAuth route when no API key is configured"
)

local methods = nil
local methods_error = nil
runtime.list_authentication_methods(function(result, err)
  methods = result
  methods_error = err
end)
assert(vim.wait(10000, function()
  return methods ~= nil or methods_error ~= nil
end, 10), "authentication discovery timed out")
assert(methods_error == nil, vim.inspect(methods_error))
assert(type(methods.methods) == "table", "authentication methods result is malformed")

local codex = nil
for _, method in ipairs(methods.methods) do
  if method.name == "OpenAI Codex (ChatGPT OAuth)" then
    codex = method
    break
  end
end
assert(codex ~= nil, "packaged runtime did not expose OpenAI Codex OAuth")

local auth = nil
local auth_error = nil
runtime.authenticate(codex.id, function(result, err)
  auth = result
  auth_error = err
end)
assert(vim.wait(10000, function()
  return auth ~= nil or auth_error ~= nil
end, 10), "authentication start timed out")
assert(auth_error == nil, vim.inspect(auth_error))
local auth_kind = string.lower(tostring(auth.kind or ""))
assert(auth_kind == "external" or auth_kind == "authenticated", "unexpected authentication state: " .. vim.inspect(auth))
if auth_kind == "external" then
  assert(type(auth.uri) == "string" and auth.uri:match("^https://"), "OAuth did not return an HTTPS authorization URI")

  local polled = nil
  local poll_error = nil
  runtime.authenticate(codex.id, function(result, err)
    polled = result
    poll_error = err
  end)
  assert(vim.wait(10000, function()
    return polled ~= nil or poll_error ~= nil
  end, 10), "authentication poll timed out")
  assert(poll_error == nil, vim.inspect(poll_error))
  assert(string.lower(tostring(polled.kind or "")) == "external", "pending OAuth flow was not preserved")
  assert(polled.uri == auth.uri, "authentication polling started a different OAuth flow")
end

frontend.disconnect()

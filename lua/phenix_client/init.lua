-- Phenix Lua client API. Transport and authority live outside Neovim UI code.
-- A backend forwards these calls to operations exposed by the Phenix runtime.
local M = {}
local Client = {}
Client.__index = Client

local operations = {
  -- Read-only ACP extension feature probe. A host without this extension
  -- returns Method not found; no frontend capability or grant is invented.
  list_providers = { name = "providers.list" },
  get_provider_auth_status = { name = "providers.auth.status" },
  begin_provider_auth = { name = "providers.auth.begin" },
  poll_provider_auth = { name = "providers.auth.poll" },
  cancel_provider_auth = { name = "providers.auth.cancel" },
  get_provider_models = { name = "providers.models" },
  credential_capabilities = { name = "credentials.capabilities" },
  import_credential = { name = "credentials.import" },
  bind_credential_environment = { name = "credentials.bind_environment" },
  revoke_credential = { name = "credentials.revoke" },
  list_models = { name = "models.list" },
  set_model = { name = "models.select" },
  new_session = { permission = { "session_operations", "new" }, name = "sessions.new" },
  load_session = { permission = { "session_operations", "load" }, name = "sessions.load" },
  send = { permission = { "session_operations", "send" }, name = "sessions.send" },
  cancel = { permission = { "session_operations", "cancel" }, name = "sessions.cancel" },
}

local function finish(callback, value, err)
  if callback then callback(value, err) end
end

local function unsupported(operation)
  return { kind = "unsupported", message = "Phenix does not expose " .. operation }
end

function M.new(backend)
  assert(type(backend) == "table" and type(backend.call) == "function")
  assert(type(backend.start) == "function")
  assert(type(backend.subscribe) == "function")
  assert(type(backend.close) == "function")
  return setmetatable({
    backend = backend,
    available = nil,
    connected = false,
    listeners = {},
    stop_subscription = nil,
    pending = {},
    closed = false,
  }, Client)
end

-- Track a callback until the operation settles or the client generation retires.
-- A failed transport and an explicit close both settle every callback once.
function Client:_await(callback)
  if not callback then return function() end end
  local record = { callback = callback }
  self.pending[record] = true
  return function(value, err)
    if not self.pending[record] then return end
    self.pending[record] = nil
    finish(callback, value, err)
  end
end

function Client:_abort(error)
  local pending = self.pending
  self.pending = {}
  for record in pairs(pending) do
    finish(record.callback, nil, error)
  end
end

function Client:_publish(event)
  if self.closed or type(event) ~= "table" then return end
  if event.type == "connection.failed" then
    self.connected = false
    self.available = nil
    self:_abort(event.error or { kind = "transport", message = "Phenix connection failed" })
  end
  local listeners = self.listeners[event.type]
  if not listeners or #listeners == 0 then
    if event.type == "permission.requested" then
      -- No UI is available: cancel rather than silently approving a tool.
      self.backend:call("permissions.respond",
        { request_id = event.request_id }, function() end)
    end
    return
  end
  local copy = {}
  for _, fn in ipairs(listeners) do copy[#copy + 1] = fn end
  local crashed = false
  for _, fn in ipairs(copy) do
    local ok, err = pcall(fn, event)
    if not ok then
      crashed = true
      vim.schedule(function()
        vim.notify("Phenix event handler failed: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
  if crashed and event.type == "permission.requested" then
    -- A malfunctioning frontend must never leave an approval pending.
    self.backend:call("permissions.respond",
      { request_id = event.request_id }, function() end)
  end
end

function Client:on(kind, listener)
  assert(type(kind) == "string" and kind ~= "")
  assert(type(listener) == "function")
  self.listeners[kind] = self.listeners[kind] or {}
  local listeners = self.listeners[kind]
  listeners[#listeners + 1] = listener
  return function()
    for i, fn in ipairs(listeners) do
      if fn == listener then table.remove(listeners, i); break end
    end
  end
end

function Client:start(callback)
  if self.closed then
    finish(callback, nil, { kind = "disconnected", message = "client closed" })
    return
  end
  if self.connected then
    finish(callback, self:capabilities(), nil)
    return
  end
  local complete = self:_await(callback)
  self.backend:start(function(features, err)
    if self.closed then return end
    if err then
      complete(nil, err)
      return
    end
    -- Capabilities are advertised by the runtime, not invented by this SDK.
    self.available = features or {}
    self.connected = true
    if not self.stop_subscription then
      self.stop_subscription = self.backend:subscribe(function(event)
        self:_publish(event)
      end)
    end
    complete(self:capabilities(), nil)
  end)
end

function Client:capabilities()
  if not self.connected then return nil end
  return self.available
end

function Client:_call(key, args, callback)
  if not self.connected or self.closed then
    finish(callback, nil, { kind = "disconnected", message = "Phenix is not connected" })
    return
  end
  local op = operations[key]
  local permission = op.permission
  if permission then
    local group = self.available[permission[1]] or {}
    if group[permission[2]] ~= true then
      finish(callback, nil, unsupported(op.name))
      return
    end
  end
  -- The backend forwards requests under its established Phenix client scope.
  -- Phenix must recheck authorization on every call. Discovery is not a grant.
  local complete = self:_await(callback)
  self.backend:call(op.name, args, function(value, err)
    if self.closed then return end
    complete(value, err)
  end)
end

function Client:list_providers(callback)
  assert(callback == nil or type(callback) == "function")
  self:_call("list_providers", {}, callback)
end

-- Provider status and model discovery are read-only plugin-owned queries.
-- These do not imply entitlement, introduce a selected account or mutate
-- the ACP session's effective model.
function Client:get_provider_auth_status(provider_id, connection_id, callback)
  assert(type(provider_id) == "string" and provider_id ~= "")
  assert(type(connection_id) == "string" and connection_id ~= "")
  assert(callback == nil or type(callback) == "function")
  self:_call("get_provider_auth_status", {
    provider_id = provider_id, connection_id = connection_id,
  }, callback)
end

-- The provider plugin owns these attempts. This client cannot create
-- authenticated profiles or accept an API key by treating presence as proof.
function Client:begin_provider_auth(provider_id, connection_id, method_id, callback)
  assert(type(provider_id) == "string" and provider_id ~= "")
  assert(type(connection_id) == "string" and connection_id ~= "")
  assert(type(method_id) == "string" and method_id ~= "")
  self:_call("begin_provider_auth", {
    provider_id = provider_id, connection_id = connection_id, method_id = method_id,
  }, callback)
end

function Client:poll_provider_auth(provider_id, connection_id, attempt_id, callback)
  assert(type(provider_id) == "string" and provider_id ~= "")
  assert(type(connection_id) == "string" and connection_id ~= "")
  assert(type(attempt_id) == "string" and attempt_id ~= "")
  self:_call("poll_provider_auth", {
    provider_id = provider_id, connection_id = connection_id, attempt_id = attempt_id,
  }, callback)
end

function Client:cancel_provider_auth(provider_id, connection_id, attempt_id, callback)
  assert(type(provider_id) == "string" and provider_id ~= "")
  assert(type(connection_id) == "string" and connection_id ~= "")
  assert(type(attempt_id) == "string" and attempt_id ~= "")
  self:_call("cancel_provider_auth", {
    provider_id = provider_id, connection_id = connection_id, attempt_id = attempt_id,
  }, callback)
end

function Client:get_provider_models(provider_id, connection_id, options, callback)
  assert(type(provider_id) == "string" and provider_id ~= "")
  assert(type(connection_id) == "string" and connection_id ~= "")
  if type(options) == "function" then callback, options = options, nil end
  options = options or {}
  assert(type(options) == "table")
  assert(callback == nil or type(callback) == "function")
  local limit = options.limit or 64
  assert(type(limit) == "number" and limit >= 1 and limit <= 256
    and limit % 1 == 0)
  assert(options.profile_id == nil or
    (type(options.profile_id) == "string" and options.profile_id ~= ""))
  assert(options.cursor == nil or type(options.cursor) == "string")
  self:_call("get_provider_models", {
    provider_id = provider_id, connection_id = connection_id,
    profile_id = options.profile_id, cursor = options.cursor,
    limit = limit,
  }, callback)
end

-- Credentials are never saved in Lua state or a client-side provider catalog.
-- A successful import means stored, not authenticated; the provider plugin
-- must independently establish valid authentication before model selection.
function Client:credential_capabilities(callback)
  assert(callback == nil or type(callback) == "function")
  self:_call("credential_capabilities", {}, callback)
end

function Client:import_credential(provider_id, connection_id, profile_id, secret, callback)
  for _, id in ipairs({ provider_id, connection_id, profile_id }) do
    assert(type(id) == "string" and id ~= "")
  end
  assert(type(secret) == "string" and secret ~= "")
  assert(callback == nil or type(callback) == "function")
  self:_call("import_credential", {
    provider_id = provider_id, connection_id = connection_id,
    profile_id = profile_id, secret = secret,
  }, callback)
end

function Client:bind_credential_environment(provider_id, connection_id, profile_id, name, callback)
  for _, id in ipairs({ provider_id, connection_id, profile_id }) do
    assert(type(id) == "string" and id ~= "")
  end
  assert(type(name) == "string" and name ~= "")
  assert(callback == nil or type(callback) == "function")
  self:_call("bind_credential_environment", {
    provider_id = provider_id, connection_id = connection_id,
    profile_id = profile_id, environment_variable = name,
  }, callback)
end

function Client:revoke_credential(provider_id, connection_id, profile_id, callback)
  for _, id in ipairs({ provider_id, connection_id, profile_id }) do
    assert(type(id) == "string" and id ~= "")
  end
  assert(callback == nil or type(callback) == "function")
  self:_call("revoke_credential", {
    provider_id = provider_id, connection_id = connection_id,
    profile_id = profile_id,
  }, callback)
end

function Client:list_models(session_or_callback, callback)
  local session_id
  if type(session_or_callback) == "function" then
    callback = session_or_callback
  else
    session_id = session_or_callback
    assert(session_id == nil or (type(session_id) == "string" and session_id ~= ""))
  end
  self:_call("list_models", { session_id = session_id }, callback)
end

-- Supply the session explicitly when multiple ACP sessions coexist. The
-- historical (model, callback) form remains safe only with one catalog.
function Client:set_model(session_or_model, model_or_callback, callback)
  local session_id, model_id
  if model_or_callback == nil or type(model_or_callback) == "function" then
    model_id, callback = session_or_model, model_or_callback
  else
    -- Explicit (nil, model, callback) is a pre-session default selection.
    -- An existing session ID instead selects a session-local override.
    session_id, model_id = session_or_model, model_or_callback
    assert(session_id == nil or (type(session_id) == "string" and session_id ~= ""))
  end
  assert(type(model_id) == "string" and model_id ~= "")
  self:_call("set_model", { session_id = session_id, model_id = model_id }, callback)
end

function Client:new_session(callback)
  self:_call("new_session", {}, callback)
end

function Client:load_session(id, callback)
  assert(type(id) == "string" and id ~= "")
  self:_call("load_session", { session_id = id }, callback)
end

function Client:send(session_id, text, callback)
  assert(type(session_id) == "string" and session_id ~= "")
  assert(type(text) == "string" and text ~= "")
  self:_call("send", { session_id = session_id, text = text }, callback)
end

-- Forward ACP-compatible user content under Phenix's prompt action.
-- The frontend may attach data but never evaluates tools or reads URI targets.
function Client:send_content(session_id, content, callback)
  assert(type(session_id) == "string" and session_id ~= "")
  assert(type(content) == "table" and #content > 0)
  for _, item in ipairs(content) do
    assert(type(item) == "table")
    if item.type == "text" then
      assert(type(item.text) == "string" and item.text ~= "")
    elseif item.type == "resource_link" then
      assert(type(item.uri) == "string" and item.uri ~= "")
      assert(type(item.name) == "string" and item.name ~= "")
    else
      error("P1 input supports only ACP text and resource_link blocks")
    end
  end
  self:_call("send", { session_id = session_id, content = content }, callback)
end

-- Respond to Phenix's request, never grant an independent Lua permission.
-- The ACP transport validates the option against Phenix's exact offer.
function Client:respond_permission(request_id, option_id, callback)
  assert(type(request_id) == "number" or type(request_id) == "string")
  assert(option_id == nil or (type(option_id) == "string" and option_id ~= ""))
  if not self.connected or self.closed then
    finish(callback, nil, { kind = "disconnected", message = "Phenix is not connected" })
    return
  end
  local complete = self:_await(callback)
  self.backend:call("permissions.respond", {
    request_id = request_id, option_id = option_id,
  }, function(value, err)
    if self.closed then return end
    complete(value, err)
  end)
end

function Client:cancel(session_id, callback)
  assert(type(session_id) == "string" and session_id ~= "")
  self:_call("cancel", { session_id = session_id }, callback)
end

function Client:close()
  if self.closed then return end
  self.closed = true
  self.connected = false
  self.available = nil
  self:_abort({ kind = "disconnected", message = "Phenix client closed" })
  if self.stop_subscription then self.stop_subscription() end
  self.stop_subscription = nil
  self.listeners = {}
  self.backend:close()
end

return M

-- ACP v1 transport for the non-plugin Lua client SDK.
-- ACP session config options remain the runtime-authoritative model surface.
local M = {}
local Backend = {}
Backend.__index = Backend

local function error_value(message, kind)
  return { kind = kind or "transport", message = tostring(message) }
end
local function finish(callback, value, err)
  if callback then callback(value, err) end
end

function M.new(options)
  options = options or {}
  local command = options.command or "phenix-basic-acp"
  assert(type(command) == "string" and command ~= "")
  return setmetatable({
    command = command, args = options.args or {},
    cwd = options.cwd or vim.fn.getcwd(),
    job = nil, next_id = 0, requests = {}, waiting = {},
    subscribers = {}, partial = "", stderr = "",
    state = "idle", features = nil, catalogs = {}, active_session = nil,
    permission_requests = {},
  }, Backend)
end

function Backend:_fail(reason)
  if self.state == "closed" or self.state == "failed" then return end
  self.state = "failed"
  local requests, waiting = self.requests, self.waiting
  self.requests, self.waiting = {}, {}
  self.permission_requests = {}
  for _, callback in pairs(requests) do finish(callback, nil, reason) end
  for _, callback in ipairs(waiting) do finish(callback, nil, reason) end
  local listeners = {}
  for _, callback in ipairs(self.subscribers) do listeners[#listeners + 1] = callback end
  for _, callback in ipairs(listeners) do
    callback({ type = "connection.failed", error = reason })
  end
end

function Backend:_write(message)
  if not self.job then return false, error_value("ACP process is not running") end
  local ok, bytes = pcall(vim.fn.chansend, self.job, vim.json.encode(message) .. "\n")
  if not ok or type(bytes) ~= "number" or bytes <= 0 then
    return false, error_value(ok and "ACP write failed" or bytes)
  end
  return true
end

function Backend:_request(method, params, callback)
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.requests[id] = callback or function() end
  local ok, err = self:_write({
    jsonrpc = "2.0", id = id, method = method, params = params,
  })
  if not ok then
    self.requests[id] = nil
    finish(callback, nil, err)
    self:_fail(err)
  end
end

function Backend:_response(frame)
  if type(frame) ~= "table" or frame.jsonrpc ~= "2.0" then
    self:_fail(error_value("invalid JSON-RPC envelope", "protocol"))
    return
  end
  if frame.method == "session/update" then
    local params = frame.params or {}
    if type(params.sessionId) == "string" and type(params.update) == "table" then
      local listeners = {}
      for _, callback in ipairs(self.subscribers) do listeners[#listeners + 1] = callback end
      for _, callback in ipairs(listeners) do
        callback({
          type = "session.updated", session_id = params.sessionId,
          update = params.update,
        })
      end
    end
    return
  end
  if frame.method == "session/request_permission" and frame.id ~= nil then
    local request = frame.params or {}
    if type(request.sessionId) ~= "string"
      or type(request.toolCall) ~= "table"
      or type(request.options) ~= "table"
    then
      self:_write({ jsonrpc = "2.0", id = frame.id,
        error = { code = -32602, message = "Invalid ACP permission request" } })
      return
    end
    self.permission_requests[frame.id] = {
      session_id = request.sessionId,
      options = request.options,
    }
    local event = {
      type = "permission.requested",
      request_id = frame.id, session_id = request.sessionId,
      tool_call = request.toolCall, options = request.options,
    }
    local listeners = {}
    for _, listener in ipairs(self.subscribers) do listeners[#listeners + 1] = listener end
    if #listeners == 0 then
      self:_permission_response(frame.id, nil)
    else
      for _, listener in ipairs(listeners) do listener(event) end
    end
    return
  end
  if frame.method ~= nil then
    if frame.id ~= nil then
      self:_write({
        jsonrpc = "2.0", id = frame.id,
        error = { code = -32601, message = "Unsupported ACP client method" },
      })
    end
    return
  end
  local callback = self.requests[frame.id]
  if callback then
    self.requests[frame.id] = nil
    if frame.error then
      finish(callback, nil, {
        kind = "remote", message = frame.error.message or "Phenix request failed",
        code = frame.error.code, data = frame.error.data,
      })
    else
      finish(callback, frame.result, nil)
    end
  end
end

function Backend:_stdout(chunks)
  if self.state == "closed" or self.state == "failed" or #chunks == 0 then return end
  local current = self.partial .. chunks[1]
  for index = 2, #chunks do
    if current ~= "" then
      local ok, frame = pcall(vim.json.decode, current)
      if not ok then
        self:_fail(error_value("Phenix emitted invalid JSON", "protocol"))
        return
      end
      self:_response(frame)
      if self.state == "failed" then return end
    end
    current = chunks[index]
  end
  self.partial = current
end

function Backend:start(callback)
  if self.state == "ready" then finish(callback, self.features, nil); return end
  if self.state == "closed" or self.state == "failed" then
    finish(callback, nil, error_value("start a new client to reconnect"))
    return
  end
  if callback then self.waiting[#self.waiting + 1] = callback end
  if self.state == "starting" then return end
  self.state = "starting"
  local argv = { self.command }
  for _, arg in ipairs(self.args) do argv[#argv + 1] = arg end
  local options = {
    cwd = self.cwd,
    on_stdout = function(_, data) self:_stdout(data) end,
    on_stderr = function(_, data)
      self.stderr = (self.stderr .. table.concat(data, "\n")):sub(-2048)
    end,
    on_exit = function(_, code)
      self:_fail(error_value("Phenix ACP exited (" .. tostring(code) .. "): " .. self.stderr))
    end,
  }
  -- Neovim may throw (e.g. E475 for a non-executable command) rather
  -- than returning a negative job ID. Surface both failures through the
  -- transport callbacks so an explicit reconnect can replace this client.
  local started, job = pcall(vim.fn.jobstart, argv, options)
  if not started or type(job) ~= "number" or job <= 0 then
    local detail = not started and (": " .. tostring(job)) or ""
    self:_fail(error_value("cannot start " .. self.command .. detail))
    return
  end
  self.job = job
  self:_request("initialize", {
    protocolVersion = 1, clientCapabilities = vim.empty_dict(),
  }, function(value, err)
    if err then self:_fail(err); return end
    if not value or value.protocolVersion ~= 1 then
      self:_fail(error_value("Phenix did not negotiate ACP v1", "protocol"))
      return
    end
    local caps = value.agentCapabilities or {}
    self.features = {
      session_operations = {
        new = true,
        load = caps.loadSession == true,
        send = true,
        cancel = true,
      },
      -- Runtime control operations are not yet published by the P1 ACP host.
      management = { models = false, model_selection = false },
    }
    self.state = "ready"
    local waiting = self.waiting
    self.waiting = {}
    for _, waiter in ipairs(waiting) do finish(waiter, self.features, nil) end
  end)
end

-- Treat ACP session config options as runtime-returned state, never as
-- frontend configuration. A catalog is scoped to the session which sent it.
function Backend:_catalog(session_id, options)
  local catalog = nil
  for _, option in ipairs(options or {}) do
    if option.id == "model" and option.category == "model"
      and option.type == "select" and type(option.options) == "table"
      and type(option.currentValue) == "string"
    then
      local models = {}
      for _, entry in ipairs(option.options) do
        if type(entry.value) == "string" and entry.value ~= ""
          and type(entry.name) == "string"
        then
          models[#models + 1] = {
            id = entry.value, name = entry.name, authorized = true,
          }
        end
      end
      if #models > 0 then
        catalog = {
          session_id = session_id,
          selected = option.currentValue,
          models = models,
        }
      end
      break
    end
  end
  if catalog then
    self.catalogs[session_id] = catalog
  else
    self.catalogs[session_id] = nil
  end
  self.active_session = session_id
  -- Capability discovery describes the connected client as a whole.
  -- One session without a catalog cannot suppress another session's
  -- still-authoritative runtime-advertised model choices.
  self.features.management.models = next(self.catalogs) ~= nil
  self.features.management.model_selection = next(self.catalogs) ~= nil
  if catalog then
    local listeners = {}
    for _, subscriber in ipairs(self.subscribers) do
      listeners[#listeners + 1] = subscriber
    end
    for _, subscriber in ipairs(listeners) do
      subscriber({ type = "models.changed", session_id = session_id,
        catalog = vim.deepcopy(catalog) })
    end
  end
end

-- Only a choice supplied in this exact runtime request is selectable.
-- The Lua frontend never issues authorization; it returns the user's choice.
function Backend:_permission_response(request_id, option_id, callback)
  local pending = self.permission_requests[request_id]
  if not pending then
    finish(callback, nil, error_value("Unknown permission request", "not_found"))
    return
  end
  if option_id ~= nil then
    local allowed = false
    for _, option in ipairs(pending.options) do
      if option.optionId == option_id then allowed = true; break end
    end
    if not allowed then
      finish(callback, nil, error_value("Option was not offered by Phenix", "denied"))
      return
    end
  end
  local outcome = option_id and { outcome = "selected", optionId = option_id }
    or { outcome = "cancelled" }
  local ok, err = self:_write({
    jsonrpc = "2.0", id = request_id, result = { outcome = outcome },
  })
  if ok then self.permission_requests[request_id] = nil end
  finish(callback, ok and true or nil, err)
end

function Backend:call(op, args, callback)
  if self.state ~= "ready" then
    finish(callback, nil, error_value("ACP is not initialized"))
    return
  end
  args = args or {}
  if op == "permissions.respond" then
    self:_permission_response(args.request_id, args.option_id, callback)
  elseif op == "models.list" then
    local id = args.session_id or self.active_session
    local catalog = id and self.catalogs[id]
    if catalog then
      finish(callback, vim.deepcopy(catalog), nil)
    else
      finish(callback, nil, error_value("Model catalog not available for session", "unsupported"))
    end
  elseif op == "models.select" then
    local id = args.session_id or self.active_session
    local catalog = id and self.catalogs[id]
    if type(args.model_id) ~= "string" or not catalog then
      finish(callback, nil, error_value("No selected ACP session", "unsupported"))
      return
    end
    local admitted = false
    for _, model in ipairs(catalog.models) do
      if model.id == args.model_id then admitted = true; break end
    end
    if not admitted then
      finish(callback, nil, error_value("Model was not offered by Phenix", "denied"))
      return
    end
    self:_request("session/set_config_option", {
      sessionId = id, configId = "model", value = args.model_id,
    }, function(value, err)
      if err then finish(callback, nil, err); return end
      if type(value) ~= "table" or type(value.configOptions) ~= "table" then
        finish(callback, nil, error_value("ACP model change omitted confirmed state", "protocol"))
        return
      end
      self:_catalog(id, value.configOptions)
      local updated = self.catalogs[id]
      if not updated or updated.selected ~= args.model_id then
        finish(callback, nil, error_value("Runtime did not confirm selected model", "protocol"))
        return
      end
      finish(callback, { selected = updated.selected }, nil)
    end)
  elseif op == "sessions.new" then
    self:_request("session/new", { cwd = self.cwd, mcpServers = {} },
      function(value, err)
        if value and type(value.sessionId) == "string" then
          self:_catalog(value.sessionId, value.configOptions)
        end
        finish(callback, value and { session_id = value.sessionId } or nil, err)
      end)
  elseif op == "sessions.load" then
    self:_request("session/load", {
      cwd = self.cwd, sessionId = args.session_id, mcpServers = {},
    }, function(value, err)
      if value then
        self:_catalog(args.session_id, value.configOptions)
      end
      finish(callback, value and { session_id = args.session_id } or nil, err)
    end)
  elseif op == "sessions.send" then
    self:_request("session/prompt", {
      sessionId = args.session_id,
      prompt = args.content or { { type = "text", text = args.text } },
    }, function(value, err)
      finish(callback, value and { stop_reason = value.stopReason } or nil, err)
    end)
  elseif op == "sessions.cancel" then
    for id, pending in pairs(self.permission_requests) do
      if pending.session_id == args.session_id then
        self:_permission_response(id, nil)
      end
    end
    local ok, err = self:_write({
      jsonrpc = "2.0", method = "session/cancel",
      params = { sessionId = args.session_id },
    })
    finish(callback, ok and true or nil, err)
  else
    finish(callback, nil, error_value("Phenix does not expose " .. op, "unsupported"))
  end
end

function Backend:subscribe(callback)
  self.subscribers[#self.subscribers + 1] = callback
  return function()
    for i, existing in ipairs(self.subscribers) do
      if existing == callback then table.remove(self.subscribers, i); break end
    end
  end
end

function Backend:close()
  if self.state == "closed" then return end
  if self.state == "ready" then
    for id in pairs(self.permission_requests) do
      self:_permission_response(id, nil)
    end
  end
  self:_fail(error_value("ACP connection closed"))
  local job = self.job
  self.job, self.state = nil, "closed"
  if job then pcall(vim.fn.jobstop, job) end
  self.subscribers = {}
end

return M

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

local function nullish(value)
  return value == nil or value == vim.NIL
end

function M.new(options)
  options = options or {}
  local command = options.command or "phenix-basic-acp"
  assert(type(command) == "string" and command ~= "")
  return setmetatable({
    command = command, args = options.args or {},
    cwd = options.cwd or vim.fn.getcwd(),
    job = nil, next_id = 0, requests = {}, waiting = {},
    subscribers = {}, partial = "",
    state = "idle", features = nil, catalogs = {}, catalog_versions = {}, active_session = nil,
    permission_requests = {},
  }, Backend)
end

-- A successful runtime CAS rotates its model option IDs from revision N
-- to N+1. A response is confirmed only when every non-secret identity field
-- is identical AND the revision increments exactly once. The frontend does
-- not issue model authority, decode secrets or forge option IDs.
local function acknowledged_native_model_choice(requested, confirmed)
  local prefix = "phenix.native-model@1:"
  if type(requested) ~= "string" or type(confirmed) ~= "string"
    or requested:sub(1, #prefix) ~= prefix
    or confirmed:sub(1, #prefix) ~= prefix
  then
    return false
  end
  local ok1, from = pcall(vim.json.decode, requested:sub(#prefix + 1))
  local ok2, into = pcall(vim.json.decode, confirmed:sub(#prefix + 1))
  if not ok1 or not ok2 or type(from) ~= "table" or type(into) ~= "table" then
    return false
  end
  local revision = from.session_revision
  if type(revision) ~= "number" or revision < 0 or revision % 1 ~= 0
    or revision >= 9007199254740991
    or into.session_revision ~= revision + 1
  then
    return false
  end
  local keys = {
    "provider_id", "connection_id", "profile_id", "model_id",
    "protocol_id", "endpoint_id", "catalog_revision",
  }
  for _, key in ipairs(keys) do
    if from[key] ~= into[key] then return false end
  end
  -- No additional unrecognized identity attributes may be silently ignored.
  for key in pairs(from) do
    if key ~= "session_revision" and not vim.tbl_contains(keys, key) then return false end
  end
  for key in pairs(into) do
    if key ~= "session_revision" and not vim.tbl_contains(keys, key) then return false end
  end
  return true
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
      -- ACP config_option_update carries the complete authoritative option
      -- set. An empty set retracts the previous model catalog.
      if params.update.sessionUpdate == "config_option_update"
        and type(params.update.configOptions) == "table"
      then
        self:_catalog(params.sessionId, params.update.configOptions)
      end
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
      -- Remote error data can contain provider bodies and credentials.
      -- Only expose a bounded diagnostic and the known Basic error code.
      local message = frame.error.message
      if type(message) ~= "string" or #message == 0 or #message > 1024
        or message:find("[%c]")
      then
        message = "Phenix request failed"
      end
      local detail = frame.error.data
      -- JSON-RPC error.data is application-owned. Only a tagged BasicError
      -- with a canonical code can override the generic ACP message. Older
      -- runtimes are accepted through a small exact-prefix compatibility path.
      local basic_code
      local provider_code
      local provider_codes = {
        InvalidInput = true, Denied = true, NotFound = true,
        Unavailable = true, Conflict = true, AuthenticationRequired = true,
      }
      if type(detail) == "table" and detail.format == "phenix.provider.error.v1"
        and provider_codes[detail.code] == true
      then
        provider_code = detail.code
      end
      local basic_codes = {
        Conflict = true, Denied = true, Indeterminate = true,
        InvalidCursor = true, InvalidInput = true, InvalidReply = true,
        ModelFailed = true, NotFound = true, StorageFailed = true,
        ToolFailed = true, TurnLimit = true,
      }
      if type(detail) == "table"
        and detail.format == "phenix.basic.error.v1"
        and basic_codes[detail.code] == true
        and type(detail.message) == "string"
        and #detail.message > 0 and #detail.message <= 1024
        and not detail.message:find("[%c]")
      then
        basic_code = detail.code
        message = detail.message
      elseif type(detail) == "string" and #detail <= 1024
        and not detail:find("[%c]")
        and (detail:match("^PHENIX_BASIC_SQLITE_PATH ")
          or detail:match("^StorageFailed: SQLite ")
          or detail:match("^session already owned")
          or detail:match("^ModelFailed: HTTP model status 401$")
          or detail:match("^ModelFailed: HTTP model status 403$"))
      then
        message = detail
      end
      finish(callback, nil, {
        kind = "remote", message = message,
        code = frame.error.code, basic_code = basic_code,
        provider_code = provider_code,
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
    -- Stderr is not a trusted diagnostic channel. Providers may print
    -- credentials or response bodies there; never forward it to Lua UI
    -- callbacks. The exit code remains enough to report transport failure.
    on_stderr = function() end,
    on_exit = function(_, code)
      self:_fail(error_value("Phenix ACP exited (" .. tostring(code) .. ")"))
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
  local previous = self.catalogs[session_id]
  -- This is a local ordering counter, never a replacement for a runtime CAS
  -- revision. It prevents an older ACP reply from undoing newer notifications.
  self.catalog_versions[session_id] = (self.catalog_versions[session_id] or 0) + 1
  local catalog = nil
  local model_options = 0
  for _, option in ipairs(options or {}) do
    if type(option) == "table" and option.id == "model" then
      model_options = model_options + 1
      if model_options == 1 and option.category == "model"
        and option.type == "select" and type(option.options) == "table"
        and type(option.currentValue) == "string"
      then
        local models, seen, current_offered = {}, {}, false
        local invalid = false
        for _, entry in ipairs(option.options) do
          if type(entry) ~= "table" or type(entry.value) ~= "string"
            or entry.value == "" or type(entry.name) ~= "string"
            or seen[entry.value]
          then
            invalid = true
            break
          end
          seen[entry.value] = true
          models[#models + 1] = {
            id = entry.value, name = entry.name, authorized = true,
          }
          if entry.value == option.currentValue then current_offered = true end
        end
        if not invalid and #models > 0 and current_offered then
          catalog = {
            session_id = session_id,
            selected = option.currentValue,
            models = models,
          }
        end
      end
    end
  end
  -- A runtime-advertised choice must map to exactly one entry/option.
  -- Ambiguous duplicate IDs cannot be used as an authority shortcut.
  if model_options ~= 1 then catalog = nil end
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
  -- A missing or invalid runtime catalog revokes the previous projection.
  -- Observers must be told when choices disappear, not only when added.
  if catalog or previous then
    local listeners = {}
    for _, subscriber in ipairs(self.subscribers) do
      listeners[#listeners + 1] = subscriber
    end
    for _, subscriber in ipairs(listeners) do
      subscriber({ type = "models.changed", session_id = session_id,
        catalog = catalog and vim.deepcopy(catalog) or nil })
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
  elseif op == "providers.list" then
    -- ACP SDK extension, never an editor-side catalog or authority bypass.
    self:_request("_phenix/providers/list", { scope = "user" }, function(value, err)
      if err then
        if err.code == -32601 then
          finish(callback, nil, error_value(
            "Phenix does not expose provider discovery", "unsupported"))
        else
          finish(callback, nil, err)
        end
        return
      end
      if type(value) ~= "table" or type(value.revision) ~= "number"
        or type(value.providers) ~= "table"
      then
        finish(callback, nil, error_value("Invalid runtime provider catalog", "protocol"))
        return
      end
      for _, provider in ipairs(value.providers) do
        if type(provider) ~= "table" or type(provider.id) ~= "string"
          or type(provider.connections) ~= "table"
        then
          finish(callback, nil, error_value("Invalid runtime provider identity", "protocol"))
          return
        end
      end
      finish(callback, vim.deepcopy(value), nil)
    end)
  elseif op == "providers.auth.status" then
    if type(args.provider_id) ~= "string" or args.provider_id == ""
      or type(args.connection_id) ~= "string" or args.connection_id == ""
    then
      finish(callback, nil, error_value("Missing provider connection", "invalid_input"))
      return
    end
    self:_request("_phenix/providers/auth/status", {
      scope = "user", provider_id = args.provider_id,
      connection_id = args.connection_id,
    }, function(value, err)
      if err then
        if err.code == -32601 then
          finish(callback, nil, error_value(
            "Phenix does not expose provider authentication status", "unsupported"))
        else
          finish(callback, nil, err)
        end
        return
      end
      if type(value) ~= "table" or value.provider_id ~= args.provider_id
        or value.connection_id ~= args.connection_id
        or type(value.profiles) ~= "table"
      then
        finish(callback, nil, error_value("Invalid provider authentication status", "protocol"))
        return
      end
      local seen = {}
      for _, profile in ipairs(value.profiles) do
        if type(profile) ~= "table" or type(profile.id) ~= "string"
          or profile.id == "" or seen[profile.id]
          or type(profile.method_id) ~= "string" or profile.method_id == ""
          or type(profile.valid) ~= "boolean"
        then
          finish(callback, nil, error_value("Invalid provider profile identity", "protocol"))
          return
        end
        seen[profile.id] = true
      end
      finish(callback, vim.deepcopy(value), nil)
    end)
  elseif op == "providers.models" then
    if type(args.provider_id) ~= "string" or args.provider_id == ""
      or type(args.connection_id) ~= "string" or args.connection_id == ""
      or type(args.limit) ~= "number" or args.limit < 1
      or args.limit > 256 or args.limit % 1 ~= 0
    then
      finish(callback, nil, error_value("Invalid provider model query", "invalid_input"))
      return
    end
    self:_request("_phenix/providers/models", {
      scope = "user", provider_id = args.provider_id,
      connection_id = args.connection_id, profile_id = args.profile_id,
      cursor = args.cursor, limit = args.limit,
    }, function(value, err)
      if err then
        if err.code == -32601 then
          finish(callback, nil, error_value(
            "Phenix does not expose provider model discovery", "unsupported"))
        else
          finish(callback, nil, err)
        end
        return
      end
      if type(value) ~= "table" or type(value.models) ~= "table"
        or type(value.revision) ~= "number"
        or (args.profile_id == nil and not nullish(value.profile_id))
        or (args.profile_id ~= nil and value.profile_id ~= args.profile_id)
        or #value.models > args.limit
        or (not nullish(value.next_cursor) and type(value.next_cursor) ~= "string")
      then
        finish(callback, nil, error_value("Invalid provider model page", "protocol"))
        return
      end
      for _, model in ipairs(value.models) do
        if type(model) ~= "table" or type(model.id) ~= "string"
          or model.id == "" or type(model.label) ~= "string"
          or model.connection_id ~= args.connection_id
          or type(model.protocol_id) ~= "string" or model.protocol_id == ""
          or type(model.endpoint_id) ~= "string" or model.endpoint_id == ""
          or type(model.selectable) ~= "boolean"
          or (model.origin ~= "Discovered" and model.origin ~= "Declared"
            and model.origin ~= "Merged")
        then
          finish(callback, nil, error_value("Invalid provider model identity", "protocol"))
          return
        end
      end
      -- Discovery is inspection only. Selection remains an independent
      -- revision-checked, authorized runtime operation.
      finish(callback, vim.deepcopy(value), nil)
    end)
  elseif op == "credentials.capabilities" then
    -- A capability is from the trusted launcher, not a locally inferred
    -- provider method or an authentication/entitlement assertion.
    self:_request("_phenix/credentials/capabilities", {}, function(value, err)
      if err then
        if err.code == -32601 then
          finish(callback, nil, error_value(
            "Phenix authentication unavailable: no credential management grant", "unsupported"))
        else
          finish(callback, nil, err)
        end
        return
      end
      if type(value) ~= "table" or value.import ~= true
        or value.revoke ~= true
      then
        finish(callback, nil, error_value("Invalid credential capability", "protocol"))
        return
      end
      for _, field in ipairs({ "provider_id", "connection_id", "profile_id" }) do
        local id = value[field]
        if type(id) ~= "string" or id == ""
          or #id > 64 or id:find("[^%w_-]")
        then
          finish(callback, nil, error_value("Invalid granted credential identity", "protocol"))
          return
        end
      end
      finish(callback, vim.deepcopy(value), nil)
    end)
  elseif op == "credentials.import" or op == "credentials.revoke" then
    -- These are independent launcher-granted operations, NOT provider
    -- authentication. No credential bytes are kept in backend state or
    -- passed to user-visible diagnostics.
    for _, key in ipairs({ "provider_id", "connection_id", "profile_id" }) do
      local value = args[key]
      if type(value) ~= "string" or value == ""
        or #value > 64 or value:find("[^%w_-]")
      then
        finish(callback, nil, error_value("Invalid credential identity", "invalid_input"))
        return
      end
    end
    if op == "credentials.import"
      and (type(args.secret) ~= "string" or args.secret == ""
        or #args.secret > 65536 or args.secret:find("%z"))
    then
      finish(callback, nil, error_value("Invalid credential secret", "invalid_input"))
      return
    end
    local path = op == "credentials.import" and "_phenix/credentials/import"
      or "_phenix/credentials/revoke"
    local params = {
      provider_id = args.provider_id,
      connection_id = args.connection_id,
      profile_id = args.profile_id,
    }
    if op == "credentials.import" then params.secret = args.secret end
    self:_request(path, params, function(value, err)
      if err then
        if err.code == -32601 then
          finish(callback, nil, error_value(
            "Phenix does not grant credential management", "unsupported"))
        else
          -- Credential responses must never surface arbitrary provider/host
          -- prose. Even a malformed error.message may echo the submitted key.
          finish(callback, nil, {
            kind = err.kind, code = err.code, provider_code = err.provider_code,
            message = "Phenix credential operation rejected",
          })
        end
        return
      end
      if type(value) ~= "table" or value.ok ~= true then
        finish(callback, nil, error_value("Invalid credential operation result", "protocol"))
        return
      end
      finish(callback, { stored = op == "credentials.import",
        revoked = op == "credentials.revoke", authenticated = false }, nil)
    end)
  elseif op == "models.list" then
    local id = args.session_id
    if id == nil then
      for session in pairs(self.catalogs) do
        if id ~= nil then
          finish(callback, nil, error_value(
            "Model catalog query requires a session with multiple catalogs", "invalid_input"))
          return
        end
        id = session
      end
    end
    local catalog = id and self.catalogs[id]
    if catalog then
      finish(callback, vim.deepcopy(catalog), nil)
    else
      finish(callback, nil, error_value("Model catalog not available for session", "unsupported"))
    end
  elseif op == "models.select" then
    local id = args.session_id
    if id == nil then
      -- The old SDK overload is only unambiguous with one live catalog.
      -- In particular, never silently select for the last-loaded session.
      for session in pairs(self.catalogs) do
        if id ~= nil then
          finish(callback, nil, error_value(
            "Model selection requires a session with multiple catalogs", "invalid_input"))
          return
        end
        id = session
      end
    end
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
    local requested_version = self.catalog_versions[id]
    self:_request("session/set_config_option", {
      sessionId = id, configId = "model", value = args.model_id,
    }, function(value, err)
      if err then finish(callback, nil, err); return end
      if self.catalog_versions[id] ~= requested_version then
        finish(callback, nil, error_value(
          "Model catalog changed during selection; refresh and retry", "conflict"))
        return
      end
      if type(value) ~= "table" or type(value.configOptions) ~= "table" then
        finish(callback, nil, error_value("ACP model change omitted confirmed state", "protocol"))
        return
      end
      self:_catalog(id, value.configOptions)
      local updated = self.catalogs[id]
      if not updated or (
        updated.selected ~= args.model_id
        and not acknowledged_native_model_choice(args.model_id, updated.selected)
      ) then
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

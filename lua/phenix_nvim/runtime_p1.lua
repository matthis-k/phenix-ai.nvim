-- P1 implementation of the existing Neovim runtime interface.
-- State is a projection of ACP journal updates, never an agent state store.
local Client = require("phenix_client")
local ACP = require("phenix_client.acp")
local Transcript = require("phenix_client.transcript")

local M = {}
local state = {
  enabled = false,
  connection = "disconnected",
  client = nil,
  config = {},
  error = nil,
  active = nil,
  known = {},
  -- Monotone local intent sequence: late session/new or session/load results
  -- may be observed but cannot replace a newer user-selected active session.
  active_revision = 0,
  replay_revision = {},
  listeners = {},
  projection = Transcript.new(),
  pending = {},
  waiting = {},
}

local function emit(kind, value)
  local callbacks = {}
  for _, fn in ipairs(state.listeners) do callbacks[#callbacks + 1] = fn end
  for _, fn in ipairs(callbacks) do
    local ok, err = pcall(fn, kind, value)
    if not ok then vim.schedule(function() vim.notify(tostring(err), vim.log.levels.ERROR) end) end
  end
end

local function unavailable(feature, callback)
  local err = { kind = "unsupported", message = "P1 does not expose " .. feature }
  if callback then callback(nil, err) end
end

local function flush_waiters(value, err)
  local waiting = state.waiting
  state.waiting = {}
  for _, fn in ipairs(waiting) do fn(value, err) end
end

-- Each asynchronous operation belongs to the client generation that
-- admitted it. A late reply from a retired connection must not mutate the
-- projection, active session or the new connection's visible state.
local function current_client(client)
  return state.client == client and state.connection == "ready"
end

local function retired_reply(client, callback)
  if current_client(client) then return false end
  if callback then
    callback(nil, { kind = "disconnected", message = "Phenix connection changed before the operation completed" })
  end
  return true
end

local function connected(callback)
  if state.connection == "ready" and state.client then
    callback(state.client)
  else
    M.connect(function(_, err)
      if err then
        callback(nil, err)
      else
        callback(state.client)
      end
    end)
  end
end

function M.active()
  return state.enabled
end

function M.configure(config)
  state.enabled = config.backend == "p1"
  state.config = config
end

function M.on_event(callback)
  state.listeners[#state.listeners + 1] = callback
  return function()
    for i, fn in ipairs(state.listeners) do
      if fn == callback then table.remove(state.listeners, i); return end
    end
  end
end

function M.connect(callback)
  if state.connection == "ready" then
    if callback then callback(state.client, nil) end
    return
  end
  if state.connection == "failed" then
    -- Retire only callbacks from the failed generation. A retry callback
    -- belongs to the replacement connection, never to the old waiters.
    M.disconnect()
  end
  if callback then state.waiting[#state.waiting + 1] = callback end
  if state.connection == "connecting" then return end
  state.connection = "connecting"
  state.error = nil
  emit("status", M.status())
  local config = state.config
  local client = Client.new(ACP.new({
    command = config.command or "phenix-basic-acp",
    args = config.args or {},
    cwd = vim.fn.getcwd(),
  }))
  state.client = client
  client:on("connection.failed", function(event)
    if state.client ~= client then return end
    state.connection = "failed"
    state.error = event.error or { kind = "transport", message = "Phenix disconnected" }
    emit("status", M.status())
  end)
  client:on("permission.requested", function(event)
    if state.client ~= client then return end
    -- Neovim owns the dialog; the ACP response is restricted to the
    -- request and choices supplied by Phenix.
    vim.schedule(function()
      if state.client ~= client then return end
      require("phenix_nvim.interaction").acp_permission(event, function(option_id)
        if state.client ~= client then return end
        client:respond_permission(event.request_id, option_id, function(_, err)
          if err and err.kind ~= "not_found" then
            vim.notify(err.message or tostring(err), vim.log.levels.ERROR)
          end
        end)
      end)
    end)
  end)
  client:on("models.changed", function(event)
    if state.client ~= client then return end
    -- A catalog update is runtime state, not a locally accepted selection.
    -- Pass revocations through even when the affected session is not active.
    emit("models", {
      session_id = event.session_id,
      catalog = event.catalog and vim.deepcopy(event.catalog) or nil,
    })
    if event.session_id == state.active then emit("status", M.status()) end
  end)
  client:on("session.updated", function(event)
    if state.client ~= client then return end
    if state.projection:apply(event) then
      emit("sessions", state.projection:session_state())
      emit("status", M.status())
    end
  end)
  client:start(function(_, err)
    if state.client ~= client then return end
    if err then
      state.error = err
      state.connection = "failed"
      state.client = nil
      client:close()
      flush_waiters(nil, err)
    else
      state.connection = "ready"
      flush_waiters(client, nil)
    end
    emit("status", M.status())
  end)
end

function M.disconnect()
  local client = state.client
  state.client = nil
  state.connection = "disconnected"
  state.error = nil
  state.active = nil
  state.active_revision = state.active_revision + 1
  state.known = {}
  state.replay_revision = {}
  state.projection = Transcript.new()
  if client then client:close() end
  flush_waiters(nil, { kind = "disconnected", message = "Phenix connection closed" })
  emit("sessions", state.projection:session_state())
  emit("status", M.status())
end

function M.new_session(callback)
  state.active_revision = state.active_revision + 1
  local revision = state.active_revision
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    client:new_session(function(result, problem)
      if retired_reply(client, callback) then return end
      if not problem and result then
        if revision == state.active_revision then state.active = result.session_id end
        state.known[result.session_id] = true
        emit("status", M.status())
      end
      if callback then callback(result, problem) end
    end)
  end)
end

function M.resume_session(session_id, callback)
  state.active_revision = state.active_revision + 1
  local revision = state.active_revision
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    -- Replay is sourced from Phenix's journal. Discard any previous
    -- presentation projection before accepting the replayed events.
    local previous = state.projection:session(session_id)
    state.replay_revision[session_id] = (state.replay_revision[session_id] or 0) + 1
    local replay_revision = state.replay_revision[session_id]
    state.projection:clear(session_id)
    client:load_session(session_id, function(result, problem)
      if retired_reply(client, callback) then return end
      if state.replay_revision[session_id] ~= replay_revision then
        if callback then callback(nil, {
          kind = "superseded", message = "A newer replay replaced this session load",
        }) end
        return
      end
      if problem then
        -- Only the latest load may restore a failed replay's projection.
        state.projection:restore(session_id, previous)
      else
        if revision == state.active_revision then state.active = session_id end
        state.known[session_id] = true
      end
      emit("sessions", state.projection:session_state())
      emit("status", M.status())
      if callback then callback(result, problem) end
    end)
  end)
end

function M.activate_session(session_id, callback)
  if session_id == nil then
    state.active_revision = state.active_revision + 1
    state.active = nil
    emit("status", M.status())
    if callback then callback(nil, nil) end
  elseif state.known[session_id] then
    state.active_revision = state.active_revision + 1
    state.active = session_id
    emit("status", M.status())
    if callback then callback(state.projection:session(session_id), nil) end
  else
    M.resume_session(session_id, callback)
  end
end

function M.list_sessions(callback)
  -- ACP v1 cannot enumerate persisted sessions. This list is restricted to
  -- IDs returned by Phenix during this connection, not a persistence query.
  local sessions = {}
  for id in pairs(state.known) do
    sessions[#sessions + 1] = { session_id = id, title = id }
  end
  table.sort(sessions, function(a, b) return a.session_id < b.session_id end)
  if callback then callback({ sessions = sessions, partial = true }, nil) end
end

function M.close_session(_, callback)
  unavailable("session close", callback)
end

function M.active_session()
  return state.active
end

function M.active_session_object()
  return nil
end

local function blocks(segments)
  local result = {}
  for _, item in ipairs(segments or {}) do
    if item.kind == "text" and type(item.text) == "string" then
      result[#result + 1] = { type = "text", text = item.text }
    elseif item.kind == "resource" and type(item.source) == "table"
      and type(item.source.uri) == "string"
    then
      result[#result + 1] = {
        type = "resource_link",
        name = item.source.label or item.source.name or item.source.uri,
        uri = item.source.uri,
      }
      if type(item.snapshot) == "string" and item.snapshot ~= "" then
        result[#result + 1] = { type = "text", text = item.snapshot }
      end
    else
      return nil, { kind = "unsupported",
        message = "P1 supports only text and resource-link inputs" }
    end
  end
  return result
end

function M.prompt(session_id, segments, callback)
  if type(session_id) ~= "string" or not state.known[session_id] then
    if callback then callback(nil, { kind = "not_found", message = "Unknown P1 session" }) end
    return
  end
  local content, err = blocks(segments)
  if err then if callback then callback(nil, err) end; return end
  if #content == 0 then
    if callback then callback(nil, { kind = "invalid_input", message = "Empty prompt" }) end
    return
  end
  connected(function(client, problem)
    if problem then if callback then callback(nil, problem) end; return end
    client:send_content(session_id, content, function(result, send_error)
      if retired_reply(client, callback) then return end
      if callback then callback(result, send_error) end
    end)
  end)
end

function M.cancel_active()
  if not state.active or not state.client then return end
  state.client:cancel(state.active, function(_, err)
    if err then vim.notify(err.message or tostring(err), vim.log.levels.ERROR) end
  end)
end

function M.choose_model(callback)
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    if not state.active then
      unavailable("model catalog without a session", callback)
      return
    end
    require("phenix_client.nvim").choose_model(client, state.active, function(value, problem)
      if retired_reply(client, callback) then return end
      if callback then callback(value, problem) end
    end)
  end)
end

-- Introspect only capabilities advertised by the connected runtime.
-- This is display data; authorization is still checked on each operation.
function M.capabilities(callback)
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    local offered = client:capabilities() or {}
    local view = {
      backend = "p1",
      transport = "acp-v1",
      session_id = state.active,
      session_operations = vim.deepcopy(offered.session_operations or {}),
      management = vim.deepcopy(offered.management or {}),
    }
    if state.active == nil or not view.management.models then
      if callback then callback(view, nil) end
      return
    end
    client:list_models(state.active, function(catalog, failure)
      if retired_reply(client, callback) then return end
      if not failure and catalog then
        view.selected_model = catalog.selected
        view.models = vim.deepcopy(catalog.models)
      else
        view.model_catalog_error = failure
      end
      if callback then callback(view, nil) end
    end)
  end)
end

function M.list_selections(callback)
  -- ACP model menus belong to one existing session. In particular the
  -- provider-first auth picker must not submit a nil session ID while the
  -- user is still onboarding an authorized credential profile.
  if not state.active then
    if callback then callback(nil, {
      kind = "not_found",
      message = "Create a Phenix session with :Phenix new before choosing a model",
    }) end
    return
  end
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    client:list_models(state.active, function(catalog, problem)
      if retired_reply(client, callback) then return end
      if problem then if callback then callback(nil, problem) end; return end
      local available = {}
      for _, item in ipairs(catalog.models) do
        available[#available + 1] = {
          id = item.id, presentation = { kind = "model" },
          model = item.name, provider = item.provider, authorized = item.authorized,
        }
      end
      if callback then callback({ available = available, selected = catalog.selected }, nil) end
    end)
  end)
end

function M.select(_, callback)
  unavailable("model selection", callback)
end

-- Read-only provider registrations are runtime-authorized per request. They
-- cannot be used as proof of a credential, selectable model, or account grant.
function M.list_providers(callback)
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    client:list_providers(function(page, problem)
      if retired_reply(client, callback) then return end
      if callback then callback(page, problem) end
    end)
  end)
end

-- A launcher may authorize multiple independent credential roots. These are
-- already-selected exact-resource grants, not capabilities created by ACP
-- account selectors. Keep the legacy one-account shape for older runtimes.
local function granted_accounts(capabilities)
  if type(capabilities) ~= "table" then return {} end
  if type(capabilities.profiles) == "table" then return capabilities.profiles end
  return { capabilities }
end

-- Provider registration is not authentication; combine the installed
-- catalog with the exact admitted credential identities. No provider is
-- inferred to be usable simply because its name is in the catalog.
function M.list_authentication_methods(callback)
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    client:credential_capabilities(function(granted, denial)
      if retired_reply(client, callback) then return end
      if denial then if callback then callback(nil, denial) end; return end
      local accounts = granted_accounts(granted)
      if #accounts == 0 then
        if callback then callback(nil, { kind = "unsupported",
          message = "No authorized credential profiles" }) end
        return
      end
      client:list_providers(function(page, problem)
        if retired_reply(client, callback) then return end
        if problem then if callback then callback(nil, problem) end; return end
        local methods, seen = {}, {}
        for _, account in ipairs(accounts) do
          for _, provider in ipairs(page.providers or {}) do
            if provider.id == account.provider_id then
              for _, connection in ipairs(provider.connections or {}) do
                if connection.id == account.connection_id then
                  for _, method in ipairs(connection.auth_methods or {}) do
                    if string.lower(tostring(method.kind)) == "apikey" then
                      local key = provider.id .. "/" .. connection.id .. "/"
                        .. tostring(account.profile_id) .. "/" .. tostring(method.id)
                      if not seen[key] then
                        seen[key] = true
                        methods[#methods + 1] = {
                          provider_id = provider.id, provider_name = provider.label,
                          connection_id = connection.id, connection_name = connection.label,
                          method_id = method.id, label = method.label, kind = method.kind,
                          profile_id = account.profile_id,
                          authenticated = false, profiles = {},
                        }
                      end
                    end
                  end
                end
              end
            end
          end
        end
        if #methods == 0 then
          if callback then callback(nil, { kind = "unsupported",
            message = "The authorized profiles have no installed API-key methods" }) end
          return
        end

        -- Check current provider-owned status independently for every
        -- connection. A stored credential is not authentication, and an
        -- authenticated sibling account must never validate this profile.
        local groups, ordered = {}, {}
        for _, method in ipairs(methods) do
          local key = method.provider_id .. "/" .. method.connection_id
          if not groups[key] then
            groups[key] = {}
            ordered[#ordered + 1] = { key = key,
              provider_id = method.provider_id, connection_id = method.connection_id }
          end
          groups[key][#groups[key] + 1] = method
        end
        local function read_status(index)
          if retired_reply(client, callback) then return end
          local group = ordered[index]
          if not group then
            if callback then callback({ methods = methods }, nil) end
            return
          end
          client:get_provider_auth_status(group.provider_id, group.connection_id,
            function(status, status_error)
              if retired_reply(client, callback) then return end
              if not status_error and status
                and status.provider_id == group.provider_id
                and status.connection_id == group.connection_id
              then
                for _, method in ipairs(groups[group.key]) do
                  local matches = 0
                  for _, profile in ipairs(status.profiles or {}) do
                    if profile.id == method.profile_id
                      and profile.method_id == method.method_id
                    then
                      matches = matches + 1
                      method.profiles[#method.profiles + 1] = vim.deepcopy(profile)
                      method.authenticated = matches == 1
                        and profile.status == "Authenticated"
                    end
                  end
                  if matches ~= 1 then method.authenticated = false end
                end
              end
              read_status(index + 1)
            end)
        end
        read_status(1)
      end)
    end)
  end)
end

-- The management host can store a key only for a launcher-authorized
-- credential identity. Storage success is not validated provider login.
function M.authenticate(identity, secret, callback)
  if type(identity) ~= "table" then
    if callback then callback(nil, { kind = "invalid_input",
      message = "Authentication identity is required" }) end
    return
  end
  local kind = string.lower(tostring(identity.kind or ""))
  if kind ~= "apikey" and kind ~= "api_key" and kind ~= "api_token" then
    unavailable("this authentication method", callback)
    return
  end
  if type(identity.provider_id) ~= "string" or identity.provider_id == ""
    or type(identity.connection_id) ~= "string" or identity.connection_id == ""
    or type(identity.profile_id) ~= "string" or identity.profile_id == ""
  then
    if callback then callback(nil, { kind = "invalid_input",
      message = "An explicit provider, connection and credential profile are required" }) end
    return
  end
  if type(secret) ~= "string" or secret == "" then
    if callback then callback(nil, { kind = "invalid_input",
      message = "An API key is required" }) end
    return
  end
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    client:credential_capabilities(function(granted, problem)
      if retired_reply(client, callback) then return end
      if problem then if callback then callback(nil, problem) end; return end
      local admitted = false
      for _, account in ipairs(granted_accounts(granted)) do
        if account.provider_id == identity.provider_id
          and account.connection_id == identity.connection_id
          and account.profile_id == identity.profile_id
        then
          admitted = true
          break
        end
      end
      if not admitted then
        if callback then callback(nil, { kind = "denied",
          message = "Credential profile is not authorized by the Phenix launcher" }) end
        return
      end
      client:import_credential(identity.provider_id, identity.connection_id,
        identity.profile_id, secret, function(stored, import_problem)
          if retired_reply(client, callback) then return end
          if import_problem then
            if callback then callback(nil, import_problem) end
            return
          end
          if not stored or stored.stored ~= true then
            if callback then callback(nil, { kind = "protocol",
              message = "Phenix did not confirm credential storage" }) end
            return
          end
          -- Storage alone is not authentication. Ask the current provider
          -- to verify this exact credential profile before enabling its UI.
          client:get_provider_auth_status(identity.provider_id, identity.connection_id,
            function(status, status_error)
              if retired_reply(client, callback) then return end
              local verified = false
              if not status_error and status
                and status.provider_id == identity.provider_id
                and status.connection_id == identity.connection_id
              then
                local matches = 0
                for _, profile in ipairs(status.profiles or {}) do
                  if profile.id == identity.profile_id
                    and (identity.method_id == nil
                      or profile.method_id == identity.method_id)
                    and profile.status == "Authenticated"
                  then
                    matches = matches + 1
                  end
                end
                verified = matches == 1
              end
              if callback then callback({
                kind = verified and "authenticated" or "stored",
                verified = verified, authenticated = verified,
                provider_id = identity.provider_id,
                connection_id = identity.connection_id,
                profile_id = identity.profile_id,
              }, nil) end
            end)
        end)
    end)
  end)
end

-- Revocation is a separately authorized host operation. Identifiers are
-- selectors, never authority tokens; the installed credential plugin decides.
function M.revoke_credential(provider_id, connection_id, profile_id, callback)
  connected(function(client, err)
    if err then if callback then callback(nil, err) end; return end
    client:revoke_credential(provider_id, connection_id, profile_id,
      function(value, problem)
        if retired_reply(client, callback) then return end
        if callback then callback(value, problem) end
      end)
  end)
end

function M.decide_review(_, _, callback)
  unavailable("permission decisions", callback)
end

function M.logs(_, callback)
  unavailable("logs", callback)
end

function M.log_reference(_, callback)
  unavailable("log references", callback)
end

function M.refresh_client_tools(callback)
  -- The Basic ACP host may already have its own authorized tools, but it has
  -- not admitted any templates registered in this Neovim process. Reporting a
  -- successful refresh would falsely claim model-visible client capabilities.
  -- A future negotiated native binding must replace this explicit boundary.
  unavailable("client-tool registration", callback)
end

function M.refresh_session_state(callback)
  local projection = state.active and state.projection:session(state.active)
  if callback then callback(projection, nil) end
  emit("sessions", state.projection:session_state())
end

function M.tick() end

function M.status(session_id)
  return {
    connection = state.connection,
    error = state.error,
    session_id = session_id or state.active,
  }
end

function M.session_state()
  return state.projection:session_state()
end

return M

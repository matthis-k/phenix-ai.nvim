local clipboard = require("phenix_nvim.clipboard")
local compose = require("phenix_nvim.compose.buffer")
local compose_model = require("phenix_nvim.compose.model")
local context = require("phenix_nvim.context")
local image = require("phenix_nvim.image")
local logs = require("phenix_nvim.logs")
local runtime = require("phenix_nvim.runtime")
local sessions = require("phenix_nvim.sessions")
local sidebar = require("phenix_nvim.sidebar")
local state = require("phenix_nvim.state")
local util = require("phenix_nvim.util")
local auth_ui = require("phenix_nvim.ui.auth")

local M = {}
local submissions = setmetatable({}, { __mode = "k" })
local connection_generation = 0

-- A prompt completion belongs to one editor surface, session and transport
-- generation. It is never permission to clear a reused compose buffer.
local function submission_current(pending)
  return submissions[pending.document] == pending
    and pending.generation == connection_generation
    and not pending.surface.closing
    and sidebar.surface_for_document(pending.document) == pending.surface
    and pending.surface.session_id == pending.session_id
    and (pending.surface.session_binding_generation or 0) == pending.binding_generation
end

local function target_surface(options)
  options = options or {}
  -- Explicit document ownership must never fall back to another sidebar.
  -- Old attachment callbacks may still carry a detached compose document.
  if options.document ~= nil then
    return sidebar.surface_for_document(options.document)
  end
  return sidebar.current_surface() or sidebar.open()
end

local function insert(item, options)
  local surface = target_surface(options)
  if surface == nil then
    local message = options and options.document ~= nil
      and "compose document is not attached to a Phenix chat window"
      or "could not open Phenix chat window"
    util.notify(message, vim.log.levels.ERROR)
    return nil
  end
  local document = options and options.document or surface.compose
  local win = sidebar.focus_compose(surface)
  local stored = compose_model.add(document, item)
  local inserted, error = compose.insert(document, stored, win)
  if not inserted then
    compose_model.remove(document, stored.id)
    util.notify(error or "could not insert compose attachment", vim.log.levels.ERROR)
    return nil
  end
  return stored
end

function M.reference()
  local mode = vim.fn.mode(1)
  local item, error
  if mode == "v" or mode == "V" or mode == "\22" then
    item, error = context.visual_selection()
  else
    item = context.current_location()
  end
  if item == nil then
    util.notify(error, vim.log.levels.ERROR)
    return
  end
  insert(item)
end

function M.reference_range(start_line, end_line)
  insert(context.line_selection(start_line, end_line))
end

function M.reference_at(value)
  local item, error = context.typed_reference(value)
  if item == nil then
    util.notify(error, vim.log.levels.ERROR)
    return
  end
  insert(item)
end

function M.reference_picker()
  context.pick_reference(function(item, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    if item ~= nil then
      insert(item)
    end
  end)
end

local function attach_image_file(path, temporary, options)
  options = options or {}
  local item, error = image.from_file(path)
  if temporary then
    os.remove(path)
  end
  if item == nil then
    if not options.quiet then
      util.notify(error, vim.log.levels.ERROR)
    end
    return nil
  end
  if temporary then
    item.path = nil
  end
  return insert(item, options)
end

function M.attach_image(source, options)
  options = options or {}
  source = (source == nil or source == "") and "clipboard" or source
  if source == "clipboard" then
    local path, error = clipboard.temp_image_file()
    if path == nil then
      if not options.quiet then
        util.notify(error or "clipboard does not contain a supported image", vim.log.levels.ERROR)
      end
      return nil
    end
    return attach_image_file(path, true, options)
  end
  return attach_image_file(source, false, options)
end

-- Attachment changes update document.revision; normal typing changes only
-- Neovim's buffer changedtick. A submitted prompt owns exactly this snapshot.
local function compose_snapshot(document)
  local buffer = compose.ensure(document)
  return tostring(document.revision) .. ":" .. tostring(vim.api.nvim_buf_get_changedtick(buffer))
end

local function submit(pending)
  if not submission_current(pending) then
    return
  end
  runtime.prompt(pending.session_id, pending.content, function(_, error)
    local current = submission_current(pending)
    if submissions[pending.document] == pending then
      submissions[pending.document] = nil
    end
    if not current then
      -- The runtime owns whether the old request was admitted or cancelled.
      -- A late callback must not mutate a replacement editor projection.
      return
    end
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    if compose_snapshot(pending.document) == pending.revision then
      compose.clear(pending.document)
    end
  end)
end

function M.send(options)
  local surface = target_surface(options)
  if surface == nil then
    return
  end
  local document = options and options.document or surface.compose
  if document ~= surface.compose then
    surface = sidebar.surface_for_document(document)
    if surface == nil then
      util.notify("compose document is not attached to a Phenix chat window", vim.log.levels.ERROR)
      return
    end
  end

  local content, error = compose.serialize(document)
  if content == nil then
    util.notify(error, vim.log.levels.ERROR)
    return
  end
  if #content == 0 or (#content == 1 and content[1].kind == "text" and content[1].text == "") then
    util.notify("compose buffer is empty", vim.log.levels.WARN)
    return
  end
  local active = submissions[document]
  if active ~= nil then
    if submission_current(active) then
      -- ACP v1 has one active prompt per session. Runtime-backed durable
      -- admission is separate; the editor cannot enqueue another prompt.
      util.notify("a compose submission is still in flight", vim.log.levels.WARN)
      return
    end
    -- An old session or disconnected client cannot hold this draft hostage.
    submissions[document] = nil
  end
  local pending = {
    document = document,
    surface = surface,
    session_id = surface.session_id,
    content = content,
    revision = compose_snapshot(document),
    generation = connection_generation,
    binding_generation = surface.session_binding_generation or 0,
  }
  submissions[document] = pending

  if pending.session_id ~= nil then
    submit(pending)
    return
  end
  runtime.new_session(function(created, create_error)
    if not submission_current(pending) then
      return
    end
    if create_error ~= nil then
      submissions[document] = nil
      util.notify(vim.inspect(create_error), vim.log.levels.ERROR)
      return
    end
    local session_id = created and (created.session_id or created.id)
    if type(session_id) ~= "string" or session_id == "" then
      submissions[document] = nil
      util.notify("Phenix created a session without an id", vim.log.levels.ERROR)
      return
    end
    pending.session_id = session_id
    sidebar.bind_session(session_id, surface)
    pending.binding_generation = surface.session_binding_generation or 0
    submit(pending)
  end)
end

function M.toggle()
  sidebar.toggle()
end

function M.new(mode)
  local surface, error = sidebar.new(mode or "sidebar")
  if surface == nil and error ~= nil then
    util.notify(error, vim.log.levels.ERROR)
  end
  return surface
end


function M.logs(scope)
  logs.open(scope)
end

function M.cancel()
  runtime.cancel_active()
end

function M.new_session(callback)
  local surface = target_surface()
  sessions.new(function(value, error)
    if error == nil and surface ~= nil then
      local session_id = value and (value.session_id or value.id)
      if session_id ~= nil then
        sidebar.bind_session(session_id, surface)
      end
    end
    if callback ~= nil then
      util.safe_call(callback, value, error)
    elseif error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
    end
  end)
end

function M.close_session()
  local surface = target_surface()
  local session_id = surface and surface.session_id or runtime.active_session()
  sessions.close(session_id, function(_, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    if surface ~= nil then
      sidebar.bind_session(nil, surface)
    end
  end)
end

function M.load_session(session_id)
  if type(session_id) ~= "string" or session_id == "" then
    util.notify("Phenix session ID must not be empty", vim.log.levels.ERROR)
    return
  end
  local surface = target_surface()
  sessions.resume(session_id, function(result, err)
    if err then
      util.notify(err.message or vim.inspect(err), vim.log.levels.ERROR)
      return
    end
    if surface then
      sidebar.bind_session(session_id, surface)
    end
    return result
  end)
end

function M.choose_session()
  local surface = target_surface()
  sessions.choose(function(value, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local session_id = value and (value.session_id or value.id)
    if surface ~= nil and session_id ~= nil then
      sidebar.bind_session(session_id, surface)
    end
  end)
end

local function presentation_kind(item)
  local presentation = item and item.presentation
  if type(presentation) == "table" then
    return string.lower(tostring(presentation.kind or ""))
  end
  return string.lower(tostring(presentation or ""))
end

local function choice_label(item, selected)
  local name = item.name or item.id or "unknown"
  local id = item.id
  local marker = id ~= nil and id == selected and "✓ " or "  "
  local kind = presentation_kind(item)
  local glyph = kind == "router" and "󰒍" or "󰧑"
  local tag = kind == "router" and "router" or "model"
  local label = marker .. glyph .. " [" .. tag .. "] " .. name
  if item.description ~= nil and item.description ~= "" then
    label = label .. "  ·  " .. item.description
  end
  if kind == "router" and id ~= nil and id ~= name then
    label = label .. "  ·  " .. id
  end
  return label
end

local function open_external_auth(result)
  local uri = result and (result.url or result.uri)
  -- Browser authentication is provider-approved, but plugin output is not
  -- inherently a safe URI for opening on the user's machine. Do not invoke
  -- OS handlers for file:, javascript:, shell-like or plaintext remote links.
  if type(uri) ~= "string" or #uri > 4096
    or not uri:match("^https://[^/%?#]+")
    or uri:find("[%c%s\\]")
  then
    return false
  end
  local authority = uri:match("^https://([^/%?#]+)")
  if authority:find("@", 1, true) then
    return false
  end
  local instructions = result.instructions or result.prompt
  if result.user_code ~= nil then
    instructions = "Enter authorization code " .. tostring(result.user_code)
      .. " in your browser."
  end
  if instructions ~= nil and instructions ~= "" then
    util.notify(instructions, vim.log.levels.INFO)
  end
  if type(vim.ui.open) == "function" then
    local call_ok, handle, open_error = pcall(vim.ui.open, uri)
    if call_ok and open_error == nil then
      return true
    end
    local failure = call_ok and open_error or handle
    if failure ~= nil then
      util.notify(tostring(failure), vim.log.levels.WARN)
    end
  end
  util.notify("Open this URL to finish Phenix authentication: " .. uri, vim.log.levels.INFO)
  return true
end

local auth_generation = 0
local selection_generation = 0
local auth_progress
local oauth_attempt

local function close_auth_progress()
  local view = auth_progress
  auth_progress = nil
  if view then view.close() end
end

local function cancel_active_oauth(report_error)
  local pending = oauth_attempt
  oauth_attempt = nil
  close_auth_progress()
  if pending and type(runtime.cancel_authentication) == "function" then
    runtime.cancel_authentication(pending.identity, pending.attempt_id, function(_, problem)
      if report_error and problem and problem.kind ~= "unsupported" then
        util.notify(problem.message or "Could not cancel provider authorization",
          vim.log.levels.WARN)
      end
    end)
  end
end
local connection_state = runtime.status().connection
runtime.on_event(function(kind, status)
  if kind == "models" then
    -- An open picker was built from an older runtime catalog. Retire its
    -- callbacks; the user can reopen it against current advertised choices.
    selection_generation = selection_generation + 1
    return
  end
  if kind ~= "status" then
    return
  end
  local next_state = status.connection
  if connection_state == "ready" and next_state ~= "ready" then
    auth_generation = auth_generation + 1
    cancel_active_oauth()
    selection_generation = selection_generation + 1
    connection_generation = connection_generation + 1
    -- Pending editor callbacks from the old connection are no longer
    -- authorized to clear drafts. Phenix decides request admission itself.
    for document in pairs(submissions) do
      submissions[document] = nil
    end
  end
  connection_state = next_state
end)

local function authentication_kind(result)
  return result and string.lower(tostring(result.kind or "")) or ""
end

local function finish_authentication(callback, value, problem)
  if callback ~= nil then
    util.safe_call(callback, value, problem)
  elseif problem ~= nil then
    util.notify(problem.message or vim.inspect(problem),
      problem.kind == "pending" and vim.log.levels.INFO
        or (problem.kind == "remote_revocation_unconfirmed"
          and vim.log.levels.WARN or vim.log.levels.ERROR))
  end
end

-- A method ID is only unique within its provider and connection. Preserve
-- all three authoritative identities instead of submitting its UI label.
local function authentication_provider_id(method)
  return method.provider_id or method.provider
end

local function authentication_identity(method)
  local provider_id = authentication_provider_id(method)
  local connection_id = method.connection_id or method.connection
  local method_id = method.method_id or method.id
  if type(provider_id) ~= "string" or provider_id == ""
    or type(connection_id) ~= "string" or connection_id == ""
    or type(method_id) ~= "string" or method_id == ""
  then
    return nil
  end
  return {
    provider_id = provider_id,
    connection_id = connection_id,
    method_id = method_id,
    kind = method.kind,
    profile_id = method.profile_id,
  }
end

local function start_authentication(method, secret, callback)
  local identity = authentication_identity(method)
  if identity == nil then
    finish_authentication(callback, nil, {
      kind = "invalid_input",
      message = "Phenix advertised authentication without provider/connection/method identity",
    })
    return
  end
  auth_generation = auth_generation + 1
  local generation = auth_generation
  local function complete(value, problem)
    if generation ~= auth_generation then return end
    if oauth_attempt and oauth_attempt.generation == generation
      and problem and problem.kind ~= "expired" and problem.kind ~= "cancelled"
    then
      cancel_active_oauth()
    else
      if oauth_attempt and oauth_attempt.generation == generation then
        oauth_attempt = nil
      end
      close_auth_progress()
    end
    finish_authentication(callback, value, problem)
  end
  runtime.authenticate(identity, secret, function(result, problem)
    if generation ~= auth_generation then
      return
    end
    if problem ~= nil then
      complete(nil, problem)
      return
    end
    local kind = authentication_kind(result)
    if kind == "authenticated" then
      util.notify(identity.provider_id .. " authentication completed", vim.log.levels.INFO)
      complete(result, nil)
      return
    end
    if kind == "stored" and result.verified == false then
      util.notify(identity.provider_id .. " API key stored for profile "
        .. tostring(result.profile_id) .. "; authentication not yet verified",
        vim.log.levels.INFO)
      complete(result, nil)
      return
    end
    if kind ~= "external" and kind ~= "openbrowser" and kind ~= "deviceauthorization" then
      complete(nil, {
        kind = "protocol", message = "Phenix returned an unknown authentication state",
      })
      return
    end
    if not open_external_auth(result) then
      complete(nil, {
        kind = "protocol", message = "Phenix authentication did not provide an authorization URL",
      })
      return
    end
    if type(result.attempt_id) ~= "string"
      or type(runtime.poll_authentication) ~= "function" then
      complete(nil, {
        kind = "protocol",
        message = "The runtime cannot poll this authorization challenge",
      })
      return
    end
    oauth_attempt = { identity = result, attempt_id = result.attempt_id,
      generation = generation }
    auth_progress = auth_ui.pending("Phenix / " .. identity.provider_id, function()
      if generation ~= auth_generation then return end
      -- Disarm the local callback generation first: an in-flight poll may
      -- return Completed while cancellation is racing with the runtime.
      auth_generation = auth_generation + 1
      cancel_active_oauth(true)
    end)
    -- Poll precisely this provider-owned attempt. Do not call begin() again,
    -- and never mark a browser-open action as successful authentication.
    local checks = 0
    local last_challenge = tostring(result.url) .. "\0"
      .. tostring(result.user_code or "")
    local function poll()
      if generation ~= auth_generation then return end
      checks = checks + 1
      if checks > 600 then
        complete(nil, {
          kind = "expired", message = "Authorization did not complete",
        })
        return
      end
      runtime.poll_authentication(result, result.attempt_id,
        function(status, problem)
          if generation ~= auth_generation then return end
          if problem then
            complete(nil, problem)
            return
          end
          local state = authentication_kind(status)
          if state == "authenticated" then
            util.notify(identity.provider_id .. " authentication completed",
              vim.log.levels.INFO)
            complete(status, nil)
          elseif state == "pending" then
            vim.defer_fn(poll, 1000)
          elseif state == "awaiting_input" then
            local challenge = tostring(status.url) .. "\0"
              .. tostring(status.user_code or "")
            if challenge ~= last_challenge then
              if not open_external_auth(status) then
                complete(nil, {
                  kind = "protocol",
                  message = "Provider returned an unsafe authorization URL",
                })
                return
              end
              last_challenge = challenge
            end
            vim.defer_fn(poll, 1000)
          else
            complete(nil, {
              kind = state,
              message = "Provider authorization " .. state,
            })
          end
        end)
    end
    vim.defer_fn(poll, 1000)
  end)
end

local function authenticate_method(method, callback)
  if authentication_identity(method) == nil then
    finish_authentication(callback, nil, {
      kind = "invalid_input",
      message = "Authentication method has no complete provider/connection identity",
    })
    return
  end
  local kind = string.lower(tostring(method.kind or ""))
  local api_key = kind == "apikey" or kind == "api_key" or kind == "api_token"
  local oauth = kind == "oauth" or kind == "oauthauthorizationcode"
    or kind == "oauthdevicecode" or kind == "oauth_authorization_code"
    or kind == "oauth_device_code"
  if not api_key and not oauth then
    finish_authentication(callback, nil, {
      kind = "unsupported",
      message = "Phenix advertised an unrecognized authentication kind",
    })
    return
  end
  if oauth then
    start_authentication(method, nil, callback)
    return
  end
  local generation = auth_generation
  local provider = method.provider_name or authentication_provider_id(method) or method.name or "provider"
  local function request_secret(named)
    util.input_secret(provider .. " API key: ", function(secret, input_error)
      if generation ~= auth_generation then return end
      if input_error ~= nil then
        finish_authentication(callback, nil, input_error)
        return
      end
      if secret == nil or secret == "" then
        finish_authentication(callback, nil, {
          kind = "cancelled", message = "authentication cancelled",
        })
        return
      end
      if type(secret) ~= "string" or secret:match("%S") == nil then
        finish_authentication(callback, nil, { message = "API key must not be empty" })
        return
      end
      local scoped = vim.deepcopy(method)
      if named then scoped.profile_id = named end
      start_authentication(scoped, secret, callback)
    end)
  end
  local function request_source(named)
    local options = { "Enter API key", "Read from environment variable" }
    auth_ui.select(options, { prompt = provider .. " API key source" }, function(choice)
      if generation ~= auth_generation then return end
      if choice == nil then
        finish_authentication(callback, nil, {
          kind = "cancelled", message = "authentication cancelled",
        })
        return
      end
      if choice == options[1] then
        request_secret(named)
        return
      end
      if type(runtime.bind_auth_environment) ~= "function" then
        finish_authentication(callback, nil, {
          kind = "unsupported", message = "Environment source binding is unavailable",
        })
        return
      end
      -- The authentication strategy can advertise a provider-specific
      -- variable hint. Never assume OpenAI's variable for other providers.
      local suggested = method.environment_variable
      if type(suggested) ~= "string" or #suggested > 128
        or not suggested:match("^[A-Z_][A-Z0-9_]*$") then
        suggested = ""
      end
      vim.ui.input({
        prompt = "Environment variable name: ",
        default = suggested,
      }, function(name)
        if generation ~= auth_generation then return end
        if name == nil then
          finish_authentication(callback, nil, {
            kind = "cancelled", message = "authentication cancelled",
          })
          return
        end
        if type(name) ~= "string" or #name > 128
          or not name:match("^[A-Z_][A-Z0-9_]*$") then
          finish_authentication(callback, nil, {
            kind = "invalid_input", message = "Invalid environment variable name",
          })
          return
        end
        local scoped = vim.deepcopy(method)
        if named then scoped.profile_id = named end
        runtime.bind_auth_environment(authentication_identity(scoped), name,
          function(value, problem)
            if generation ~= auth_generation then return end
            if problem then
              finish_authentication(callback, nil, problem)
              return
            end
            if value and value.kind == "authenticated" and value.verified == true then
              util.notify(provider .. " authentication completed", vim.log.levels.INFO)
            elseif value and value.kind == "stored" then
              util.notify("Environment source stored; account not yet verified",
                vim.log.levels.WARN)
            end
            finish_authentication(callback, value, nil)
          end)
      end)
    end)
  end
  -- P1's credential store is scoped to one explicit named account. Never
  -- silently pick a profile, especially when multiple accounts share a method.
  if runtime.p1_active() and method.profile_id ~= nil then
    -- The exact profile was authorized by the native ACP host. Do not
    -- invite the editor to request a different account.
    request_source(method.profile_id)
  elseif runtime.p1_active() then
    vim.ui.input({
      prompt = "Credential profile ID (letters, digits, _ or -): ",
      default = method.profile_id or "personal",
    }, function(profile_id)
      if generation ~= auth_generation then return end
      if profile_id == nil then
        finish_authentication(callback, nil, {
          kind = "cancelled", message = "authentication cancelled",
        })
      elseif type(profile_id) ~= "string" or profile_id == ""
        or #profile_id > 64 or profile_id:find("[^%w_-]")
      then
        finish_authentication(callback, nil, {
          kind = "invalid_input", message = "Invalid credential profile ID",
        })
      else
        request_source(profile_id)
      end
    end)
  else
    request_source(method.profile_id)
  end
end

local function authentication_label(method)
  local provider = method.provider_name or authentication_provider_id(method) or "provider"
  local connection = method.connection_name or method.connection_label
    or method.connection_id or method.connection
  local name = method.label or method.name or method.method_id or method.id or "authentication"
  local label = provider
  if type(connection) == "string" and connection ~= "" then
    label = label .. " / " .. connection
  end
  label = label .. " / " .. name
  if type(method.profile_id) == "string" and method.profile_id ~= "" then
    label = label .. " [" .. method.profile_id .. "]"
  end
  if method.description ~= nil and method.description ~= "" then
    label = label .. "  ·  " .. method.description
  end
  return label
end

local function choose_authentication_method(methods, prompt, callback)
  if #methods == 0 then
    finish_authentication(callback, nil, { message = "No Phenix authentication method is available" })
    return
  end
  if #methods == 1 then
    authenticate_method(methods[1], callback)
    return
  end
  local picker_generation = auth_generation
  auth_ui.select(methods, {
    prompt = prompt,
    format_item = authentication_label,
  }, function(method)
    if picker_generation ~= auth_generation or method == nil then
      return
    end
    authenticate_method(method, callback)
  end)
end

function M.providers()
  runtime.list_providers(function(result, problem)
    if problem then
      if problem.kind ~= "cancelled" then
        util.notify(problem.message or vim.inspect(problem), vim.log.levels.WARN)
      end
      return
    end
    local providers = result and result.providers or {}
    if #providers == 0 then
      util.notify("No installed Phenix provider registrations", vim.log.levels.INFO)
      return
    end
    auth_ui.select(providers, {
      prompt = "Installed Phenix providers (not authenticated)",
      format_item = function(item) return item.label or item.id end,
    }, function(provider)
      if not provider then return end
      local connections = {}
      for _, connection in ipairs(provider.connections or {}) do
        local methods = {}
        for _, method in ipairs(connection.auth_methods or {}) do
          methods[#methods + 1] = method.label or method.id
        end
        connections[#connections + 1] = (connection.label or connection.id)
          .. " (" .. (#methods == 0 and "no auth" or table.concat(methods, ", ")) .. ")"
      end
      util.notify((provider.label or provider.id)
        .. " — registered, not authenticated: " .. table.concat(connections, "; "),
        vim.log.levels.INFO)
    end)
  end)
end

-- Never infer the account from an authentication method or model name.
-- Revocation requires the exact connection/profile and an explicit confirmation.
function M.revoke_credential(provider_id, connection_id, profile_id, callback)
  local ids = { provider_id, connection_id, profile_id }
  for _, value in ipairs(ids) do
    if type(value) ~= "string" or value == ""
      or #value > 64 or value:find("[^%w_-]")
    then
      finish_authentication(callback, nil, {
        kind = "invalid_input", message = "Invalid provider/connection/profile identity",
      })
      return
    end
  end
  local prompt = "Revoke " .. provider_id .. " / " .. connection_id
    .. " / " .. profile_id .. " credential?"
  auth_ui.select({ "Cancel", "Revoke" }, { prompt = prompt }, function(choice)
    if choice ~= "Revoke" then
      if callback then util.safe_call(callback, nil, {
        kind = "cancelled", message = "Credential revocation cancelled",
      }) end
      return
    end
    runtime.revoke_credential(provider_id, connection_id, profile_id,
      function(value, problem)
        if problem then
          if connection_id == "chatgpt"
            and problem.provider_code == "RemoteRevocationUnconfirmed"
          then
            finish_authentication(callback, nil, {
              kind = "remote_revocation_unconfirmed",
              provider_code = "RemoteRevocationUnconfirmed",
              message = "ChatGPT credentials were removed locally, but remote sign-out "
                .. "could not be confirmed. Disconnect the session in ChatGPT settings.",
            })
          else
            finish_authentication(callback, nil, problem)
          end
          return
        end
        if not value or value.revoked ~= true then
          finish_authentication(callback, nil, { kind = "protocol",
            message = "Phenix did not confirm credential revocation" })
          return
        end
        util.notify("Credential revoked: " .. provider_id .. " / "
          .. connection_id .. " / " .. profile_id, vim.log.levels.INFO)
        finish_authentication(callback, value, nil)
      end)
  end)
end

function M.authenticate()
  if type(runtime.list_authentication_methods) ~= "function" or type(runtime.authenticate) ~= "function" then
    util.notify("The installed Phenix runtime does not expose application authentication yet", vim.log.levels.WARN)
    return
  end
  auth_generation = auth_generation + 1
  cancel_active_oauth()
  local generation = auth_generation
  runtime.list_authentication_methods(function(result, problem)
    if generation ~= auth_generation then
      return
    end
    if problem ~= nil then
      -- Unsupported is a declared runtime capability, not a broken login.
      local level = problem.kind == "unsupported" and vim.log.levels.WARN or vim.log.levels.ERROR
      util.notify(problem.message or vim.inspect(problem), level)
      return
    end
    local methods = vim.deepcopy(result and result.methods or {})
    if #methods == 0 then
      util.notify("No Phenix authentication methods are available", vim.log.levels.WARN)
      return
    end
    -- One offered method needs no provider or method dialog. The actual
    -- credential input/browser challenge still comes from its declared kind.
    if #methods == 1 then
      authenticate_method(methods[1])
      return
    end
    local providers = {}
    local seen = {}
    for _, method in ipairs(methods) do
      local id = authentication_provider_id(method)
      if type(id) == "string" and id ~= "" and not seen[id] then
        seen[id] = true
        providers[#providers + 1] = id
      end
    end
    table.sort(providers)
    if #providers == 0 then
      util.notify("Phenix did not advertise a valid authentication provider", vim.log.levels.ERROR)
      return
    end
    local function choose_provider(provider)
      if generation ~= auth_generation or provider == nil then
        return
      end
      local offered = {}
      local provider_name = provider
      for _, method in ipairs(methods) do
        if authentication_provider_id(method) == provider then
          offered[#offered + 1] = method
          provider_name = method.provider_name or provider_name
        end
      end
      choose_authentication_method(offered, "Authenticate " .. provider_name)
    end
    if #providers == 1 then
      choose_provider(providers[1])
      return
    end
    auth_ui.select(providers, {
      prompt = "Phenix provider",
      format_item = function(provider)
        for _, method in ipairs(methods) do
          if authentication_provider_id(method) == provider then
            return method.provider_name or provider
          end
        end
        return provider
      end,
    }, choose_provider)
  end)
end

local function model_selections(result)
  local models = {}
  local seen = {}
  for _, item in ipairs(result and result.available or {}) do
    if presentation_kind(item) == "model"
      and type(item.provider) == "string"
      and item.provider ~= ""
      and type(item.model) == "string"
      and item.model ~= ""
      and type(item.id) == "string"
      and item.id ~= ""
      -- Runtime management must explicitly affirm each entitlement.
      -- Missing fields are not proof of authorization or credential readiness.
      and item.authorized == true
      and item.selectable == true
      and item.authenticated == true
    then
      -- Same display names from distinct connections/accounts remain separate.
      -- No fallback-derived identity may ever be submitted as a model choice.
      if not seen[item.id] then
        seen[item.id] = true
        table.insert(models, item)
      end
    end
  end
  table.sort(models, function(left, right)
    if left.provider ~= right.provider then
      return left.provider < right.provider
    end
    if left.model ~= right.model then
      return left.model < right.model
    end
    return tostring(left.thinking or "") < tostring(right.thinking or "")
  end)
  return models
end

local function distinct(models, field)
  local values = {}
  local seen = {}
  for _, item in ipairs(models) do
    local value = item[field]
    local key = value == nil and "\0" or tostring(value)
    if not seen[key] then
      seen[key] = true
      table.insert(values, value)
    end
  end
  table.sort(values, function(left, right)
    return tostring(left or "") < tostring(right or "")
  end)
  return values
end

local function filter_models(models, field, value)
  local filtered = {}
  for _, item in ipairs(models) do
    if item[field] == value then
      table.insert(filtered, item)
    end
  end
  return filtered
end

local function selected_marker(result, candidates)
  for _, item in ipairs(candidates) do
    if item.id == result.selected then
      return "✓ "
    end
  end
  return "  "
end

-- The model list has already been filtered using runtime-provided readiness.
-- A failed or revoked selection is rejected by Phenix; the frontend cannot
-- authenticate an unrelated connection and retry a stale model identity.
local function apply_model_selection(item, provider_name)
  runtime.select(item.id, function(result, error)
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local label = (provider_name or item.provider) .. " / " .. item.model
    if item.thinking ~= nil and item.thinking ~= "" then
      label = label .. " / " .. item.thinking
    end
    util.notify(label, vim.log.levels.INFO)
  end)
end

local function choose_thinking(result, models, provider, provider_name, model, generation)
  local variants = filter_models(filter_models(models, "provider", provider), "model", model)
  if #variants == 1 then
    apply_model_selection(variants[1], provider_name)
    return
  end
  vim.ui.select(variants, {
    prompt = "Thinking for " .. model,
    format_item = function(item)
      local label = item.thinking or "default"
      local account = item.profile_name or item.profile_id
      local connection = item.connection_name or item.connection_id
      if type(connection) == "string" and connection ~= "" then
        label = label .. " / " .. connection
      end
      if type(account) == "string" and account ~= "" then
        label = label .. " / " .. account
      end
      return (item.id == result.selected and "✓ " or "  ") .. label
    end,
  }, function(item)
    if generation ~= selection_generation then
      return
    end
    if item ~= nil then
      apply_model_selection(item, provider_name)
    end
  end)
end

local function choose_model(result, models, provider, provider_name, generation)
  local provider_models = filter_models(models, "provider", provider)
  local names = distinct(provider_models, "model")
  vim.ui.select(names, {
    prompt = "Model for " .. provider_name,
    format_item = function(model)
      local variants = filter_models(provider_models, "model", model)
      return selected_marker(result, variants) .. model
    end,
  }, function(model)
    if generation ~= selection_generation then
      return
    end
    if model ~= nil then
      choose_thinking(result, models, provider, provider_name, model, generation)
    end
  end)
end

local function provider_authentication_methods(methods, provider)
  local matches = {}
  for _, method in ipairs(methods or {}) do
    if authentication_provider_id(method) == provider then
      table.insert(matches, method)
    end
  end
  return matches
end

local function provider_display_name(methods, models, provider)
  for _, item in ipairs(models or {}) do
    if item.provider == provider
      and type(item.provider_name) == "string"
      and item.provider_name ~= ""
    then
      return item.provider_name
    end
  end
  for _, method in ipairs(methods or {}) do
    if authentication_provider_id(method) == provider
      and type(method.provider_name) == "string"
      and method.provider_name ~= ""
    then
      return method.provider_name
    end
  end
  return provider
end

local function provider_choices(models, methods)
  local providers = distinct(models, "provider")
  local seen = {}
  for _, provider in ipairs(providers) do
    seen[provider] = true
  end
  for _, method in ipairs(methods or {}) do
    local provider = authentication_provider_id(method)
    if type(provider) == "string" and provider ~= "" and not seen[provider] then
      seen[provider] = true
      table.insert(providers, provider)
    end
  end
  table.sort(providers)
  return providers
end

local function provider_needs_authentication(methods)
  if #methods == 0 then
    return false
  end
  for _, method in ipairs(methods) do
    if method.authenticated == true then
      return false
    end
  end
  return true
end

local function continue_provider_selection(provider, provider_name, generation)
  runtime.list_selections(function(result, error)
    if generation ~= selection_generation then
      return
    end
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local models = filter_models(model_selections(result), "provider", provider)
    if #models == 0 then
      util.notify("Phenix did not discover any models for " .. provider_name, vim.log.levels.WARN)
      return
    end
    choose_model(result, models, provider, provider_name, generation)
  end)
end

function M.choose_selection()
  selection_generation = selection_generation + 1
  local generation = selection_generation

  -- The installed P1 ACP preset currently exposes only a standard model
  -- config option. Prefer provider-first selection once the authoritative
  -- runtime offers auth/catalog operations. Fall back to the ACP picker
  -- only when those management operations are explicitly unsupported.
  runtime.list_authentication_methods(function(auth_result, auth_error)
    if generation ~= selection_generation then
      return
    end
    if auth_error ~= nil then
      if runtime.p1_active() and auth_error.kind == "unsupported" then
        runtime.choose_model(function(selection, problem)
          if generation ~= selection_generation then
            return
          end
          if problem then
            if problem.kind ~= "cancelled" then
              util.notify(problem.message or vim.inspect(problem), vim.log.levels.WARN)
            end
          elseif selection then
            util.notify("Phenix model: " .. tostring(selection.selected), vim.log.levels.INFO)
          end
        end)
        return
      end
      util.notify(vim.inspect(auth_error), vim.log.levels.ERROR)
      return
    end

    runtime.list_selections(function(result, error)
      if generation ~= selection_generation then
        return
      end
      if error ~= nil then
        util.notify(vim.inspect(error), vim.log.levels.ERROR)
        return
      end

      local models = model_selections(result)
      local methods = auth_result and auth_result.methods or {}
      local providers = provider_choices(models, methods)
      if #providers == 0 then
        util.notify("No Phenix model providers are available", vim.log.levels.WARN)
        return
      end

      vim.ui.select(providers, {
        prompt = "Phenix provider",
        format_item = function(provider)
          local candidates = filter_models(models, "provider", provider)
          local auth_methods = provider_authentication_methods(methods, provider)
          local requires_auth = provider_needs_authentication(auth_methods)
          local suffix = requires_auth and "  ·  authentication required" or ""
          return selected_marker(result, candidates)
            .. provider_display_name(auth_methods, candidates, provider) .. suffix
        end,
      }, function(provider)
        if generation ~= selection_generation or provider == nil then
          return
        end
        local candidates = filter_models(models, "provider", provider)
        local auth_methods = provider_authentication_methods(methods, provider)
        local provider_name = provider_display_name(auth_methods, candidates, provider)
        if provider_needs_authentication(auth_methods) then
          choose_authentication_method(
            auth_methods, "Authenticate " .. provider_name, function(_, auth_problem)
              if generation ~= selection_generation then
                return
              end
              if auth_problem ~= nil then
                if auth_problem.kind ~= "cancelled" and auth_problem.kind ~= "pending" then
                  util.notify(vim.inspect(auth_problem), vim.log.levels.ERROR)
                end
                return
              end
              continue_provider_selection(provider, provider_name, generation)
            end
          )
          return
        end
        if #candidates == 0 then
          util.notify("Phenix did not discover any models for " .. provider_name, vim.log.levels.WARN)
          return
        end
        choose_model(result, models, provider, provider_name, generation)
      end)
    end)
  end)
end
return M

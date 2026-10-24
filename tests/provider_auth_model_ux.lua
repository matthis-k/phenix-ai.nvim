-- The standalone Neovim frontend follows the runtime's provider and
-- credential choices. No provider catalog is maintained in this test UI.
local actions = require("phenix_nvim.actions")
local runtime = require("phenix_nvim.runtime")
local util = require("phenix_nvim.util")
local originals = {
  list_authentication_methods = runtime.list_authentication_methods,
  list_providers = runtime.list_providers,
  authenticate = runtime.authenticate,
  list_selections = runtime.list_selections,
  select = runtime.select,
  p1_active = runtime.p1_active,
  ui_select = vim.ui.select,
  input_secret = util.input_secret,
  notify = util.notify,
  ui_open = vim.ui.open,
}
local methods = {}
local calls = {}
local chosen_items = {}
local prompts = {}
local rendered_labels = {}
local selected_model

runtime.p1_active = function() return false end
runtime.list_authentication_methods = function(cb)
  cb({ methods = vim.deepcopy(methods) }, nil)
end
runtime.list_providers = function(cb)
  local providers, by_id = {}, {}
  for _, method in ipairs(methods) do
    local id = method.provider_id or method.provider
    if type(id) == "string" and id ~= "" and not by_id[id] then
      local item = { id = id, label = method.provider_name or id, connections = {} }
      by_id[id] = item
      providers[#providers + 1] = item
    end
  end
  cb({ revision = 1, providers = providers }, nil)
end
runtime.authenticate = function(identity, secret, cb)
  calls[#calls + 1] = { identity = vim.deepcopy(identity), secret = secret }
  cb({ kind = "authenticated" }, nil)
end
util.input_secret = function(_, cb) cb("fake-key-from-ui", nil) end
util.notify = function() end
vim.ui.select = function(items, opts, cb)
  prompts[#prompts + 1] = opts.prompt
  chosen_items[#chosen_items + 1] = vim.deepcopy(items)
  local labels = {}
  for _, item in ipairs(items) do
    labels[#labels + 1] = opts.format_item and opts.format_item(item) or tostring(item)
  end
  rendered_labels[#rendered_labels + 1] = labels
  cb(items[1])
end

local function reset()
  calls, chosen_items, prompts, rendered_labels = {}, {}, {}, {}
end

methods = {
  { provider_id = "openai", connection_id = "api", provider_name = "OpenAI", method_id = "api", kind = "ApiKey", label = "API key" },
  { provider_id = "openai", connection_id = "subscription", provider_name = "OpenAI", method_id = "oauth", kind = "OAuthAuthorizationCode", label = "ChatGPT" },
  { provider_id = "anthropic", connection_id = "api", provider_name = "Anthropic", method_id = "anthropic-key", kind = "ApiKey", label = "API key" },
}
actions.authenticate()
assert(#prompts == 2, "provider selection and API-key source only")
assert(prompts[1] == "Phenix provider (declared, not authenticated)")
assert(#chosen_items[1] == 2 and chosen_items[1][1].id == "anthropic")
assert(chosen_items[2][1] == "Enter API key",
  "API-key source picker must not be confused with auth method selection")
assert(#calls == 1 and calls[1].identity.provider_id == "anthropic"
  and calls[1].identity.connection_id == "api"
  and calls[1].identity.method_id == "anthropic-key")
assert(calls[1].secret == "fake-key-from-ui",
  "canonical ApiKey kind must request a secret, not launch OAuth")
assert(calls[1].secret == "fake-key-from-ui")

reset()
methods = {
  { provider = "openai", connection_id = "api", provider_name = "OpenAI", id = "api", kind = "api_token", name = "API key" },
  { provider = "openai", connection_id = "subscription", provider_name = "OpenAI", id = "oauth", kind = "oauth", name = "ChatGPT" },
}
actions.authenticate()
assert(#prompts == 3 and prompts[1] == "Phenix provider (declared, not authenticated)"
  and prompts[2] == "Authenticate OpenAI",
  "even one declared provider must be shown before selecting its methods")
assert(#chosen_items[2] == 2)
assert(vim.tbl_contains(vim.tbl_map(function(item)
  return item.connection_id
end, chosen_items[2]), "subscription"), "OAuth connection must remain distinct")
assert(calls[1].identity.method_id == "api"
  and calls[1].identity.connection_id == "api")

-- Two accounts may advertise the exact same method ID. Submitting only
-- the method string would authenticate the wrong connection.
reset()
methods = {
  { provider = "openai", connection_id = "personal", id = "api-key",
    kind = "api_token", name = "Personal key" },
  { provider = "openai", connection_id = "work", id = "api-key",
    kind = "api_token", name = "Work key" },
}
actions.authenticate()
assert(#chosen_items == 3 and #chosen_items[2] == 2,
  "same-method different-connection entries must both remain selectable")
assert(chosen_items[2][1].connection_id ~= chosen_items[2][2].connection_id)
assert(rendered_labels[2][1]:find("personal", 1, true)
  and rendered_labels[2][2]:find("work", 1, true),
  "credential choices must show their different connection identities")
assert(#calls == 1 and calls[1].identity.connection_id == "personal"
  and calls[1].identity.method_id == "api-key")

-- Browser authorization must be initiated only once. ProviderAuth::begin is
-- not a polling API; its separate status mechanism is not yet installed.
reset()
local opened
vim.ui.open = function(uri) opened = uri; return true end
runtime.authenticate = function(identity, secret, cb)
  calls[#calls + 1] = { identity = vim.deepcopy(identity), secret = secret }
  cb({ kind = "external", uri = "https://example.test/authorize",
    attempt_id = "attempt-1" }, nil)
end
methods = { { provider = "openai", connection_id = "subscription",
  id = "oauth", kind = "OAuthAuthorizationCode", name = "Subscription" } }
actions.authenticate()
assert(opened == "https://example.test/authorize")
assert(#calls == 1, "OAuth challenge was restarted while awaiting completion")

-- An installed provider's challenge is data, not permission to ask the OS
-- to open arbitrary URI handlers.
local blocked_notices = {}
util.notify = function(message, level)
  blocked_notices[#blocked_notices + 1] = { message = message, level = level }
end
for _, unsafe_uri in ipairs({
  "file:///tmp/phishing",
  "javascript:alert(1)",
  "http://example.test/authorize",
  "https://user@example.test/authorize",
  "https://example.test/\\evil",
}) do
  reset()
  opened = nil
  blocked_notices = {}
  runtime.authenticate = function(identity, secret, cb)
    calls[#calls + 1] = { identity = vim.deepcopy(identity), secret = secret }
    cb({ kind = "external", url = unsafe_uri, attempt_id = "attempt-untrusted" }, nil)
  end
  actions.authenticate()
  assert(opened == nil, "untrusted OAuth URI was launched: " .. unsafe_uri)
  assert(#calls == 1 and #blocked_notices == 1,
    "one denied authorization should produce one clear error")
  assert(blocked_notices[1].message:find("authorization URL", 1, true),
    "OAuth URI denial must be actionable")
end
util.notify = function() end
runtime.authenticate = function(identity, secret, cb)
  calls[#calls + 1] = { identity = vim.deepcopy(identity), secret = secret }
  cb({ kind = "authenticated" }, nil)
end
vim.ui.open = originals.ui_open

-- A single canonical provider_id/method_id tuple starts directly, without
-- selecting a provider first or surfacing the legacy method format.
reset()
methods = { { provider_id = "openrouter", connection_id = "api",
  method_id = "api-key", kind = "ApiKey", label = "API key" } }
actions.authenticate()
assert(#prompts == 2 and #chosen_items == 2
  and prompts[1] == "Phenix provider (declared, not authenticated)"
  and prompts[2]:find("API key source", 1, true),
  "one method still displays its declared provider before choosing API source")
assert(#calls == 1 and calls[1].identity.provider_id == "openrouter"
  and calls[1].identity.method_id == "api-key")
assert(calls[1].secret == "fake-key-from-ui")

reset()
methods = {}
actions.authenticate()
assert(#calls == 0 and #prompts == 0, "no advertised methods must not authenticate")

-- Models with the same display name but different account/connection identities
-- are separate, runtime-owned selections. No implicit account switching.
methods = {}
runtime.list_selections = function(cb)
  cb({ selected = "account-one", available = {
    { id = "account-one", provider = "openai", model = "gpt-example",
      thinking = "medium", connection_id = "api", profile_id = "personal",
      presentation = { kind = "model" }, authenticated = true,
      authorized = true, selectable = true },
    { id = "account-two", provider = "openai", model = "gpt-example",
      thinking = "medium", connection_id = "api", profile_id = "work",
      presentation = { kind = "model" }, authenticated = true,
      authorized = true, selectable = true },
  } }, nil)
end
runtime.select = function(id, cb)
  selected_model = id
  cb({ selected = id }, nil)
end
reset()
actions.choose_selection()
assert(#chosen_items == 3, "provider, model and distinct account variants must appear")
assert(#chosen_items[3] == 2, "different account variants must not be collapsed")
assert(selected_model == "account-one", "picker must submit the selected runtime-owned ID")
assert(
  prompts[3] == "Thinking for gpt-example",
  "account variants must retain their exact model ID"
)

-- Runtime-denied, unavailable and unauthenticated models must never be
-- offered as selectable choices. An auth-only provider remains visible so the
-- user can authenticate first and fetch its freshly authorized model catalog.
local saved_list_selections = runtime.list_selections
reset()
methods = {
  { provider_id = "z-auth", connection_id = "api", method_id = "key",
    kind = "ApiKey", authenticated = false },
}
runtime.list_selections = function(cb)
  cb({ selected = "ready", available = {
    { id = "ready", provider = "a-ready", model = "usable",
      presentation = { kind = "model" }, authenticated = true,
      authorized = true, selectable = true },
    { id = "denied", provider = "a-ready", model = "denied",
      presentation = { kind = "model" }, authorized = false },
    { id = "unavailable", provider = "a-ready", model = "unavailable",
      presentation = { kind = "model" }, selectable = false },
    { id = "needs-auth", provider = "a-ready", model = "needs-auth",
      presentation = { kind = "model" }, authenticated = false,
      authorized = true, selectable = true },
    { id = "unknown-authority", provider = "a-ready", model = "unknown-authority",
      presentation = { kind = "model" }, authenticated = true, selectable = true },
    { id = "unknown-readiness", provider = "a-ready", model = "unknown-readiness",
      presentation = { kind = "model" }, authorized = true, selectable = true },
    { id = "unknown-selectability", provider = "a-ready", model = "unknown-selectability",
      presentation = { kind = "model" }, authorized = true, authenticated = true },
    { provider = "a-ready", model = "missing-selection-id",
      presentation = { kind = "model" }, authorized = true,
      selectable = true, authenticated = true },
    { id = "", provider = "a-ready", model = "empty-selection-id",
      presentation = { kind = "model" }, authorized = true,
      selectable = true, authenticated = true },
  } }, nil)
end
selected_model = nil
actions.choose_selection()
assert(#chosen_items[1] == 2 and chosen_items[1][1] == "a-ready"
  and chosen_items[1][2] == "z-auth",
  "providers needing authentication must remain available for onboarding")
assert(#chosen_items[2] == 1 and chosen_items[2][1] == "usable",
  "unusable runtime model entries must not be offered to the picker")
assert(selected_model == "ready",
  "only a currently usable runtime model identity may be submitted")

runtime.list_selections = saved_list_selections
methods = {}

-- ACP P1 advertises exact session model IDs and display names but never
-- provides provider/account/readiness metadata on those options. Even when
-- the combined auth runtime advertises methods, :Phenix model must use the
-- validated ACP session picker, not the synthetic application picker.
runtime.p1_active = function() return true end
local original_choose_model = runtime.choose_model
local original_list_methods = runtime.list_authentication_methods
local original_list_selections = runtime.list_selections
local chosen_from_acp, preflights = 0, 0
runtime.choose_model = function(cb)
  chosen_from_acp = chosen_from_acp + 1
  cb({ selected = "phenix.native-model@1:opaque-account-bound-choice" }, nil)
end
runtime.list_authentication_methods = function()
  preflights = preflights + 1
  error("P1 model picker must not preflight auth methods instead of ACP models")
end
runtime.list_selections = function()
  error("P1 must not synthesize provider readiness from ACP model labels")
end
reset()
actions.choose_selection()
assert(chosen_from_acp == 1 and preflights == 0 and #prompts == 0,
  "combined authenticated P1 model selection did not use ACP session picker")

-- A runtime without an active session must refuse the picker cleanly.
local missing_session_notices = {}
local previous_notify = util.notify
util.notify = function(message, level)
  missing_session_notices[#missing_session_notices + 1] = { message = message, level = level }
end
runtime.choose_model = function(cb)
  cb(nil, { kind = "not_found", message = "Create a Phenix session with :Phenix new before choosing a model" })
end
actions.choose_selection()
assert(#missing_session_notices == 1
  and missing_session_notices[1].message:find(":Phenix new", 1, true),
  "P1 session prerequisite must be actionable, not a hidden model picker")
util.notify = previous_notify
runtime.choose_model = original_choose_model
runtime.list_authentication_methods = function(cb)
  cb(nil, { kind = "unsupported", message = "auth not installed" })
end
runtime.list_selections = original_list_selections
methods = { { provider_id = "openai", connection_id = "api",
  method_id = "key", kind = "ApiKey" } }

-- The installed Basic preset advertises auth as unsupported. The command
-- should report a missing capability, not a failed login or credential prompt.
local notices = {}
util.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end
reset()
actions.authenticate()
assert(#notices == 1 and notices[1].level == vim.log.levels.WARN
  and notices[1].message:find("auth", 1, true),
  "unsupported runtime authentication must be a clear warning")
assert(#calls == 0 and #prompts == 1,
  "unsupported credential methods must not request a secret")

-- With the P1 credential extension, account selection is explicit and
-- a stored key is never presented as provider-verified login.
local original_ui_input = vim.ui.input
local profile_prompt
vim.ui.input = function(options, callback)
  profile_prompt = options.prompt
  callback("personal")
end
methods = { { provider_id = "openai", connection_id = "api",
  method_id = "api-key", kind = "ApiKey", label = "API key" } }
runtime.list_authentication_methods = function(cb)
  cb({ methods = vim.deepcopy(methods) }, nil)
end
runtime.authenticate = function(identity, secret, cb)
  calls[#calls + 1] = { identity = vim.deepcopy(identity), secret = secret }
  cb({ kind = "stored", profile_id = identity.profile_id, verified = false }, nil)
end
reset()
notices = {}
actions.authenticate()
assert(profile_prompt and profile_prompt:find("Credential profile", 1, true))
assert(#calls == 1 and calls[1].identity.profile_id == "personal"
  and calls[1].identity.provider_id == "openai"
  and calls[1].identity.connection_id == "api")
assert(calls[1].identity.kind == "ApiKey")
assert(#notices == 1 and notices[1].level == vim.log.levels.INFO
  and notices[1].message:find("not yet verified", 1, true),
  "credential storage must not be announced as an authenticated provider")

vim.ui.input = function(_, callback) callback("invalid/profile") end
reset()
notices = {}
actions.authenticate()
assert(#calls == 0, "invalid profile must never reach credential store")
assert(#notices == 1 and notices[1].level == vim.log.levels.ERROR)
vim.ui.input = original_ui_input

for key, value in pairs(originals) do
  if key == "ui_select" then vim.ui.select = value
  elseif key == "ui_open" then vim.ui.open = value
  elseif key == "input_secret" then util.input_secret = value
  elseif key == "notify" then util.notify = value
  else runtime[key] = value end
end

print("Provider-first authentication and account-specific model UI accepted")

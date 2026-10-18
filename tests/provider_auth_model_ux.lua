-- The standalone Neovim frontend follows the runtime's provider and
-- credential choices. No provider catalog is maintained in this test UI.
local actions = require("phenix_nvim.actions")
local runtime = require("phenix_nvim.runtime")
local util = require("phenix_nvim.util")
local originals = {
  list_authentication_methods = runtime.list_authentication_methods,
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
assert(#prompts == 1, "single-method provider skips method picker")
assert(prompts[1] == "Phenix provider")
assert(#chosen_items[1] == 2 and chosen_items[1][1] == "anthropic")
assert(chosen_items[2] == nil, "one-method provider should not show a method selector")
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
assert(#prompts == 1 and prompts[1] == "Authenticate OpenAI",
  "single-provider multiple methods must skip redundant provider picker")
assert(#chosen_items[1] == 2)
assert(vim.tbl_contains(vim.tbl_map(function(item)
  return item.connection_id
end, chosen_items[1]), "subscription"), "OAuth connection must remain distinct")
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
assert(#chosen_items == 1 and #chosen_items[1] == 2,
  "same-method different-connection entries must both remain selectable")
assert(chosen_items[1][1].connection_id ~= chosen_items[1][2].connection_id)
assert(rendered_labels[1][1]:find("personal", 1, true)
  and rendered_labels[1][2]:find("work", 1, true),
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
assert(#prompts == 0 and #chosen_items == 0,
  "one available method must not show an unnecessary chooser")
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
      presentation = { kind = "model" }, authenticated = true },
    { id = "account-two", provider = "openai", model = "gpt-example",
      thinking = "medium", connection_id = "api", profile_id = "work",
      presentation = { kind = "model" }, authenticated = true },
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
      presentation = { kind = "model" }, authenticated = false },
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

-- The installed P1 frontend must adopt provider-first selection once
-- runtime management is available. Before that, retain the standard ACP
-- picker when authentication methods are explicitly unsupported.
runtime.p1_active = function() return true end
reset()
selected_model = nil
actions.choose_selection()
assert(selected_model == "account-one" and #prompts == 3,
  "P1 management-capable runtime bypassed provider-first model choice")

local fallback = 0
runtime.list_authentication_methods = function(cb)
  cb(nil, { kind = "unsupported", message = "auth not installed" })
end
local original_choose_model = runtime.choose_model
runtime.choose_model = function(cb)
  fallback = fallback + 1
  cb({ selected = "phenix.model.scripted" }, nil)
end
reset()
actions.choose_selection()
assert(fallback == 1 and #prompts == 0,
  "P1 fallback must only use the ACP model picker when auth is unsupported")
runtime.choose_model = original_choose_model

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
assert(#calls == 0 and #prompts == 0,
  "unsupported runtime authentication must not request a credential")

for key, value in pairs(originals) do
  if key == "ui_select" then vim.ui.select = value
  elseif key == "ui_open" then vim.ui.open = value
  elseif key == "input_secret" then util.input_secret = value
  elseif key == "notify" then util.notify = value
  else runtime[key] = value end
end

print("Provider-first authentication and account-specific model UI accepted")

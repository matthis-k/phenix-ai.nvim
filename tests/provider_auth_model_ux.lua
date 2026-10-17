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
  cb(items[1])
end

local function reset()
  calls, chosen_items, prompts = {}, {}, {}
end

methods = {
  { provider = "openai", connection_id = "api", provider_name = "OpenAI", id = "api", kind = "api_token", name = "API key" },
  { provider = "openai", connection_id = "subscription", provider_name = "OpenAI", id = "oauth", kind = "oauth", name = "ChatGPT" },
  { provider = "anthropic", connection_id = "api", provider_name = "Anthropic", id = "anthropic-key", kind = "api_token", name = "API key" },
}
actions.authenticate()
assert(#prompts == 1, "single-method provider skips method picker")
assert(prompts[1] == "Phenix provider")
assert(#chosen_items[1] == 2 and chosen_items[1][1] == "anthropic")
assert(chosen_items[2] == nil, "one-method provider should not show a method selector")
assert(#calls == 1 and calls[1].identity.provider_id == "anthropic"
  and calls[1].identity.connection_id == "api"
  and calls[1].identity.method_id == "anthropic-key")
assert(calls[1].secret == "fake-key-from-ui")

reset()
methods = {
  { provider = "openai", connection_id = "api", provider_name = "OpenAI", id = "api", kind = "api_token", name = "API key" },
  { provider = "openai", connection_id = "subscription", provider_name = "OpenAI", id = "oauth", kind = "oauth", name = "ChatGPT" },
}
actions.authenticate()
assert(#prompts == 2, "multiple methods must show the second-level method picker")
assert(#chosen_items[2] == 2)
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
assert(#chosen_items == 2 and #chosen_items[2] == 2,
  "same-method different-connection entries must both remain selectable")
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
  id = "oauth", kind = "oauth", name = "Subscription" } }
actions.authenticate()
assert(opened == "https://example.test/authorize")
assert(#calls == 1, "OAuth challenge was restarted while awaiting completion")
runtime.authenticate = function(identity, secret, cb)
  calls[#calls + 1] = { identity = vim.deepcopy(identity), secret = secret }
  cb({ kind = "authenticated" }, nil)
end
vim.ui.open = originals.ui_open

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

for key, value in pairs(originals) do
  if key == "ui_select" then vim.ui.select = value
  elseif key == "ui_open" then vim.ui.open = value
  elseif key == "input_secret" then util.input_secret = value
  elseif key == "notify" then util.notify = value
  else runtime[key] = value end
end

print("Provider-first authentication and account-specific model UI accepted")

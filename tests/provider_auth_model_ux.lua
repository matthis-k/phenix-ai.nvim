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
runtime.authenticate = function(id, secret, cb)
  calls[#calls + 1] = { id = id, secret = secret }
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
  { provider = "openai", provider_name = "OpenAI", id = "api", kind = "api_token", name = "API key" },
  { provider = "openai", provider_name = "OpenAI", id = "oauth", kind = "oauth", name = "ChatGPT" },
  { provider = "anthropic", provider_name = "Anthropic", id = "anthropic-key", kind = "api_token", name = "API key" },
}
actions.authenticate()
assert(#prompts == 1, "single-method provider skips method picker")
assert(prompts[1] == "Phenix provider")
assert(#chosen_items[1] == 2 and chosen_items[1][1] == "anthropic")
assert(chosen_items[2] == nil, "one-method provider should not show a method selector")
assert(#calls == 1 and calls[1].id == "anthropic-key")
assert(calls[1].secret == "fake-key-from-ui")

reset()
methods = {
  { provider = "openai", provider_name = "OpenAI", id = "api", kind = "api_token", name = "API key" },
  { provider = "openai", provider_name = "OpenAI", id = "oauth", kind = "oauth", name = "ChatGPT" },
}
actions.authenticate()
assert(#prompts == 2, "multiple methods must show the second-level method picker")
assert(#chosen_items[2] == 2)
assert(calls[1].id == "api")

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

for key, value in pairs(originals) do
  if key == "ui_select" then vim.ui.select = value
  elseif key == "input_secret" then util.input_secret = value
  elseif key == "notify" then util.notify = value
  else runtime[key] = value end
end

print("Provider-first authentication and account-specific model UI accepted")

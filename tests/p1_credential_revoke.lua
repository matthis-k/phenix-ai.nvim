-- Named API-key revocation must not use a frontend-owned credential list.
-- Only the selected provider/connection/profile is forwarded to ACP.
local runtime = require("phenix_nvim.runtime")
local commands = require("phenix_nvim.commands")
local util = require("phenix_nvim.util")

local old_revoke = runtime.revoke_credential
local old_select = vim.ui.select
local old_notify = util.notify
local calls, notices = {}, {}
local decision = "Cancel"
local options_seen

runtime.revoke_credential = function(provider, connection, profile, callback)
  calls[#calls + 1] = { provider, connection, profile }
  callback({ revoked = true, authenticated = false }, nil)
end
vim.ui.select = function(options, config, callback)
  options_seen = { options = options, prompt = config.prompt }
  callback(decision)
end
util.notify = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end
local function command(...)
  commands.execute({ fargs = { ... } })
end

-- No method is invoked without explicit user confirmation.
command("auth", "revoke", "openai", "api", "personal")
assert(#calls == 0 and #options_seen.options == 2)
assert(options_seen.prompt:find("openai / api / personal", 1, true))
assert(#notices == 0, "cancelled revocation must be silent")

decision = "Revoke"
notices = {}
command("auth", "revoke", "openai", "api", "personal")
assert(#calls == 1)
assert(vim.deep_equal(calls[1], { "openai", "api", "personal" }))
assert(#notices == 1 and notices[1].level == vim.log.levels.INFO
  and notices[1].message:find("Credential revoked", 1, true))

local before = #calls
command("auth", "revoke", "openai", "api")
command("auth", "revoke", "openai", "api", "personal", "extra")
command("auth", "revoke", "openai", "api", "../other")
assert(#calls == before, "invalid or missing profile must never revoke")

local completions = commands.complete("", "Phenix auth ", #"Phenix auth ")
assert(vim.tbl_contains(completions, "revoke"))

runtime.revoke_credential = function(_, _, _, callback)
  callback(nil, { kind = "denied", message = "Not authorized" })
end
notices = {}
command("auth", "revoke", "openai", "api", "work")
assert(#notices == 1 and notices[1].level == vim.log.levels.ERROR)
assert(not notices[1].message:find("revoked", 1, true))

-- The provider explicitly confirms local credential removal but could
-- not confirm remote token revocation. Never display "revoked" as success.
runtime.revoke_credential = function(_, _, _, callback)
  callback(nil, {
    kind = "transport", provider_code = "RemoteRevocationUnconfirmed",
    message = "Provider error body must not enter editor notifications",
  })
end
notices = {}
command("auth", "revoke", "openai", "chatgpt", "personal")
assert(#notices == 1, vim.inspect(notices))
assert(notices[1].level == vim.log.levels.WARN)
assert(notices[1].message:find("removed locally", 1, true))
assert(notices[1].message:find("remote sign%-out"))
assert(notices[1].message:find("ChatGPT settings", 1, true))
assert(not notices[1].message:find("Provider error body", 1, true))
assert(not notices[1].message:find("Credential revoked:", 1, true))

runtime.revoke_credential = old_revoke
vim.ui.select = old_select
util.notify = old_notify
print("Exact-profile credential revocation requires confirmation and authority")

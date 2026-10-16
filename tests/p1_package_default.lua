-- Verify the installed Basic package is self-contained and selects P1.
-- This runs against the built Vim plugin, not the working-tree source.
local config = require("phenix_nvim.config")
local defaults = config.get()
assert(defaults.backend == "p1", "packaged Basic must select the P1 backend")
assert(type(defaults.command) == "string"
  and defaults.command:match("/bin/phenix%-basic%-acp$"),
  "packaged Basic must launch its pinned ACP product")
local front = require("phenix_nvim")
front.setup({ auto_connect = false })
local configured = config.get()
assert(configured.backend == "p1" and configured.command == defaults.command,
  "normal setup must not replace the packaged ACP executable with PATH lookup")
local runtime = require("phenix_nvim.runtime")
assert(runtime.p1_active(), "packaged Basic must never select the legacy runtime")
print("Installed P1 Neovim package defaults passed")

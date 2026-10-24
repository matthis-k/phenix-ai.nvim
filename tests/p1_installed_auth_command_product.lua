-- Integrated auth command acceptance test.
local M = require("phenix_nvim.commands")
assert(type(M.execute) == "function")

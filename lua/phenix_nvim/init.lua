local actions = require("phenix_nvim.actions")
local compose = require("phenix_nvim.compose.buffer")
local config = require("phenix_nvim.config")
local runtime = require("phenix_nvim.runtime")
local state = require("phenix_nvim.state")
local status = require("phenix_nvim.status")
local transcript = require("phenix_nvim.transcript.controller")

local M = {
  actions = actions,
  status = status,
}

function M.setup(options)
  local resolved = config.setup(options)
  runtime.configure(resolved)
  compose.ensure(state.compose)
  transcript.start()
  if resolved.auto_connect then
    runtime.connect()
  end
  return M
end

M.connect = runtime.connect
M.disconnect = runtime.disconnect
M.reference = actions.reference
M.reference_at = actions.reference_at
M.reference_picker = actions.reference_picker
M.send = actions.send
M.toggle = actions.toggle
M.cancel = actions.cancel
M.new_session = actions.new_session
M.close_session = actions.close_session
M.choose_session = actions.choose_session
M.authenticate = actions.authenticate
M.choose_selection = actions.choose_selection
M.attach_image = actions.attach_image

return M

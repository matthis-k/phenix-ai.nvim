local compose_model = require("phenix_nvim.compose.model")

local default_compose = compose_model.new()

local M = {
  compose = default_compose,
  remembered_compose_cursor = { 1, 0 },
}

function M.new_surface()
  return {
    session_id = nil,
    compose = compose_model.new(),
    compose_cursor = { 1, 0 },
  }
end

return M

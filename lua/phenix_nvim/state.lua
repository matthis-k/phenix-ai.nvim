local compose_model = require("phenix_nvim.compose.model")

local M = {
  compose = compose_model.new(),
  remembered_compose_cursor = { 1, 0 },
}

return M

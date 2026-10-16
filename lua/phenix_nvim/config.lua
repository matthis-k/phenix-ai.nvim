-- Neovim owns presentation and connection parameters; Phenix owns
-- model selection, storage, permissions, tool admission and runtime policy.
local M = {}
local defaults = {
  backend = "p1",
  command = "phenix-basic-acp",
  args = {},
  auto_connect = false,
  side = "right",
  width = 0.4,
  compose_height = 8,
}
local current = vim.deepcopy(defaults)

function M.setup(options)
  options = options or {}
  if options.backend ~= nil and options.backend ~= "p1" then
    error("phenix-ai.nvim supports only the P1 runtime backend")
  end
  for _, key in ipairs({
    "env", "state_directory", "log_directory", "log_depth",
    "poll_interval_ms", "poll_budget",
    "connect_timeout_ms", "request_timeout_ms", "prompt_timeout_ms",
  }) do
    if options[key] ~= nil then
      error("phenix-ai.nvim " .. key .. " is runtime-owned or retired in P1")
    end
  end
  local resolved = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options)
  if type(resolved.command) ~= "string" or resolved.command == "" then
    error("phenix-ai.nvim command must be a non-empty ACP executable")
  end
  if type(resolved.args) ~= "table" or not vim.islist(resolved.args) then
    error("phenix-ai.nvim args must be an argument list")
  end
  for _, arg in ipairs(resolved.args) do
    if type(arg) ~= "string" then
      error("phenix-ai.nvim ACP arguments must be strings")
    end
  end
  if type(resolved.width) ~= "number" or resolved.width ~= resolved.width
    or resolved.width <= 0 or resolved.width == math.huge then
    error("phenix-ai.nvim width must be a finite positive number")
  end
  current = resolved
  return M.get()
end

function M.get()
  return vim.deepcopy(current)
end

return M

local M = {}

local defaults = {
  command = "phenix-acp",
  args = {},
  env = {},
  log_directory = vim.fn.stdpath("state") .. "/phenix",
  log_depth = "reference",
  auto_connect = false,
  poll_interval_ms = 25,
  poll_budget = 32,
  side = "right",
  width = 56,
  compose_height = 8,
}

local current = vim.deepcopy(defaults)

function M.setup(options)
  current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  return M.get()
end

function M.get()
  return vim.deepcopy(current)
end

function M.runtime_env(config)
  local resolved = vim.tbl_deep_extend("force", vim.deepcopy(current), config or {})
  local environment = vim.deepcopy(resolved.env or {})
  local log_directory = resolved.log_directory
  if log_directory ~= false and log_directory ~= nil then
    if type(log_directory) ~= "string" or log_directory == "" then
      error("phenix-ai.nvim log_directory must be a non-empty path or false")
    end
    local explicit_log = environment.PHENIX_LOG ~= nil
      or environment.PHENIX_DEBUG_LOG ~= nil
      or vim.env.PHENIX_LOG ~= nil
      or vim.env.PHENIX_DEBUG_LOG ~= nil
    if not explicit_log then
      environment.PHENIX_LOG = "dir:" .. log_directory
    end
  end

  local log_depth = resolved.log_depth
  if log_depth ~= false and log_depth ~= nil then
    if log_depth ~= "summary" and log_depth ~= "reference" and log_depth ~= "inline" then
      error("phenix-ai.nvim log_depth must be summary, reference, inline, or false")
    end
    local explicit_depth = environment.PHENIX_LOG_DEPTH ~= nil or vim.env.PHENIX_LOG_DEPTH ~= nil
    if not explicit_depth then
      environment.PHENIX_LOG_DEPTH = log_depth
    end
  end
  return environment
end

return M

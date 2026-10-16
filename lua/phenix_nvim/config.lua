local M = {}

local defaults = {
  backend = "legacy",
  command = "phenix",
  args = { "--mode", "acp" },
  env = {},
  state_directory = nil,
  log_directory = vim.fn.stdpath("state") .. "/phenix",
  log_depth = "reference",
  auto_connect = false,
  poll_interval_ms = 25,
  poll_budget = 32,
  side = "right",
  width = 0.4,
  compose_height = 8,
}

local current = vim.deepcopy(defaults)

local function non_empty(value)
  return type(value) == "string" and value ~= ""
end

local function resolved_config(config)
  return vim.tbl_deep_extend("force", vim.deepcopy(current), config or {})
end

function M.setup(options)
  local resolved = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  if resolved.backend ~= "legacy" and resolved.backend ~= "p1" then
    error("phenix-ai.nvim backend must be legacy or p1")
  end
  if resolved.backend == "p1" then
    local overrides = options or {}
    -- P1's process composition and storage are configured inside Phenix.
    for _, key in ipairs({ "env", "state_directory", "log_directory", "log_depth" }) do
      if overrides[key] ~= nil then
        error("phenix-ai.nvim " .. key .. " configures Phenix; set it in the runtime")
      end
    end
    if overrides.command == nil then
      resolved.command = defaults.backend == "p1" and defaults.command or "phenix-basic-acp"
    end
    if overrides.args == nil then resolved.args = {} end
  end
  for _, key in ipairs({ "connect_timeout_ms", "request_timeout_ms", "prompt_timeout_ms" }) do
    if options ~= nil and options[key] ~= nil then
      error("phenix-ai.nvim " .. key .. " is not supported; configure execution timeouts and limits in Phenix")
    end
  end
  if type(resolved.width) ~= "number"
    or resolved.width ~= resolved.width
    or resolved.width <= 0
    or resolved.width == math.huge
  then
    error("phenix-ai.nvim width must be a finite positive number")
  end
  current = resolved
  return M.get()
end

function M.get()
  return vim.deepcopy(current)
end

function M.runtime_env(config)
  local resolved = resolved_config(config)
  local environment = vim.deepcopy(resolved.env or {})

  local state_directory = resolved.state_directory
  if state_directory ~= false and state_directory ~= nil then
    if not non_empty(state_directory) then
      error("phenix-ai.nvim state_directory must be a non-empty path or false")
    end
    if environment.PHENIX_STATE_DIR == nil and vim.env.PHENIX_STATE_DIR == nil then
      environment.PHENIX_STATE_DIR = state_directory
    end
  end

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

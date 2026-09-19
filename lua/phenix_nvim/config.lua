local M = {}

local defaults = {
  command = "phenix-acp",
  args = {},
  env = {},
  selection = "auto",
  api_key_providers = {
    {
      id = "openai-api",
      name = "OpenAI API key",
      description = "Use OpenAI API billing instead of ChatGPT OAuth",
      env = "OPENAI_API_KEY",
      selection = "router.openai-api",
    },
    {
      id = "opencode-go",
      name = "OpenCode Go API key",
      description = "Use the OpenCode Go provider",
      env = "OPENCODE_API_KEY",
      selection = "router.opencode-go",
    },
  },
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

local function non_empty(value)
  return type(value) == "string" and value ~= ""
end

local function resolved_config(config)
  return vim.tbl_deep_extend("force", vim.deepcopy(current), config or {})
end

local function configured_environment(resolved, name)
  local configured = resolved.env and resolved.env[name]
  if non_empty(configured) then
    return true
  end
  return non_empty(vim.env[name])
end

function M.setup(options)
  current = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  return M.get()
end

function M.get()
  return vim.deepcopy(current)
end

function M.api_key_providers(config)
  local resolved = resolved_config(config)
  return vim.deepcopy(resolved.api_key_providers or {})
end

function M.has_api_key(provider, config)
  if type(provider) ~= "table" or not non_empty(provider.env) then
    return false
  end
  return configured_environment(resolved_config(config), provider.env)
end

function M.preferred_selection(config)
  local resolved = resolved_config(config)
  local selection = resolved.selection
  if selection == false or selection == nil then
    return nil
  end
  if selection ~= "auto" then
    if not non_empty(selection) then
      error("phenix-ai.nvim selection must be auto, a non-empty routing selection, or false")
    end
    return selection
  end
  for _, provider in ipairs(resolved.api_key_providers or {}) do
    if non_empty(provider.selection) and M.has_api_key(provider, resolved) then
      return provider.selection
    end
  end
  return "router.chatgpt-plus"
end

function M.runtime_env(config)
  local resolved = resolved_config(config)
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

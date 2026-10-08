local M = {}

local function inspect(value)
  if value == nil then
    return nil
  end
  return type(value) == "string" and value or vim.inspect(value)
end

local function lines(value)
  return vim.split(tostring(value or ""), "\n", { plain = true })
end

function M.status(state)
  if state == "completed" then
    return "completed", "PhenixToolCompleted"
  elseif state == "failed" then
    return "failed", "PhenixToolFailed"
  end
  return "running", "PhenixToolRunning"
end

function M.header(node, width)
  local status = M.status(node.state)
  local name = tostring(node.callable_id or "unknown")
  local prefix = "Tool  "
  local suffix = "  " .. status
  width = math.max(20, width or 80)
  local available = math.max(1, width - vim.fn.strdisplaywidth(prefix .. suffix) - 3)
  if vim.fn.strdisplaywidth(name) > available then
    name = vim.fn.strcharpart(name, 0, math.max(1, available - 1)) .. "…"
  end
  local lead = prefix .. name .. " "
  local fill = math.max(1, width - vim.fn.strdisplaywidth(lead .. suffix))
  return lead .. string.rep("─", fill) .. suffix
end

local function command(input)
  if type(input) ~= "table" then
    return nil
  end
  if type(input.command) == "string" then
    return input.command
  end
  if type(input.arguments) == "table" and type(input.arguments.command) == "string" then
    return input.arguments.command
  end
  return nil
end

local function add(result, value)
  if value ~= nil and tostring(value) ~= "" then
    for _, line in ipairs(lines(value)) do
      table.insert(result, line)
    end
  end
end

local function friendly_output(output)
  if type(output) ~= "table" then
    return inspect(output)
  end
  local stdout = output.stdout or output.output or output.text
  local stderr = output.stderr
  if stdout ~= nil or stderr ~= nil then
    local result = {}
    add(result, inspect(stdout))
    add(result, inspect(stderr))
    return table.concat(result, "\n")
  end
  return inspect(output)
end

function M.lines(node, mode, width)
  local result = { M.header(node, width) }
  if mode == "compact" then
    return result
  end

  local input = node.input
  local output = node.output
  local bash = node.callable_id == "bash" or node.callable_id == "workspace.shell"
  if mode == "human" then
    local cmd = bash and command(input) or nil
    if cmd ~= nil then
      table.insert(result, "$ " .. cmd)
    elseif input ~= nil then
      add(result, inspect(input))
    end
    if output ~= nil then
      add(result, friendly_output(output))
    elseif node.state == "running" then
      table.insert(result, "Running…")
    end
    return result
  end

  table.insert(result, "Input")
  add(result, inspect(input) or "(none)")
  if output ~= nil then
    table.insert(result, node.state == "failed" and "Error" or "Output")
    add(result, inspect(output))
  end
  return result
end

function M.next_mode(current)
  if current == "compact" then
    return "human"
  elseif current == "human" then
    return "protocol"
  end
  return "compact"
end

return M

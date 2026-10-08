local M = {}

local MAX_HUMAN_LINES = 14

local function inspect(value)
  if value == nil then
    return nil
  end
  return type(value) == "string" and value or vim.inspect(value)
end

local function lines(value)
  return vim.split(tostring(value or ""), "\n", { plain = true })
end

local function text_width(text)
  return vim.fn.strdisplaywidth(text)
end

local function truncate(text, width)
  if text_width(text) <= width then
    return text
  end
  local result = ""
  for index = 0, vim.fn.strchars(text) - 1 do
    local character = vim.fn.strcharpart(text, index, 1)
    if text_width(result .. character .. "…") > width then
      break
    end
    result = result .. character
  end
  return result .. "…"
end

local function clean(text)
  -- These lines are rendered in a normal Neovim buffer. Strip terminal escapes,
  -- not ordinary UTF-8 text, so tool output cannot alter the terminal display.
  return tostring(text):gsub("\27%[[0-9;?]*[%a]", ""):gsub("[%z\1-\8\11\12\14-\31\127]", "�")
end

function M.status(state)
  if state == "completed" then
    return "completed", "PhenixToolCompleted", "✓"
  elseif state == "failed" then
    return "failed", "PhenixToolFailed", "✗"
  end
  return "running", "PhenixToolRunning", "◌"
end

function M.header(node, width, mode)
  local status, _, symbol = M.status(node.state)
  local name = tostring(node.callable_id or "unknown")
  local marker = mode == "compact" and "▸" or "▾"
  local prefix = marker .. " Tool  "
  local suffix = "  " .. symbol .. " " .. status
  width = math.max(20, width or 80)
  local available = math.max(1, width - text_width(prefix .. suffix) - 2)
  name = truncate(name, available)
  local lead = prefix .. name .. " "
  local fill = math.max(1, width - text_width(lead .. suffix))
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

local function fields(input)
  if type(input) ~= "table" then
    return nil
  end
  if type(input.arguments) == "table" then
    return input.arguments
  end
  return input
end

local function scope_name(value)
  if type(value) == "table" then
    return tostring(value.kind or value.scope or "unknown")
  end
  return tostring(value)
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
    if stderr ~= nil and stderr ~= "" then
      table.insert(result, "stderr:")
      add(result, inspect(stderr))
    end
    return table.concat(result, "\n")
  end
  return inspect(output)
end

local function human_input(node, result)
  local input = fields(node.input)
  local name = tostring(node.callable_id or "")
  if name == "bash" or name == "workspace.shell" then
    local cmd = command(node.input)
    if cmd ~= nil then
      add(result, "$ " .. cmd)
      return
    end
  end
  if (name == "workspace.read" or name:match("%.read$")) and type(input) == "table" then
    local path = input.path or input.resource or input.uri
    if type(path) == "string" then
      add(result, "Read  " .. path)
      return
    end
  end
  if name == "memory.record" and type(input) == "table" then
    if input.scope ~= nil then
      add(result, "Scope  " .. scope_name(input.scope))
    end
    if input.content ~= nil then
      add(result, "Content  " .. tostring(input.content))
    end
    if #result > 0 then
      return
    end
  end
  if node.input ~= nil then
    add(result, inspect(node.input))
  end
end

local function human_output(node, result)
  if type(node.output_streams) == "table" then
    if node.output_streams.stdout ~= "" and node.output_streams.stdout ~= nil then
      add(result, node.output_streams.stdout)
    end
    if node.output_streams.stderr ~= "" and node.output_streams.stderr ~= nil then
      add(result, "stderr:")
      add(result, node.output_streams.stderr)
    end
    -- The final structured output is still available in protocol mode. Avoid
    -- duplicating stdout already streamed into the human-readable view.
    if #result > 0 and (node.callable_id == "bash" or node.callable_id == "workspace.shell") then
      return
    end
  end
  if node.output ~= nil then
    add(result, friendly_output(node.output))
  elseif node.state == "running" and #result == 0 then
    add(result, "Running…")
  end
end

local function bounded_human(body, width)
  local max_width = math.max(16, math.min(width - 3, 160))
  local result = {}
  for _, value in ipairs(body) do
    if #result == MAX_HUMAN_LINES then
      table.insert(result, "  … more details: press 3 for protocol")
      break
    end
    table.insert(result, "  " .. truncate(clean(value), max_width))
  end
  return result
end

function M.lines(node, mode, width)
  mode = mode or "compact"
  width = math.max(20, width or 80)
  local result = { M.header(node, width, mode) }
  if mode == "compact" then
    return result
  end

  if mode == "human" then
    local body = {}
    human_input(node, body)
    human_output(node, body)
    for _, line in ipairs(bounded_human(body, width)) do
      table.insert(result, line)
    end
    return result
  end

  table.insert(result, "Input")
  add(result, inspect(node.input) or "(none)")
  if type(node.output_streams) == "table" then
    if node.output_streams.stdout ~= "" then
      table.insert(result, "Stream · stdout")
      add(result, node.output_streams.stdout)
    end
    if node.output_streams.stderr ~= "" then
      table.insert(result, "Stream · stderr")
      add(result, node.output_streams.stderr)
    end
  end
  if node.output ~= nil then
    table.insert(result, node.state == "failed" and "Error" or "Output")
    add(result, inspect(node.output))
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

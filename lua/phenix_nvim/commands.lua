local actions = require("phenix_nvim.actions")
local util = require("phenix_nvim.util")

local M = {}

local roots = {
  "auth",
  "cancel",
  "image",
  "reference",
  "select",
  "send",
  "session",
  "toggle",
  "window",
  "window",
}

local function join(args, first)
  return table.concat(args, " ", first or 1)
end

local function usage(message)
  util.notify(message, vim.log.levels.ERROR)
end

function M.execute(options)
  local args = vim.deepcopy(options.fargs or {})
  local command = table.remove(args, 1)
  if command == nil then
    actions.toggle()
    return
  end

  if command == "toggle" then
    if #args == 0 then
      actions.toggle()
    else
      usage("Usage: Phenix toggle")
    end
    return
  end
  if command == "send" then
    if #args == 0 then
      actions.send()
    else
      usage("Usage: Phenix send")
    end
    return
  end
  if command == "cancel" then
    if #args == 0 then
      actions.cancel()
    else
      usage("Usage: Phenix cancel")
    end
    return
  end
  if command == "auth" then
    if #args == 0 then
      actions.authenticate()
    else
      usage("Usage: Phenix auth")
    end
    return
  end
  if command == "select" then
    if #args == 0 then
      actions.choose_selection()
    else
      usage("Usage: Phenix select")
    end
    return
  end

  if command == "reference" then
    local subcommand = table.remove(args, 1)
    if subcommand == nil then
      if options.range ~= nil and options.range > 0 then
        actions.reference_range(options.line1, options.line2)
      else
        actions.reference()
      end
      return
    end
    if subcommand == "pick" and #args == 0 then
      actions.reference_picker()
      return
    end
    if subcommand == "at" and #args > 0 then
      actions.reference_at(join(args))
      return
    end
    usage("Usage: Phenix reference [pick|at <path>]")
    return
  end

  if command == "image" then
    local source = table.remove(args, 1)
    if source == nil or source == "clipboard" then
      if #args ~= 0 then
        usage("Usage: Phenix image [clipboard|<path>]")
        return
      end
      actions.attach_image("clipboard")
      return
    end
    table.insert(args, 1, source)
    actions.attach_image(join(args))
    return
  end

  if command == "window" then
    local subcommand = table.remove(args, 1)
    if subcommand == "new" and #args == 0 then
      actions.new_window()
      return
    end
    if subcommand == "close" and #args == 0 then
      actions.close_window()
      return
    end
    if subcommand == "move" and #args == 1 then
      local direction = args[1]
      if direction == "left" or direction == "right" or direction == "up" or direction == "down" or direction == "tab" then
        actions.move_window(direction)
        return
      end
    end
    usage("Usage: Phenix window <new|close|move <left|right|up|down|tab>>")
    return
  end

  if command == "session" then
    local subcommand = table.remove(args, 1)
    if #args ~= 0 then
      usage("Usage: Phenix session <new|close|select>")
      return
    end
    if subcommand == "new" then
      actions.new_session()
      return
    end
    if subcommand == "close" then
      actions.close_session()
      return
    end
    if subcommand == "select" then
      actions.choose_session()
      return
    end
    usage("Usage: Phenix session <new|close|select>")
    return
  end

  if command == "window" then
    local subcommand = table.remove(args, 1)
    if subcommand == "new" and #args == 0 then
      actions.new_window()
      return
    end
    if subcommand == "close" and #args == 0 then
      actions.close_window()
      return
    end
    if subcommand == "move" and #args == 1 then
      local direction = args[1]
      if direction == "left" or direction == "right" or direction == "up" or direction == "down" or direction == "tab" then
        actions.move_window(direction)
        return
      end
    end
    usage("Usage: Phenix window <new|close|move <left|right|up|down|tab>>")
    return
  end

  usage("Unknown Phenix subcommand: " .. tostring(command))
end

local function matches(values, lead)
  local result = {}
  for _, value in ipairs(values) do
    if lead == "" or value:sub(1, #lead) == lead then
      table.insert(result, value)
    end
  end
  return result
end

local function completed_args(cmdline, cursorpos)
  local prefix = cmdline:sub(1, cursorpos)
  local body = prefix:gsub("^%s*Phenix%s*", "", 1)
  local trailing_space = body:match("%s$") ~= nil
  local parts = vim.split(body, "%s+", { trimempty = true })
  if not trailing_space and #parts > 0 then
    table.remove(parts)
  end
  return parts
end

function M.complete(arglead, cmdline, cursorpos)
  local args = completed_args(cmdline, cursorpos)
  if #args == 0 then
    return matches(roots, arglead)
  end
  if args[1] == "reference" then
    if #args == 1 then
      return matches({ "at", "pick" }, arglead)
    end
    if args[2] == "at" then
      return vim.fn.getcompletion(arglead, "file")
    end
    return {}
  end
  if args[1] == "image" and #args == 1 then
    local values = { "clipboard" }
    vim.list_extend(values, vim.fn.getcompletion(arglead, "file"))
    return matches(values, arglead)
  end
  if args[1] == "session" and #args == 1 then
    return matches({ "close", "new", "select" }, arglead)
  end
  if args[1] == "window" then
    if #args == 1 then
      return matches({ "close", "move", "new" }, arglead)
    end
    if args[2] == "move" and #args == 2 then
      return matches({ "down", "left", "right", "tab", "up" }, arglead)
    end
  end
  if args[1] == "window" then
    if #args == 1 then
      return matches({ "close", "move", "new" }, arglead)
    end
    if #args == 2 and args[2] == "move" then
      return matches({ "down", "left", "right", "tab", "up" }, arglead)
    end
  end
  return {}
end

return M

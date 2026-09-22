local runtime = require("phenix_nvim.runtime")
local util = require("phenix_nvim.util")

local M = {}
local generation = 0

runtime.on_event(function(kind, status)
  if kind == "status" and status.connection ~= "ready" then
    generation = generation + 1
  end
end)

function M.new(callback)
  runtime.new_session(callback)
end

function M.resume(session_id, callback)
  runtime.resume_session(session_id, callback)
end

function M.close(session_id, callback)
  session_id = session_id or runtime.active_session()
  if session_id == nil then
    util.safe_call(callback, nil, { message = "no active Phenix session" })
    return
  end
  runtime.close_session(session_id, callback)
end

function M.choose()
  local picker_generation = generation
  runtime.list_sessions(function(result, error)
    if picker_generation ~= generation then
      return
    end
    if error ~= nil then
      util.notify(vim.inspect(error), vim.log.levels.ERROR)
      return
    end
    local sessions = result and (result.sessions or result) or {}
    vim.ui.select(sessions, {
      prompt = "Phenix sessions",
      format_item = function(item)
        return item.title or item.session_id or item.id or vim.inspect(item)
      end,
    }, function(item)
      if picker_generation ~= generation then
        return
      end
      if item ~= nil then
        runtime.resume_session(item.session_id or item.id, function(_, resume_error)
          if resume_error ~= nil then
            util.notify(vim.inspect(resume_error), vim.log.levels.ERROR)
          end
        end)
      end
    end)
  end)
end

return M

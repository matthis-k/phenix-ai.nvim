local M = {}

function M.pack(...)
  return { n = select("#", ...), ... }
end

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Phenix" })
end

function M.input_secret(prompt, callback)
  local ok, value = pcall(vim.fn.inputsecret, prompt)
  if not ok then
    M.safe_call(callback, nil, { message = tostring(value) })
    return
  end
  M.safe_call(callback, value, nil)
end

function M.request_poll(request)
  local result = M.pack(request:poll())

  -- High-level facade requests are explicit: ready, value?, error?.
  if result.n > 0 and type(result[1]) == "boolean" then
    if not result[1] then
      return false
    end
    return true, result[2], result[3]
  end

  -- Keep the raw ABI request shape usable for low-level consumers.
  if result.n == 0 then
    return false
  end
  if result[1] == nil and result[2] ~= nil then
    return true, nil, result[2]
  end
  return true, result[1], nil
end

function M.safe_call(callback, ...)
  if callback == nil then
    return
  end
  local ok, error = pcall(callback, ...)
  if not ok then
    M.notify(error, vim.log.levels.ERROR)
  end
end

return M

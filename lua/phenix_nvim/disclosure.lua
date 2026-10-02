local M = {}

function M.new()
  return { expanded = {} }
end

function M.is_open(state, id)
  return state ~= nil and state.expanded[id] == true
end

function M.set(state, id, open)
  state.expanded[id] = open == true
  return state.expanded[id]
end

function M.toggle(state, id)
  return M.set(state, id, not M.is_open(state, id))
end

function M.clear(state, id)
  if id == nil then
    state.expanded = {}
  else
    state.expanded[id] = nil
  end
end

return M

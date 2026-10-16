-- Manual live-model acceptance entry point for the packaged P1 client.
-- Invoked through a headless Neovim wrapper; the model and tool graph still
-- execute in Phenix, not in this script.
local prompt = vim.env.PHENIX_P1_PROMPT
if type(prompt) ~= "string" or prompt == "" then
  error("PHENIX_P1_PROMPT is required")
end

local frontend = require("phenix_nvim")
frontend.setup({ auto_connect = false })
local runtime = require("phenix_nvim.runtime")
local session, session_error
runtime.new_session(function(result, err)
  session, session_error = result, err
end)
assert(vim.wait(30000, function() return session or session_error end, 20),
  "P1 live model could not create a session")
assert(session and not session_error, vim.inspect(session_error))
local id = assert(session.session_id)
local selected, model_error
runtime.list_selections(function(result, err)
  selected, model_error = result, err
end)
assert(vim.wait(15000, function() return selected or model_error end, 20),
  "P1 live model did not supply a catalog")
assert(selected and not model_error, vim.inspect(model_error))
assert(selected.selected == "phenix.model.http",
  "live acceptance selected the scripted Model instead of phenix.model.http")

local response, failure
runtime.prompt(id, { { kind = "text", text = prompt } }, function(result, err)
  response, failure = result, err
end)
assert(vim.wait(180000, function() return response or failure end, 20),
  "P1 model prompt did not finish")
assert(response and not failure, vim.inspect(failure))
local state = runtime.session_state().sessions[id]
assert(state, "P1 transcript is missing")
local view, render_error = require("phenix_nvim.transcript.model").rebuild(state)
assert(view and not render_error, vim.inspect(render_error))
local messages = {}
for _, key in ipairs(view.order) do
  local node = view.nodes[key]
  if node.role == "assistant" and type(node.text) == "string" and node.text ~= "" then
    messages[#messages + 1] = node.text
  end
end
assert(#messages > 0, "live HTTP Model produced no assistant message")
-- Keep diagnostics off stdout, so callers may pipe or capture the answer.
-- Headless Neovim's print() writes to its message stream (stderr).
io.stderr:write("Phenix P1 live session: ", id, "\n")
io.stderr:write("Phenix P1 Model: ", selected.selected, "\n")
io.stdout:write(table.concat(messages, "\n"), "\n")
io.stdout:flush()
runtime.disconnect()

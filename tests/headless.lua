local native = require("phenix")
assert(native.interface_id == "phenix.application@1")

local frontend = require("phenix_nvim")
frontend.setup({ auto_connect = false })
local config = require("phenix_nvim.config")
local configured = config.get()
local inherited_openai_api_key = vim.env.OPENAI_API_KEY
vim.env.OPENAI_API_KEY = nil
assert(
  config.preferred_selection({ selection = "auto", env = {} }) == "router.chatgpt-plus",
  "ChatGPT OAuth must be the automatic route when no API key is configured"
)
vim.env.OPENAI_API_KEY = "test-api-key"
assert(
  config.preferred_selection({ selection = "auto", env = {} }) == "router.openai-api",
  "OPENAI_API_KEY must select the OpenAI API route"
)
vim.env.OPENAI_API_KEY = inherited_openai_api_key
local inherited_opencode_api_key = vim.env.OPENCODE_API_KEY
vim.env.OPENAI_API_KEY = nil
vim.env.OPENCODE_API_KEY = "test-opencode-key"
assert(
  config.preferred_selection({ selection = "auto", env = {} }) == "router.opencode-go",
  "OPENCODE_API_KEY must select the OpenCode Go route"
)
vim.env.OPENCODE_API_KEY = inherited_opencode_api_key
vim.env.OPENAI_API_KEY = inherited_openai_api_key
assert(
  config.preferred_selection({ selection = "router.mixed" }) == "router.mixed",
  "explicit routing selection must override automatic credential routing"
)
assert(
  configured.log_directory == vim.fn.stdpath("state") .. "/phenix",
  "default Phenix log directory must live under Neovim state"
)
local default_env = config.runtime_env(configured)
assert(
  default_env.PHENIX_LOG == "dir:" .. configured.log_directory,
  "runtime environment must pass the canonical log directory"
)
assert(configured.log_depth == "reference", "default log depth must be reference")
assert(default_env.PHENIX_LOG_DEPTH == "reference", "runtime must default to reference-depth logging")
local explicit_env = config.runtime_env({
  env = { PHENIX_LOG = "stderr", KEEP = "value" },
  log_directory = "/tmp/ignored",
})
assert(explicit_env.PHENIX_LOG == "stderr", "explicit PHENIX_LOG must override log_directory")
assert(explicit_env.PHENIX_LOG_DEPTH == "reference", "default reference depth must remain explicit")
assert(explicit_env.KEEP == "value", "runtime logging must preserve caller environment")
local legacy_env = config.runtime_env({
  env = { PHENIX_DEBUG_LOG = "/tmp/legacy.jsonl" },
  log_directory = "/tmp/ignored",
})
assert(legacy_env.PHENIX_LOG == nil, "legacy explicit debug log must not be shadowed")
assert(legacy_env.PHENIX_DEBUG_LOG == "/tmp/legacy.jsonl")
local disabled_env = config.runtime_env({ env = {}, log_directory = false })
assert(disabled_env.PHENIX_LOG == nil, "log_directory=false must disable default sink injection")
local inherited_log = vim.env.PHENIX_LOG
vim.env.PHENIX_LOG = "stdout"
local inherited_env = config.runtime_env({ env = {}, log_directory = "/tmp/ignored" })
assert(inherited_env.PHENIX_LOG == nil, "inherited PHENIX_LOG must not be shadowed")
vim.env.PHENIX_LOG = inherited_log
local explicit_depth = config.runtime_env({
  env = { PHENIX_LOG_DEPTH = "summary" },
  log_directory = "/tmp/phenix",
  log_depth = "reference",
})
assert(explicit_depth.PHENIX_LOG_DEPTH == "summary", "explicit PHENIX_LOG_DEPTH must win")
local disabled_depth = config.runtime_env({ env = {}, log_directory = "/tmp/phenix", log_depth = false })
assert(disabled_depth.PHENIX_LOG_DEPTH == nil, "log_depth=false must disable default depth injection")
local inherited_depth = vim.env.PHENIX_LOG_DEPTH
vim.env.PHENIX_LOG_DEPTH = "inline"
local inherited_depth_env = config.runtime_env({ env = {}, log_directory = "/tmp/phenix", log_depth = "reference" })
assert(inherited_depth_env.PHENIX_LOG_DEPTH == nil, "inherited PHENIX_LOG_DEPTH must not be shadowed")
vim.env.PHENIX_LOG_DEPTH = inherited_depth
vim.cmd.runtime("plugin/phenix.lua")
assert(type(frontend.reference) == "function")
assert(type(frontend.reference_at) == "function")
assert(type(frontend.reference_picker) == "function")
assert(type(frontend.send) == "function")
assert(type(frontend.choose_selection) == "function")
assert(frontend.choose_model == nil)
assert(frontend.choose_routing_profile == nil)
assert(vim.fn.exists(":PhenixSelect") == 2)
assert(vim.fn.exists(":PhenixModel") == 0)
assert(vim.fn.exists(":PhenixRoute") == 0)

local runtime = require("phenix_nvim.runtime")
local actions = require("phenix_nvim.actions")
local original_auth_methods = runtime.list_authentication_methods
local original_has_environment = runtime.has_environment
local original_reconnect_with_env = runtime.reconnect_with_env
local original_select_ui = vim.ui.select
local util = require("phenix_nvim.util")
local original_input_secret = util.input_secret
local original_notify = vim.notify
local api_key_call = nil

runtime.list_authentication_methods = function(callback)
  callback({ methods = {} }, nil)
end
runtime.has_environment = function(_name)
  return false
end
runtime.reconnect_with_env = function(name, value, selection, callback)
  api_key_call = { name = name, value = value, selection = selection }
  callback({}, nil)
end
vim.ui.select = function(items, options, callback)
  assert(options.prompt == "Phenix authentication")
  local selected = nil
  for _, item in ipairs(items) do
    if item._phenix_api_key ~= nil then
      selected = item
      break
    end
  end
  assert(selected ~= nil, "PhenixAuth must offer configured API-key providers")
  callback(selected)
end
util.input_secret = function(prompt, callback)
  assert(prompt == "OpenAI API key: ", "API-key input must use the provider label")
  callback("entered-api-key", nil)
end
vim.notify = function() end

actions.authenticate()
assert(api_key_call ~= nil, "API-key authentication must reconfigure the runtime")
assert(api_key_call.name == "OPENAI_API_KEY")
assert(api_key_call.value == "entered-api-key")
assert(api_key_call.selection == "router.openai-api")

runtime.list_authentication_methods = original_auth_methods
runtime.has_environment = original_has_environment
runtime.reconnect_with_env = original_reconnect_with_env
vim.ui.select = original_select_ui
util.input_secret = original_input_secret
vim.notify = original_notify

local context = require("phenix_nvim.context")
local direct = assert(context.typed_reference("file:///tmp/reference.txt"))
local typed = assert(context.typed_reference("@file:///tmp/reference.txt"))
assert(direct.kind == "resource")
assert(vim.deep_equal(direct, typed), "picker and @ references must share one typed constructor")

local model = require("phenix_nvim.compose.model")
local buffer = require("phenix_nvim.compose.buffer")
local document = model.new()
local source_a = {
  kind = "selection",
  source = { uri = "file:///a.rs", start_line = 1, end_line = 2 },
  snapshot = "A",
}
local a = model.add(document, source_a)
source_a.snapshot = "mutated"
assert(a.snapshot == "A", "selection snapshots must be immutable copies")
local b = model.add(document, {
  kind = "selection",
  source = { uri = "file:///b.rs", start_line = 3, end_line = 4 },
  snapshot = "B",
})
local serialized = assert(buffer.serialize_text(
  buffer.marker(a) .. "question A\n" .. buffer.marker(b) .. "question B",
  document
))
assert(#serialized == 4)
assert(serialized[1].snapshot == "A")
assert(serialized[2].text == "question A\n")
assert(serialized[3].snapshot == "B")
assert(serialized[4].text == "question B")

local transcript = require("phenix_nvim.transcript.model")
local projection = transcript.new("session-1")
local function update(sequence, change)
  return {
    session_id = "session-1",
    sequence = sequence,
    update = change,
  }
end
assert(transcript.apply(projection, update(1, {
  kind = "Message",
  message = {
    role = { kind = "User" },
    content = { { kind = "Text", text = "question" } },
  },
})))
assert(projection.nodes["session:session-1:sequence:1"].text == "question")
assert(transcript.apply(projection, update(2, {
  kind = "Execution",
  execution_id = "execution-1",
  update = { kind = "State", state = { kind = "Running" } },
})))
assert(transcript.apply(projection, update(3, {
  kind = "TextDelta",
  execution_id = "execution-1",
  text = "hello",
})))
assert(transcript.apply(projection, update(4, {
  kind = "TextDelta",
  execution_id = "execution-1",
  text = " world",
})))
local assistant_id = "session:session-1:execution:execution-1:assistant"
assert(projection.nodes[assistant_id].text == "hello world")
assert(transcript.apply(projection, update(5, {
  kind = "Execution",
  execution_id = "execution-1",
  update = {
    kind = "ToolCall",
    call_id = "call-1",
    callable_id = "tools.read",
    input = "README.md",
  },
})))
assert(transcript.apply(projection, update(6, {
  kind = "Execution",
  execution_id = "execution-1",
  update = { kind = "ToolResult", call_id = "call-1", output = "done" },
})))
local tool_id = "session:session-1:execution:execution-1:tool:call-1"
assert(projection.nodes[tool_id].state == "completed")
assert(transcript.apply(projection, update(7, {
  kind = "Review",
  review = {
    id = "review-1",
    revision = 0,
    session_id = "session-1",
    execution_id = "execution-1",
    files = {},
    state = { kind = "Pending" },
  },
})))
assert(projection.nodes["session:session-1:review:review-1"] ~= nil)
assert(transcript.apply(projection, update(8, {
  kind = "Message",
  message = {
    role = { kind = "Assistant" },
    content = { { kind = "Text", text = "hello world" } },
  },
})))
assert(projection.nodes[assistant_id].final == true)
assert(projection.nodes["session:session-1:sequence:8"] == nil)
assert(transcript.apply(projection, update(9, {
  kind = "Execution",
  execution_id = "execution-1",
  update = { kind = "State", state = { kind = "Completed" } },
})))
assert(projection.nodes["session:session-1:execution:execution-1:state"].state == "completed")

local rebuilt = assert(transcript.rebuild({
  session = { session_id = "session-1" },
  through_sequence = 9,
  updates = {
    update(1, {
      kind = "Message",
      message = {
        role = { kind = "User" },
        content = { { kind = "Text", text = "question" } },
      },
    }),
    update(2, {
      kind = "Execution",
      execution_id = "execution-1",
      update = { kind = "State", state = { kind = "Running" } },
    }),
    update(3, { kind = "TextDelta", execution_id = "execution-1", text = "hello" }),
    update(4, { kind = "TextDelta", execution_id = "execution-1", text = " world" }),
    update(5, {
      kind = "Execution",
      execution_id = "execution-1",
      update = {
        kind = "ToolCall",
        call_id = "call-1",
        callable_id = "tools.read",
        input = "README.md",
      },
    }),
    update(6, {
      kind = "Execution",
      execution_id = "execution-1",
      update = { kind = "ToolResult", call_id = "call-1", output = "done" },
    }),
    update(7, {
      kind = "Review",
      review = {
        id = "review-1",
        revision = 0,
        session_id = "session-1",
        execution_id = "execution-1",
        files = {},
        state = { kind = "Pending" },
      },
    }),
    update(8, {
      kind = "Message",
      message = {
        role = { kind = "Assistant" },
        content = { { kind = "Text", text = "hello world" } },
      },
    }),
    update(9, {
      kind = "Execution",
      execution_id = "execution-1",
      update = { kind = "State", state = { kind = "Completed" } },
    }),
  },
}))
assert(rebuilt.sequence == 9)
assert(rebuilt.nodes[assistant_id].text == "hello world")

local unknown_tool = transcript.new("session-1")
local _, tool_error = transcript.apply(unknown_tool, update(1, {
  kind = "Execution",
  execution_id = "execution-1",
  update = { kind = "ToolResult", call_id = "missing", output = "bad" },
}))
assert(tool_error ~= nil, "unknown tool results must request repair")
assert(unknown_tool.sequence == 0, "failed reducer updates must not advance the sequence")

local _, gap = transcript.apply(projection, update(11, {
  kind = "Execution",
  execution_id = "execution-1",
  update = { kind = "Progress", message = "bad gap" },
}))
assert(gap ~= nil, "session sequence gaps must fail instead of being guessed")

local sidebar = require("phenix_nvim.sidebar")
sidebar.open()
local transcript_buffer, compose_buffer = sidebar.buffers()
assert(transcript_buffer ~= compose_buffer, "transcript and compose must use separate buffers")
assert(vim.bo[compose_buffer].buftype == "acwrite", "compose buffer must support custom :write sending")

local normal_enter = nil
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(compose_buffer, "n")) do
  if mapping.lhs == "<CR>" then
    normal_enter = mapping
    break
  end
end
assert(normal_enter ~= nil, "compose buffer must map normal-mode Enter to send")

for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(compose_buffer, "i")) do
  assert(mapping.lhs ~= "<CR>", "compose buffer must not map insert-mode Enter")
end

local write_handlers = vim.api.nvim_get_autocmds({
  event = "BufWriteCmd",
  buffer = compose_buffer,
})
assert(#write_handlers == 1, "compose buffer must send through exactly one BufWriteCmd handler")

local transcript_view = require("phenix_nvim.transcript.buffer")
local transcript_win = vim.fn.bufwinid(transcript_buffer)
assert(transcript_win > 0, "transcript buffer must be visible")
vim.bo[transcript_buffer].modifiable = true
local lines = {}
for index = 1, 200 do
  lines[index] = "line " .. index
end
vim.api.nvim_buf_set_lines(transcript_buffer, 0, -1, false, lines)
vim.bo[transcript_buffer].modifiable = false
vim.api.nvim_win_set_cursor(transcript_win, { 1, 0 })
vim.api.nvim_win_call(transcript_win, function()
  vim.cmd("normal! zt")
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(transcript_win) })
assert(not transcript_view.is_following_tail(), "manual scrolling away from the end must disable follow-tail")
vim.api.nvim_win_set_cursor(transcript_win, { 200, 0 })
vim.api.nvim_win_call(transcript_win, function()
  vim.cmd("normal! zb")
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(transcript_win) })
assert(transcript_view.is_following_tail(), "returning to the end must re-enable follow-tail")
sidebar.close()

local review = require("phenix_nvim.review")
local review_buffer = assert(review.open({
  id = "review-1",
  revision = 1,
  files = {
    {
      uri = "file:///workspace/lib.rs",
      hunks = {
        { unified_diff = "@@ -1 +1 @@\n-old\n+new" },
      },
    },
  },
}))
assert(vim.bo[review_buffer].filetype == "diff")
assert(table.concat(vim.api.nvim_buf_get_lines(review_buffer, 0, -1, false), "\n"):find("%+new"))
vim.cmd("tabclose")

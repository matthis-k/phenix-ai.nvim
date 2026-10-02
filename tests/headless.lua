local native = require("phenix")
assert(native.interface_id == "phenix.application@1")

local frontend = require("phenix_nvim")
frontend.setup({ auto_connect = false })
local config = require("phenix_nvim.config")
local configured = config.get()
assert(configured.state_directory == nil, "Phenix must own its default state location")
assert(configured.selection == nil, "Neovim must not own the default model selection")
assert(configured.api_key_providers == nil, "Neovim must not own a provider authentication list")
assert(configured.models == nil, "Neovim must not own a model catalog")
local state_env = config.runtime_env({
  env = {},
  state_directory = "/tmp/phenix-state",
  log_directory = false,
  log_depth = false,
})
assert(state_env.PHENIX_STATE_DIR == "/tmp/phenix-state", "state_directory must be passed to Phenix")
local explicit_state_env = config.runtime_env({
  env = { PHENIX_STATE_DIR = "/tmp/explicit-state" },
  state_directory = "/tmp/ignored-state",
  log_directory = false,
  log_depth = false,
})
assert(explicit_state_env.PHENIX_STATE_DIR == "/tmp/explicit-state", "explicit PHENIX_STATE_DIR must win")
local inherited_state = vim.env.PHENIX_STATE_DIR
vim.env.PHENIX_STATE_DIR = "/tmp/inherited-state"
local inherited_state_env = config.runtime_env({
  env = {},
  state_directory = "/tmp/ignored-state",
  log_directory = false,
  log_depth = false,
})
assert(inherited_state_env.PHENIX_STATE_DIR == nil, "inherited PHENIX_STATE_DIR must not be shadowed")
vim.env.PHENIX_STATE_DIR = inherited_state
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
assert(type(frontend.new) == "function")
assert(type(frontend.logs) == "function")
assert(type(frontend.choose_selection) == "function")
assert(frontend.choose_model == nil)
assert(frontend.choose_routing_profile == nil)
assert(vim.fn.exists(":Phenix") == 2)
assert(vim.fn.exists(":PhenixSelect") == 0)
assert(vim.fn.exists(":PhenixModel") == 0)
assert(vim.fn.exists(":PhenixRoute") == 0)

local runtime = require("phenix_nvim.runtime")
local actions = require("phenix_nvim.actions")
local original_auth_methods = runtime.list_authentication_methods
local original_authenticate = runtime.authenticate
local original_select_ui = vim.ui.select
local util = require("phenix_nvim.util")
local original_input_secret = util.input_secret
local original_notify = vim.notify
local api_key_call = nil

runtime.list_authentication_methods = function(callback)
  callback({
    methods = {
      {
        id = "xai-api-token",
        provider = "xai",
        kind = "api_token",
        name = "API key",
        description = "Stored by Phenix",
      },
    },
  }, nil)
end
runtime.authenticate = function(method_id, secret, callback)
  api_key_call = { method_id = method_id, secret = secret }
  callback({ kind = "authenticated" }, nil)
end
vim.ui.select = function(items, options, callback)
  assert(options.prompt == "Phenix authentication")
  assert(#items == 1 and items[1].provider == "xai", "authentication must come from runtime discovery")
  callback(items[1])
end
util.input_secret = function(prompt, callback)
  assert(prompt == "xai API key: ", "API-key input must identify the provider")
  callback("entered-api-key", nil)
end
vim.notify = function() end

actions.authenticate()
assert(api_key_call ~= nil, "API-key authentication must be delegated to Phenix")
assert(api_key_call.method_id == "xai-api-token")
assert(api_key_call.secret == "entered-api-key")

runtime.list_authentication_methods = original_auth_methods
runtime.authenticate = original_authenticate
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
local transcript_surface = assert(sidebar.current_surface())

-- Tool payloads stay out of the rendered transcript until the user opens them.
local payload_marker = "TOOL-PAYLOAD-MUST-BE-COLLAPSED"
transcript_view.render_projection({
  order = { "tool" },
  nodes = {
    tool = {
      id = "tool",
      kind = "tool",
      callable_id = "workspace.shell",
      state = "completed",
      input = { command = payload_marker .. string.rep("x", 4096) },
      output = { text = payload_marker .. string.rep("y", 4096) },
    },
  },
}, transcript_surface.transcript_key)
local collapsed = table.concat(vim.api.nvim_buf_get_lines(transcript_buffer, 0, -1, false), "\n")
assert(collapsed:find("<CR> details", 1, true), "collapsed tool must advertise disclosure")
assert(not collapsed:find(payload_marker, 1, true), "collapsed tool must not eagerly render its payload")
vim.api.nvim_win_set_cursor(transcript_win, { 1, 0 })
assert(transcript_view.toggle_tool(transcript_win, transcript_surface.transcript_key))
local expanded = table.concat(vim.api.nvim_buf_get_lines(transcript_buffer, 0, -1, false), "\n")
assert(expanded:find(payload_marker, 1, true), "expanded tool must render its payload")
assert(transcript_view.toggle_tool(transcript_win, transcript_surface.transcript_key))
local collapsed_again = table.concat(vim.api.nvim_buf_get_lines(transcript_buffer, 0, -1, false), "\n")
assert(not collapsed_again:find(payload_marker, 1, true), "collapsing a tool must remove its payload from the buffer")

-- Wrapped transcript scrolling must operate on screen rows. A partial view of
-- the final logical line is not the tail.
if vim.fn.exists("+smoothscroll") == 1 then
  assert(vim.wo[transcript_win].smoothscroll, "wrapped transcript must enable smoothscroll")
end
vim.bo[transcript_buffer].modifiable = true
vim.api.nvim_buf_set_lines(transcript_buffer, 0, -1, false, { string.rep("wrapped text ", 2000) })
vim.bo[transcript_buffer].modifiable = false
vim.api.nvim_win_set_cursor(transcript_win, { 1, 0 })
vim.api.nvim_win_call(transcript_win, function()
  vim.cmd("normal! zt")
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(transcript_win) })
assert(
  not transcript_view.is_following_tail(transcript_win, transcript_surface.transcript_key),
  "seeing only the start of a wrapped final line must disable follow-tail"
)
vim.api.nvim_win_call(transcript_win, function()
  vim.cmd("normal! G$")
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(transcript_win) })
assert(
  transcript_view.is_following_tail(transcript_win, transcript_surface.transcript_key),
  "showing the end of the wrapped final line must re-enable follow-tail"
)
sidebar.close()

-- Logs use the same semantic disclosure behavior as transcript tools. Hidden
-- payloads are absent from the buffer until opened, while references remain
-- directly navigable.
local original_logs = runtime.logs
local original_log_reference = runtime.log_reference
local digest = "sha256:" .. string.rep("a", 64)
local reference = {
  digest = digest,
  media_type = "application/json",
  bytes = 18,
  locator = { kind = "file", path = "sha256/aa/" .. string.rep("a", 64) },
}
runtime.logs = function(options, callback)
  assert(options.limit == 200)
  callback({
    records = {
      {
        cursor = "0",
        timestamp_ms = 1,
        pid = 1,
        kind = "runtime_trace",
        payload = {
          summary = { event = "fixture" },
          hidden = "LOG-PAYLOAD-MUST-BE-COLLAPSED",
          detail = { kind = "reference", reference = reference },
        },
      },
    },
    next_cursor = nil,
  }, nil)
end
runtime.log_reference = function(value, callback)
  assert(value.digest == digest)
  callback({
    reference = value,
    content = '{"nested":"REFERENCE-PAYLOAD"}',
  }, nil)
end

local logs = require("phenix_nvim.logs")
logs.open("all")
local log_buffer = vim.api.nvim_get_current_buf()
local log_lines = vim.api.nvim_buf_get_lines(log_buffer, 0, -1, false)
local collapsed_log = table.concat(log_lines, "\n")
assert(not collapsed_log:find("LOG%-PAYLOAD%-MUST%-BE%-COLLAPSED"))
assert(collapsed_log:find("fixture", 1, true))
assert(collapsed_log:find("sha256:", 1, true))

local toggle_log
local follow_log
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(log_buffer, "n")) do
  if mapping.lhs == "<CR>" then
    toggle_log = mapping.callback
  elseif mapping.lhs == "gf" then
    follow_log = mapping.callback
  end
end
assert(type(toggle_log) == "function")
assert(type(follow_log) == "function")

local record_row
local reference_row
for index, line in ipairs(log_lines) do
  if line:find("runtime_trace", 1, true) then
    record_row = index
  elseif line:find("sha256:", 1, true) then
    reference_row = index
  end
end
assert(record_row ~= nil and reference_row ~= nil)
vim.api.nvim_win_set_cursor(0, { record_row, 0 })
toggle_log()
local expanded_log = table.concat(vim.api.nvim_buf_get_lines(log_buffer, 0, -1, false), "\n")
assert(expanded_log:find("LOG%-PAYLOAD%-MUST%-BE%-COLLAPSED"))

-- Re-rendering can move the reference row, so resolve it again before gf.
for index, line in ipairs(vim.api.nvim_buf_get_lines(log_buffer, 0, -1, false)) do
  if line:find("sha256:", 1, true) then
    reference_row = index
    break
  end
end
vim.api.nvim_win_set_cursor(0, { reference_row, 0 })
follow_log()
local reference_buffer = vim.api.nvim_get_current_buf()
local reference_text = table.concat(vim.api.nvim_buf_get_lines(reference_buffer, 0, -1, false), "\n")
assert(reference_text:find("REFERENCE%-PAYLOAD"))
vim.cmd("tabclose")
vim.cmd("tabclose")
runtime.logs = original_logs
runtime.log_reference = original_log_reference

local review = require("phenix_nvim.review")
local original_decide_review = runtime.decide_review
local review_decisions = {}
local review_callbacks = {}
runtime.decide_review = function(value, decision, callback)
  table.insert(review_decisions, { review = value, decision = decision })
  table.insert(review_callbacks, callback)
end
local review_value = {
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
  state = { kind = "Pending" },
}
local review_buffer = assert(review.open(review_value))
assert(vim.bo[review_buffer].filetype == "diff")
assert(table.concat(vim.api.nvim_buf_get_lines(review_buffer, 0, -1, false), "\n"):find("%+new"))
local accept
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(review_buffer, "n")) do
  if mapping.lhs == "a" then
    accept = mapping.callback
    break
  end
end
assert(type(accept) == "function")
accept()
accept()
assert(#review_decisions == 1, "pending review decision must be single-flight")
local accepted = vim.deepcopy(review_value)
accepted.state = { kind = "Accepted" }
review_callbacks[1](accepted, nil)
accept()
assert(#review_decisions == 1, "settled review must not accept a second decision")
runtime.decide_review = original_decide_review
vim.cmd("tabclose")

-- N5: unavailable client-tool admission must not be reported as success.
-- The P1 ACP client can use runtime-owned tools, but this Lua process cannot
-- install its local templates through a negotiated client-tool contract.
local tools = require("phenix_nvim.tools")
local runtime = require("phenix_nvim.runtime")
local calls, admitted, error_value = 0, nil, nil

tools.enable_defaults()
assert(#tools._templates() > 0, "test needs locally registered templates")
runtime.refresh_client_tools(function(value, err)
  calls = calls + 1
  admitted, error_value = value, err
end)
assert(calls == 1, "missing synchronous unsupported response")
assert(admitted == nil, "missing host admission must never report success")
assert(type(error_value) == "table" and error_value.kind == "unsupported",
  "P1 must return typed unsupported for client-tool registration")
-- This is a projection capability check, not a transport connection attempt.
assert(runtime.status().connection == "disconnected")
tools.disable_defaults()
print("N5 missing negotiated tool admission fails explicitly")

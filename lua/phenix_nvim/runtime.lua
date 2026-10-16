-- The supported Neovim runtime is the M1/P1 ACP client projection.
-- Runtime authority remains in Phenix; no oldmain binding or fallback.
local runtime = require("phenix_nvim.runtime_p1")
function runtime.p1_active()
  return runtime.active()
end
return runtime

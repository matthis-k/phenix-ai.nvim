# P1 Lua client boundary

The Phenix runtime owns sessions, execution, model selection, routes, credentials and configuration. Neovim owns dialogs, keymaps, windows, compose buffers and transcript presentation. The Lua client SDK mediates the two.

## Client interface

```lua
local client = require("phenix_client").new(require("phenix_client.acp").new())
client:start(function(capabilities, err) end)
client:new_session(function(session, err) end)
client:send(session_id, "hello", function(result, err) end)
client:send_content(session_id, {
  { type = "text", text = "Explain this file" },
  { type = "resource_link", name = "buffer", uri = "file:///repo/source.lua" },
}, function(result, err) end)
client:cancel(session_id, function(result, err) end)
client:on("session.updated", function(event) end)

-- Read-only P1 discovery after session/new or session/load from PR #892.
client:list_models(session_id, function(catalog, err) end)
-- Requires the additional authorized management contract in #891.
client:set_model(model_id, function(selection, err) end)
client:on("model.changed", function(event) end)
```

The client SDK defines the calls and delegates them to a transport. It does not implement model catalogs, routing policy, authorization decisions or persistence. Its capability cache is a display hint. The runtime must authorize every call.

## P1 support

| Operation | P1 ACP v1 | Source of truth |
| --- | --- | --- |
| Initialize | Yes | Host negotiation |
| New session | Yes | Phenix session plugin |
| Load durable session | Yes | Phenix journal and SQLite |
| Prompt / stream | Yes | Agent graph and journal |
| Cancel | Yes | Kernel root cancellation |
| Discover effective model binding | Read-only after new/load in PR #892 | Runtime composition |
| Select different models | Not exposed | Authorized management contract in #891 |
| Authentication / permission prompts | Not exposed | Planned runtime management contract |
| Routing updates | Not exposed | Planned runtime management contract |
| Logs / tools management | Not exposed | Planned runtime management contract |

The SDK returns a typed `unsupported` error for model switching and other missing operations. Its model catalog is a session-scoped snapshot returned by Phenix ACP after session creation or reload, not an independent Lua-maintained model registry. No frontend should invent model state or grant itself authority. Phenix AI issue #891 tracks the runtime side of these operations.

## Neovim migration

The old UI modules remain in the repository. The existing `phenix_nvim.runtime` facade now selects either the legacy native backend or `runtime_p1`. With `backend = "p1"`, the original Neovim sidebar, compose buffer, commands and transcript controller use the standalone `phenix_client` API. The native legacy Lua module is optional in P1 mode. Unsupported P1 controls fail explicitly; they never invoke the old backend.

The current default remains `legacy` until P1 reaches feature parity. Keep all selectors, rich transcript, image attachment, permission dialogs and editor tools available for the eventual completed cutover.

Migration is complete only when the original UI uses the new SDK, shows runtime-returned models and authentication methods, sends through P1, survives restart and replay, and has no fallback to oldmain. In particular, a working SDK against a scripted P1 model is not proof that Neovim's full agent UI is usable.

## Acceptance

`tests/client_sdk.lua` exercises typed Lua delegation, events and unsupported operations against deterministic backends.

`tests/p1_client_transport.lua` checks real JSON-RPC v1 request and notification shapes with a deterministic process mock.

`tests/p1_client_product.lua` uses the packaged P1 Basic ACP executable to test model discovery, turns, text/resource-link input, and user/tool/assistant transcript replay after process restart. `tests/p1_model_picker.lua` and `tests/p1_transcript.lua` exercise the existing Neovim picker and renderer interfaces. GitHub workflow `p1-lua-client.yml` runs these checks. The suite also runs `tests/p1_ui_runtime.lua` for the shared runtime interface and `tests/p1_ui_product.lua` against the actual existing sidebar, picker and transcript, including a durable restart. It does not yet prove full common-feature parity.

An official SDK-backed Rust Lua module may replace the narrow ACP transport if it reduces code and duplication. It belongs outside the Phenix plugin set. The Lua-facing methods and runtime authorization rules should remain unchanged.


## UI contract inventory

Preserve the current frontend components and have them consume Phenix queries, actions and updates. This is the acceptance checklist for the eventual backend cutover, not a claim that P1 already exposes each operation.

| Neovim UI | Query or incoming event | User action forwarded to Phenix | P1 availability |
| --- | --- | --- | --- |
| Chat and transcript | Session updates, answer and tool events | Submit prompt, cancel turn | ACP v1; adapter `phenix_client.transcript` translates to existing rich renderer |
| Provider / model / thinking picker | Authorized providers, variants, effective selection | Set selected model or thinking level | Read-only model binding from #892; mutations require #891 |
| Routing editor | Rules, effective route and revision | Update route with revision check | After model management |
| Session picker | Owned sessions, metadata, current session | New, load, activate and close | ACP v1 supports new/load. `:Phenix session load <id>` allows durable reload; local picker is incomplete |
| Authentication dialogs | Provider authentication methods and status | Supply secret or initiate external flow | Requires #891 |
| Tool approval and progress | Call and authorization requests, progress | Approve, reject, cancel | Progress via ACP; approvals require runtime support |
| Editor references and attachments | Current Neovim selection, editor context | Send user-approved content blocks | P1 only supports text and resource links |
| Logs and execution inspector | Journal/log queries and change cursors | Filter, expand, inspect | Requires later observer/control operations |

For each control: query authoritative state, display it, send the chosen operation, and update only from the runtime response or event. A frontend may hold pending UI state but must not make that pending value authoritative. Failed, denied and stale-revision mutations leave the runtime state unchanged and surface the returned error.

Lua is a client endpoint with Phenix-authorized operations. UI callbacks do not bypass the kernel's scoped permissions. Shared state can be rendered by several frontends; each observes and refreshes the same Phenix-owned revision.

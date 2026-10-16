# Neovim client roadmap: P1 Basic to P2 Advanced

Status: planned. P1 Basic is accepted in `phenix-ai`, but Neovim's P1 backend is not the default or an accepted replacement yet.
Updated: 2026-10-16
Owner: `phenix-ai.nvim`. Distribution work lives in [phenix-nvim's roadmap](https://github.com/matthis-k/phenix-nvim/blob/main/spec/p1-p2-distribution-roadmap.md).

## Authority and references

This file tracks implementation order and acceptance in the standalone client. It does not redefine the runtime or the existing integration contracts.

- [Phenix M1 roadmap](https://github.com/matthis-k/phenix-ai/blob/main/spec/m1-roadmap.md), especially post-P1 session projections, P2-IO1 through P2-IO4, A2UI and I/O.
- [Phenix Advanced roadmap](https://github.com/matthis-k/phenix-ai/blob/main/spec/p2-advanced-agent-roadmap.md), for memory, workspace, jobs, session trees, code intelligence and inspection.
- [Runtime management issue #891](https://github.com/matthis-k/phenix-ai/issues/891), for authorized model/routing/configuration changes, durable follow-ups, approval, subscriptions and shared sessions.
- [Existing P1 migration PR #48](https://github.com/matthis-k/phenix-ai.nvim/pull/48) and its `spec/p1-client-sdk.md`, for current ACP Basic coverage. The PR is an implementation input, not full migration acceptance.
- [Neovim integration behavior](nvim-integrations.md), [mechanical APIs and test cases](nvim-integrations-implementation.md) and [value/capability boundary](nvim-integrations-value-capability.md). These remain authoritative for local Lua adapters, tool schemas and callback lifetime.

Dependency direction is `phenix-nvim -> phenix-ai.nvim -> phenix-ai`. The runtime is the only authority for sessions, graphs, tools, models, permissions, configuration and persistence. This client owns Neovim rendering, editor context, Lua-facing interaction and frontend capability advertisement. The distribution supplies package pins, keymaps, theme and optional overrides.

## Design fixed at the P1 boundary

Build P1 on the same seams needed by P2. P2 should add projections, supported transports, catalogs and renderers rather than replace the client.

1. **Transport and Lua SDK.** The standalone `phenix_client` API defines submit, cancel, load, subscribe and query/action requests. Its ACP v1 implementation is a transport adapter, not another agent API. Use the official ACP schema/SDK where supported and keep standard protocol messages intact. Host-neutral binding work belongs in `phenix-ai` if it is reused by other frontends.
2. **One Neovim ingress.** `phenix_nvim.runtime` owns connection lifetime, session selection and adapter subscription. It maps authorized runtime responses/events to a cached read-only Neovim projection. UI controllers do not import transport objects, native client userdata or private contract IDs.
3. **Projections, never replicas.** Retain session identity, origin, request identity, generation/revision and event order wherever supplied. Reconnect begins from a runtime snapshot and ordered replay; a frontend never invents accepted messages, tool effects or model selections. The existing transcript, prompt, status and permission views read the projection. P1 ACP lacks some P2 cursors; record the limitation rather than guessing a cursor.
4. **Actions are intents.** Buttons, mappings, `:Phenix` commands and Lua callbacks submit typed user intents. An accepted runtime response or event updates authoritative state. A pending control can show a pending indicator but cannot grant permissions or optimistically commit configuration. Unavailable operations return a typed unsupported error.
5. **Presentation is replaceable locally.** Keep existing sidebar/transcript/compose behavior. Use the existing integration registry for pickers, forms, review, notification, navigation, image sources, tool presentation and status. Callbacks remain ordinary Neovim Lua values; only runtime-facing handlers and client tools cross the typed capability boundary.
6. **No compatibility architecture.** PR #48's dual backend is a short-lived migration mechanism. The final supported client has one P1/M1 runtime path. Remove the legacy native/oldmain backend, compatibility facades and stale tests after the new packaged path passes product acceptance. Preserve UI features, not their old runtime implementation.
7. **Do not copy runtime catalogs.** Provider/model/thinking choices, route policy, credentials, allowed actions and permission grants come from the runtime and its selected plugins. Version/revision mismatch, stale client and denied scopes are explicit failures.

## P1 implementation slices

Each slice is a reviewable change with RED behavioral tests before implementation. All packaging tests exercise the same Basic graph, not a frontend simulation.

| ID | Depends on | Client work | Functional acceptance |
| --- | --- | --- | --- |
| N0: baseline and inventory | Accepted `phenix-basic`; PR #48 | Inventory current commands and UI flows against Basic ACP v1 and runtime #891. Keep existing transcript/compose UI; identify old native imports, transport duplication and unsupported P1 features. | A checked capability matrix reports supported, blocked and intentionally unsupported behaviors. Existing UI regressions stay green. |
| N1: independent P1 client | N0; runtime #892 for effective model | Finish `phenix_client` with standard ACP v1 initialization, new/load, typed prompt blocks, stream, cancel, session-bound model read and callbacks. Reuse #48 rather than creating another bridge. | Deterministic protocol fixture plus packaged Basic session, multi-turn tool result, error, cancellation, restart/replay and permission-option validation. No leaked callbacks across reconnect. |
| N2: original Neovim UI on P1 | N1 | Drive sidebar, transcript, separate compose and editable follow-up windows, model display, tool/reasoning disclosure and permission UI from the P1 projection. Ensure multiple Neovim chat surfaces can select their session without copying runtime state. | Headless real-Neovim product journey opens chat, submits, streams, reloads, shows the correct user/assistant/tool order and fails closed for stale prompts. Keep PR #48's `p1_ui_product` test. |
| N3: packaged Basic cutover | N2; matching Basic executable and Nix artifacts | Replace legacy `phenix`/`phenix-binding-lua` assumptions in `flake.nix` with the real accepted P1 Basic ACP entry point. Set the packaged P1 backend as the supported default. Delete oldmain fallback and retired native-only product paths, preserving reusable Lua UI. | `nix flake check -L` builds the plugin and runs the packaged Basic UX, restart, failed launch, multi-session and permission tests. Package closure and startup use the exact pinned runtime revision. |
| N4: authorized management and queue | N3; runtime #891/P2-IO1 as APIs arrive | Bind runtime discovery and revision-checked mutations for provider/model/thinking, routing and scoped settings, auth, session list/load/close and durable queued/interrupting input. Keep unsupported controls hidden/disabled until the runtime offers them. | Model/config changes survive reconnect and report origin/revision; denied/stale mutations do not change UI authority; accepted follow-ups survive restart in order; interrupted turns cannot replay uncertain effects. |
| N5: editor integration completion | N3; N4 only for privileged actions | Finish the existing `phenix_nvim.integrations` and `phenix_nvim.tools` contracts. Register bounded default context/navigation/review tools via normal client-tool admission, retain optional permission-gated Lua eval/exec/reload, and present file references/diffs/images where the selected runtime transport supports them. | Tests from `nvim-integrations-implementation.md` pass against the selected runtime. Disabled tools are absent; denied privileged calls never execute. One live handler per session/client generation. |
| N6: P1 frontend acceptance | N3; N4/N5 for declared parity | Audit command inventory, remove dead compatibility branches, test close/reconnect and log/inspection degradation where P1 does not expose the service. Publish a precise feature matrix. | No fallback to legacy. Full packaged Basic story and independent ACP client interop pass on one pinned pair of runtime/client SHAs. All unsupported features fail explicitly; no claim of parity for missing #891 services. |

**Cutover rule.** N3 is the minimum P1 Neovim milestone. N4/N5 restore the broader interactive feature set as the runtime exposes authorized contracts. N6 is accepted only for the actual declared feature matrix, not on the basis of a mock-only SDK test. No P2 Advanced implementation is required to make Basic chat usable.

## P2 client implementation slices

P2 Advanced is an additive runtime preset. Neovim can use the same SDK, views and controls while its runtime gains capabilities. The P2-IO frontend track is separate from Advanced's release gate.

| ID | Runtime dependency | Client work | Functional acceptance |
| --- | --- | --- | --- |
| C1: independent live projections | P2-IO1/IO2, #891 | Consume authorized snapshot + ordered change cursors; model separate connection, client, session, request and execution lifetimes. Support multiple viewers of one session and independent replay positions. | Two clients see the same committed state, each with its own cursor; slow/disconnected viewer cannot block a turn or affect the other. |
| C2: dynamic action/feature selection | C1 and #891 | Drive command availability, menus, editor actions, status and configuration dialogs from advertised typed capabilities, not a static model/provider list. Handle selected runtime composition/generation changes. | Denied, missing or revoked capabilities disappear or become disabled. No cross-client or cross-project actions survive rebinding. |
| C3: A2UI catalog and local Lua registry | P2-IO2/IO4; C1 | Implement the accepted upstream A2UI v0.9.1 component catalog in `phenix-ai.nvim`, with built-in text, interactive controls, container/card and data-binding renderers. Provide a normal Lua table registry keyed by component name, with defaults, override/removal and extra catalogs. Containers can recursively render children. The registry lives in the standalone client, not the distribution. | Advertise only actually supported catalog IDs/component schemas. Validate upstream envelopes, component bounds, nesting, revisions, data bindings and action payloads before rendering/return. Malformed, stale and unsupported nodes reject with no partial UI. |
| C4: negotiated per-client UI | P2-IO2/IO3/IO4; C3 | Advertise A2UI versions and catalogs through a verified supported initialization/transport facility. Phenix selects the catalog and validates model output for the target client. Pin each live surface to its chosen catalog. Deliver standard A2UI messages unchanged. Keep ACP elicitation/text fallback where negotiated interactive UI is unavailable. | Text/Button-only peer never receives Form/SVG. Extended peer can use allowed input, checkbox and nested card. Cross-client action, forged component ID, stale catalog and untrusted inline catalogs fail closed. |
| C5: action lifecycle, renderers and terminal UX | C4; P2-IO4 | Map validated A2UI user events to authorized runtime actions. Add editable defaults and renderer overrides for input, checkbox, buttons, layout and cards; optional safe SVG only with a trusted advertised catalog and sanitization. Keep character-cell layout, disclosure/folds, bounded tool output and streamed reasoning distinct from protocol data. Use Neovim native fold callbacks when verified to simplify the renderer, not as an authority mechanism. | User actions settle once under current session/client generation. Reconnect disposes old handles; component focus, cancellation, stale responses, nesting and buffer/window close all pass Neovim tests. |
| C6: Advanced workflows | P2 Advanced stages P2-4 through P2-9 | Present code evidence and stale/rebuild state, workspace edit/diff/review, job attach/cancel/log cursors, child-session tree and token/cost/trace inspection as views over runtime providers. No client-owned jobs, code index, memory or agent loop. | Packaged Advanced-verification fixture covers edit conflict, job detach/reattach, two children, scoped evidence, restart and independent inspection, with Basic parity unchanged. |
| C7: interoperability and release | C1 through C6 for installed features | Exercise ACP standard clients plus Neovim, including reconnect, partial negotiation, permission races, version mismatch and slow consumer. Separate Basic-only and Advanced package suites. | Exact pinned runtime/client closure, independent wire client, A2UI schema fixture and real Neovim renderer all pass. A Basic-only package does not require Advanced plugins or A2UI. |

### Public extension boundary

Use the already specified `phenix_nvim.integrations`, `phenix_nvim.tools.register` and `phenix_nvim.status.get/listen` entry points for editor-local customization and tools. Add an A2UI-native registry through the same frontend integration model rather than inventing a Phenix UI message schema. A registry entry receives a validated component plus context/children and returns a Neovim presentation handle; local callbacks can submit only actions authorized by Phenix. The client advertises its **effective** defaults and overrides. `phenix-nvim` may change them but never needs its own negotiation stack.

ACP remains ACP, MCP remains MCP, and A2UI remains A2UI. When a standard transport lacks an operation, report it as unavailable or use another existing verified standard facility. Do not assign private ACP method names, serialize Lua functions or execute model-supplied Lua.

## Test and rollout policy

- Every new slice starts with an observable failing test, then the smallest implementation. Keep protocol/schema verification in `phenix-ai`, client projections/rendering in this repo and pinned distribution journeys in `phenix-nvim`. CI tests behavior, not a second list of forbidden architectural patterns.
- Keep unit/Neovim headless tests, a packaged Basic ACP product test and negative tests for malformed frames, stale revisions, scope denial, cancellation, restart and lost transport. For C3-C5 use the upstream versioned A2UI schemas and an actual renderer fixture.
- Merge and propagate upstream runtime changes before pinning this client's `flake.lock` to their exact revision. Then update `phenix-nvim` to an internally consistent runtime/client pair. Never change a lock to point at a non-existent package.
- Update this milestone table in the owning client PR. Link evidence to actual final commit checks. Planning alone is not implementation or acceptance.

## Status at plan creation

P1 runtime: accepted. N0-N2: partial work in open PR #48. N3-N6: not accepted. C1-C7: planned. The existing Neovim integration specifications describe later functionality but do not prove it implemented against the M1 Basic product.

Outstanding design questions: 0. Accepted cross-repository responsibilities and protocol decisions remain in force. Deferred implementation stages: N3-N6 and C1-C7, pending their listed runtime dependencies.

# Neovim client roadmap: P1 Basic to P2 Advanced

Status: P1 Basic Neovim N0–N3 ACCEPTED; N4 provider/catalog and scoped API-key UX PARTIALLY IMPLEMENTED, N5 bounded editor tools and editable queue UI PARTIALLY IMPLEMENTED; N4 authoritative model mutation/verification, N5 runtime admission, N6 full acceptance and P2 Advanced UI remain open.
Updated: 2026-10-20
Owner: `phenix-ai.nvim`. Distribution work lives in [phenix-nvim's roadmap](https://github.com/matthis-k/phenix-nvim/blob/main/spec/p1-p2-distribution-roadmap.md).

## 20 October 2026 implementation reconciliation

Current client `main` checked at `532d7340` (#90 merged). These updates mark **individual integrated behaviors**, not N4/N5 product acceptance or a new contract:

- **#46 closed unmerged**: its supported presentation-only editable follow-up buffers were extracted and merged in #69. Do not repair/reopen the discarded old transport façade; runtime-authorized durable queue admission, interrupt-and-submit and controller integration are still missing under runtime #891 and client N4/N5.
- **Editor tool and lifecycle progress:** #72/#74/#76/#77/#80 corrected bounded quickfix/cursor/buffer/viewport reads and default-tool overrides; #83/#85 reject obsolete asynchronous session replies. These fixes are merged. The negotiated client-tool authority and comprehensive N5 negative/product matrix remain future work.
- **Catalog/model selection presentation:** #75/#78/#79/#81/#82 hardened usable choices, catalog revocation, stale selection replies and missing entitlements; #86/#88 implemented native read-only provider and auth/model queries. None of this grants a new executable model binding by itself.
- **API-key UI:** #89 added scoped revocation confirmation, and #90 gates prompts on the launcher's exact authorized credential profile (#1011 runtime). Stored keys remain unverified until a real provider authenticates; approved OAuth and genuine runtime-authorized persisted model switching remain open.
- **Distribution:** #147/#148 merged installed provider-management pinning. Distribution D4 is partly integrated, not an end-to-end authenticated-model acceptance.

As of this revision, **N0–N3 accepted; N4–N6 not accepted; C1–C7 planned**. Treat the historical SHA/evidence paragraphs below as dated snapshots, not current next-action tickets. Do not repeat already merged SDK, tool or picker implementations.

## Authority and references

This file tracks implementation order and acceptance in the standalone client. It does not redefine the runtime or the existing integration contracts.

- [Phenix M1 roadmap](https://github.com/matthis-k/phenix-ai/blob/main/spec/m1-roadmap.md), especially post-P1 session projections, P2-IO1 through P2-IO4, A2UI and I/O.
- [Phenix Advanced roadmap](https://github.com/matthis-k/phenix-ai/blob/main/spec/p2-advanced-agent-roadmap.md), for memory, workspace, jobs, session trees, code intelligence and inspection.
- [Runtime management issue #891](https://github.com/matthis-k/phenix-ai/issues/891), for authorized model/routing/configuration changes, durable follow-ups, approval, subscriptions and shared sessions.
- [Merged P1 client #48](https://github.com/matthis-k/phenix-ai.nvim/pull/48) (`aefc618f`) and [default cutover #50](https://github.com/matthis-k/phenix-ai.nvim/pull/50) (`2bc128a7`), for the installed Basic ACP SDK/UI and N3 package acceptance. The client contract is in `spec/p1-client-sdk.md`; missing management remains in runtime #891.
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
| N4: authorized management and queue **(P1/P2 priority)** | N3; runtime #891/P2-IO1 as APIs arrive | Implement `:Phenix auth` and `:Phenix model` through the runtime SDK. Provider list groups distinct configured connections (protocol, URL, method and discovery metadata), shows only provider-advertised auth choices, and skips the method picker for zero/one choices. Render secure API-key input or the provider-approved OAuth flow without retaining secrets in Neovim. Display only currently usable authenticated/no-auth model choices, including discovery/static origin and thinking variants. Submit connection-scoped, revision-checked selection. Continue with routing/scoped settings, session list/load/close and durable queued/interrupting input; never copy runtime catalogs or credential storage. | Real packaged Neovim: provider -> one/both auth methods -> model -> prompt; dynamic/static and auth-specific model lists; both methods valid and individually revoked; secrets never enter transcript, journal or logs; provider/connection/model selection survives reconnect; denied/stale/expired credentials and model mutations fail closed; existing follow-up and restart tests remain green. |
| N5: editor integration completion | N3; N4 only for privileged actions | Finish the existing `phenix_nvim.integrations` and `phenix_nvim.tools` contracts. Register bounded default context/navigation/review tools via normal client-tool admission, retain optional permission-gated Lua eval/exec/reload, and present file references/diffs/images where the selected runtime transport supports them. | Tests from `nvim-integrations-implementation.md` pass against the selected runtime. Disabled tools are absent; denied privileged calls never execute. One live handler per session/client generation. |
| N6: P1 frontend acceptance | N3; N4/N5 for declared parity | Audit command inventory, remove dead compatibility branches, test close/reconnect and log/inspection degradation where P1 does not expose the service. Publish a precise feature matrix. | No fallback to legacy. Full packaged Basic story and independent ACP client interop pass on one pinned pair of runtime/client SHAs. All unsupported features fail explicitly; no claim of parity for missing #891 services. |

**Cutover rule.** N3 is the minimum P1 Neovim milestone. N4/N5 restore the broader interactive feature set as the runtime exposes authorized contracts. N6 is accepted only for the actual declared feature matrix, not on the basis of a mock-only SDK test. No P2 Advanced implementation is required to make Basic chat usable.

**Priority override (2026-10-17):** N4's authentication and usable-model picker are prerequisites for calling either the live Basic UX or Advanced P2 Neovim product ready for end users. This is not a new protocol or a Neovim-only provider registry. The runtime's [#891](https://github.com/matthis-k/phenix-ai/issues/891) and [M1 roadmap](https://github.com/matthis-k/phenix-ai/blob/main/spec/m1-roadmap.md) own method, connection and model semantics. Prioritize this thin UI/SDK flow ahead of P2 A2UI polish; preserve P1's accepted deterministic baseline.

## Coding handoff for N4–N6

The N4–N6 table owns milestone status. The following packets identify the
files and first executable tests for a fresh-session coding model. Use the
existing `phenix_client` and `phenix_nvim.runtime_p1` modules; the exact
private Lua file split is an implementation choice. Do not implement a new
runtime management store in Lua to compensate for an unavailable Phenix
operation.

| Order | Existing entry points | Implement and verify |
| --- | --- | --- |
| **N4a: read catalog** | `lua/phenix_client/init.lua`, `lua/phenix_client/acp.lua`, `lua/phenix_nvim/runtime_p1.lua`, `tests/p1_model_picker.lua` | Map the runtime's provider/connection/profile/model metadata to the existing client query and Neovim picker. Keep the effective revision and provenance. Add a RED transport test: same display name on two connections must remain distinguishable; an unauthenticated connection is visible in auth setup but its unusable models are absent from model selection. Do not synthesize a provider catalog from local config. |
| **N4b: API-key and OAuth actions** | Existing `phenix_nvim.integrations` picker/forms and `phenix_client` request/response API, runtime #891 | Query offered methods. No methods means ready/no prompt, one begins directly, multiple show a picker. Accept API keys only through the runtime's dedicated secret-safe submission flow and dispose prompt buffers/results immediately. Browser/device OAuth launch and status are displayed from authorized runtime operations. If a transport lacks those operations, return `unsupported` and keep the UI functional. Tests must ensure credentials never reach transcript, normal model events or persistent Neovim projection. |
| **N4c: selection and race** | `lua/phenix_client/acp.lua`, `lua/phenix_nvim/runtime_p1.lua`, `tests/p1_client_transport.lua`, `tests/p1_ui_product.lua` | Apply the accepted ACP catalog/selection projection from [#78](https://github.com/matthis-k/phenix-ai.nvim/pull/78); propagate model updates to the editor, cancel open picker callbacks on revocation and use the current session catalog. Reuse standard ACP `session/set_config_option` only where the runtime supports it. The remaining runtime #891 operation must check provider/connection/profile/model identity and revision; update the UI only from confirmed runtime state. Test stale revision, denial, revoked profile, reconnect and two clients. |
| **N5a: default editor tools** | `lua/phenix_nvim/tools.lua`, `spec/nvim-integrations-implementation.md`, runtime-negotiated client-tool admission | Register one bounded, read-only editor context/navigation tool, then a review action. Advertise only currently installed/allowed tools; execute a handler only on the current authorized client generation. Negative fixture must prove a disabled or revoked tool never runs. Optional Lua eval/exec stays separately permission-gated. |
| **N5b: UI/callback lifecycle** | `lua/phenix_nvim/runtime_p1.lua`, transcript and compose controllers, `tests/p1_ui_product.lua` | Test the existing submit/queue/cancel/reopen journey during reconnect and buffer close. Remove stale callback handles and re-query runtime state; the frontend must not replay a request merely to repair its projection. Assert ordered user/tool/assistant events and no duplicate accepted follow-up. |
| **N6: final cutover proof** | `tests/p1_client_transport.lua`, `tests/p1_ui_product.lua`, `tests/p1_model_picker.lua`, `flake.nix` | Extend the real installed P1 product check with API-key onboarding, usable model selection, prompt, restart and a denied request. Record exact tested runtime/client SHAs and the features that remain unsupported. Keep the existing Basic SDK/protocol tests; only claim a feature once its runtime operation exists. |

### P2 client handoff after N4

| Packet | Start here | First RED integration result |
| --- | --- | --- |
| **C1–C2: projections and commands** | `phenix_client` subscription/query/action API and `phenix_nvim.runtime_p1`; runtime P2-IO1/IO2 | Two connected clients attach with separate cursors. A session change refreshes both projections; stale/denied mutation changes neither. Rebind to a new generation and revoke stale handlers. |
| **C3: registry** | Existing `phenix_nvim.integrations` registry, `spec/nvim-integrations-implementation.md`, selected upstream A2UI schema | Add a Lua table registry for one text component, then input/button and recursive card. Make override, removal and catalog advertisement reflect actual supported implementations. Malformed nesting/data binding rejects before any UI handle exists. |
| **C4–C5: negotiation and actions** | C3 renderer, runtime-selected A2UI catalog and supported transport | A text-only client cannot receive Form/SVG; a separately authorized client with the correct pinned catalog can render allowed controls. Reject forged/stale actions before Lua callback execution. Reconnect and window close invalidate old callbacks. |
| **C6–C7: Advanced UI** | Existing transcript, sidebar and navigation integrations; runtime P2-4–P2-9 read-only projections | Add one source-backed stale-code view, job log cursor and child-session entry at a time. Real Advanced-verification product must survive restart, while Basic package runs with no Advanced plugin. Independent ACP interop remains a separate gate. |

For each packet, read the relevant accepted runtime contract *first*. Write a
failing Lua transport/renderer test and, where the feature crosses into the
runtime, a packaged Neovim test. Run the repository's existing Neovim test
commands and the pinned Nix check from `flake.nix` on the exact head.
Leave Lua helper layout, picker styling, buffer internals and renderer details
to the implementation model. Stop if a runtime operation, A2UI transport
facility or authority rule is missing; link the runtime owner instead of
inventing a new wire method or permissive local fallback.

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

## Current acceptance and outstanding stages

P1 Basic runtime is accepted. **N0–N3: 4 accepted; N4–N6: 3 open/partial; C1–C7: 7 planned.** Scoped ACP API-key import/revoke, non-secret authorized profile discovery, native read-only provider/auth/model queries, editor picker race/denial guards and bounded local context tooling now exist (#86–#90 and preceding fixes). Provider-*verified* authentication, actual selected-provider executable dispatch, runtime-owned revision-CAS model mutations, durable admitted follow-ups and full negotiated client tools are **not** accepted. Keep N5/N6 open until independent installed runtime and authority tests pass.

Release evidence: [#48](https://github.com/matthis-k/phenix-ai.nvim/pull/48) merged at `aefc618f`; [#50](https://github.com/matthis-k/phenix-ai.nvim/pull/50) merged at `2bc128a7` after exact-head Source, Client integration and `lua-client` checks passed. The N3 default closure is the P1 Basic ACP plugin with no native `phenix.so`; `checks.<system>.p1-default-cutover` and `p1-product` exercise the installed product. The optional live HTTP Model remains a distinct composition.

Presentation evidence: [#52](https://github.com/matthis-k/phenix-ai.nvim/pull/52) merged at `36bc9a87` for compact/human/protocol tool disclosure, and [#47](https://github.com/matthis-k/phenix-ai.nvim/pull/47) merged at `3d42a4ab` for the bounded, display-only local UI renderer. Both run inside `p1-default-cutover`; neither is A2UI negotiation or a runtime catalog. N4 remains blocked on the runtime-owned provider/auth/model operations from [#891](https://github.com/matthis-k/phenix-ai/issues/891); N5/N6 stay open until those operations and the declared integration matrix are verified.

Phase 0 client hardening (2026-10-18): `tests/p1_transcript_tail.lua`,
`tests/p1_transcript_updates.lua` and `tests/p1_transcript_disclosure.lua`
reproduce deprecated nonempty-tail indexing, first/middle node grow/shrink
corruption on subsequent updates, and highlights covering the disclosure marker
or a status substring in a callable name at baseline `82a2a2f`. They pass after
the focused renderer fixes on Neovim 0.12.4 and 0.13.0-nightly+7737589 with
deprecations fatal. Coverage includes ASCII, emoji, multibyte and combining
tails, wrapped follow-tail, three-node boundaries, disclosure routing, and exact
highlighted bytes for all three statuses and compact/human/protocol markers.
The same tests run in the existing SDK workflow and installed
`p1-default-cutover` flake check. This is local presentation/API maintenance,
not runtime/distribution work or acceptance of N4, N5, N6 or any P2 stage.

Cross-repository distribution promotion lives in [phenix-nvim #117](https://github.com/matthis-k/phenix-nvim/pull/117) and its distribution roadmap, rather than being inferred from client acceptance.

Runtime pin integration (2026-10-18): `flake.lock` now resolves runtime
`fa7135c896b0c6cb66c02c0fed40bbe2acb2868d` (merged runtime #971/#972), with
Nix-resolved source hash `sha256-9gzB1/VS8857THd/UTF5oTuCMwERERqQ/1iC4LqYX8A=`.
Upstream actual-main [Nix CI run 39078891177](https://github.com/matthis-k/phenix-ai/actions/runs/39078891177)
and [official ACP interop run 39078890848](https://github.com/matthis-k/phenix-ai/actions/runs/39078890848)
passed on that exact runtime revision. The P1 workflow no longer overrides the
lock with `8ad88aec`; both installed-product CI gates test the locked runtime.
Local `nix flake check -L` passed `provider-auth-ui`, `p1-default-cutover` and
`p1-product` on x86_64-linux (aarch64-linux was not executed). The 12 deterministic
SDK workflow tests plus `p1_model_config` and `structured_ui`, and the installed
`p1_package_default`, `p1_client_product`, `p1_ui_product` and
`p1_startup_recovery` tests passed on Neovim 0.12.4 and
0.13.0-dev-1892+g9b7ec59580. This verifies the pinned deterministic Basic
integration and existing auth/model UI fixtures, not operational authentication,
live-provider onboarding, N4/N5/N6 acceptance or distribution promotion.

Runtime #973 pin promotion (2026-10-18): following client #63, `flake.lock`
resolves merged runtime `892388d76ef2f07e934c6922cb8cedc4cc5f6b7c` with
Nix-resolved source hash `sha256-d6RpBbJ0MMPWoHC9c3fHU0ivG0JJDunqWQgZ/+K0BjE=`;
nixpkgs is unchanged. All existing upstream actual-main workflows passed on
that exact revision, including the Nix matrix and official ACP interop.
Local `nix flake check -L` passed `provider-auth-ui`, `p1-default-cutover` and
`p1-product` on x86_64-linux, exercising the installed client and pinned Basic
ACP runtime, chat/UI, SQLite replay and failed-launch recovery; aarch64-linux
was not executed. Existing client CI continues to test the lock unchanged.
This is deterministic integration verification only: the independently packaged
OS Secret Service backend does not establish operational authentication,
live-provider onboarding, N4/N5/N6 acceptance or distribution promotion.
The distribution must pin this promoted client together with the same runtime;
no runtime or distribution files are changed here.

Runtime #974 pin promotion (2026-10-18): `flake.lock` now resolves merged
runtime `562c9531b05d16ff4f7d01052844e5ad3c0a8a35` (runtime #974, additive
Responses/Anthropic inference codecs; no client API change) with Nix-resolved
source hash `sha256-kiXnujPcNUEAt8TlXvWzvgZFJR+QJuUS1r2rEwprjSY=`; nixpkgs is
unchanged. Upstream actual-main workflows passed on that exact revision:
[Nix CI run 39097066582](https://github.com/matthis-k/phenix-ai/actions/runs/39097066582),
[official ACP interop run 39097066381](https://github.com/matthis-k/phenix-ai/actions/runs/39097066381),
[formatting run 39097066274](https://github.com/matthis-k/phenix-ai/actions/runs/39097066274) and
[flake CI caller run 39097066359](https://github.com/matthis-k/phenix-ai/actions/runs/39097066359).
Local `nix flake check -L` passed `provider-auth-ui`, `p1-default-cutover` and
`p1-product` on x86_64-linux (aarch64-linux was not executed). Existing client
CI continues to test the lock unchanged. This is deterministic lock verification
only: the additive codecs do not establish operational authentication,
live-provider onboarding, N4/N5/N6 acceptance or distribution promotion. The
distribution must pin this promoted client together with the same runtime; no
runtime or distribution files are changed here.

Runtime #975/#976 pin promotion (2026-10-18): `flake.lock` now resolves merged
runtime `70e33b7e225664562466f19ba2f258ab68456435` (additive Basic deterministic
streaming fixture #975 and P2-3al staged graph re-preparation #976; no client API
change) with Nix-resolved source hash
`sha256-mU1n1HkhKj0VBGesHip4T5buE7sZ+n+X3XIl6ZxHObM=`; nixpkgs is unchanged.
Upstream actual-main workflows passed on that exact revision:
[Nix CI run 39109650327](https://github.com/matthis-k/phenix-ai/actions/runs/39109650327),
[official ACP interop run 39109649979](https://github.com/matthis-k/phenix-ai/actions/runs/39109649979),
[formatting run 39109649881](https://github.com/matthis-k/phenix-ai/actions/runs/39109649881) and
[flake CI caller run 39109649899](https://github.com/matthis-k/phenix-ai/actions/runs/39109649899).
Local `nix flake check -L` passed `provider-auth-ui`, `p1-default-cutover` and
`p1-product` on x86_64-linux (aarch64-linux was not executed). Existing client
CI continues to test the lock unchanged. This is deterministic lock verification
only: the additive streaming fixture and graph re-preparation do not establish
operational authentication, live-provider onboarding, N4/N5/N6 acceptance or
distribution promotion. The distribution must pin this promoted client together
with the same runtime; no runtime or distribution files are changed here.

N4c projection continuation (historical 19 October, reconciled 20 October): client [#78](https://github.com/matthis-k/phenix-ai.nvim/pull/78) implemented ACP `config_option_update` catalog replacement/revocation, and [#79](https://github.com/matthis-k/phenix-ai.nvim/pull/79) already invalidated open picker callbacks. Distribution [#139](https://github.com/matthis-k/phenix-nvim/pull/139) and later [#147](https://github.com/matthis-k/phenix-nvim/pull/147)/[#148](https://github.com/matthis-k/phenix-nvim/pull/148) merged their respective tested pin/management slices. Do not queue picker invalidation or #139 promotion again. Runtime [#891](https://github.com/matthis-k/phenix-ai/issues/891) still owns executable provider/account selection, verified readiness, persistent revision CAS and durable admitted queues. N5 editor work not requiring new authority may continue in parallel; N6 closes only on the full installed parity matrix.

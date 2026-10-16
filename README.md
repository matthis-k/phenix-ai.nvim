# Phenix AI.nvim

Canonical Neovim client for Phenix AI.

This repository owns the Neovim-specific Lua client, UI, interaction model, product acceptance, and Nix package. It depends on `matthis-k/phenix-ai` for the frontend-neutral runtime, host-neutral Lua binding, and ACP/default-Harness executable.

## P1 backend preview

The existing Neovim windows, compose buffers, transcript renderer and keymaps can
use the P1 runtime without the old native Lua module:

```lua
require("phenix_nvim").setup({
  backend = "p1",
  command = "phenix-basic-acp",
  auto_connect = true,
})
```

The command must resolve to the packaged **P1 ACP** executable. Neovim
configures only the client connection. The Phenix composition owns its model,
tools, permissions, storage and execution policy. Do not set `env`,
`state_directory`, `log_directory` or `log_depth` in P1 mode.

P1 mode currently supports creating and resuming sessions by ID with
`:Phenix session load <id>`, text and
resource-link prompts, cancellation, tool events and assistant streaming in
the same transcript UI. `:Phenix select` displays the model binding reported
by Phenix, without allowing an unsupported change. `:Phenix session select`
lists only sessions created or loaded by this process; ACP v1 does not yet
offer global persistent session enumeration. Model switching, authentication,
routing changes, session close, images, client-side tool registration, logs
and permission decisions still require Phenix runtime operations.
Those features remain in the existing legacy UI but **do not silently
fall back to legacy when using P1**.

The Lua bridge is `require("phenix_client")`. It exposes operations,
subscriptions and runtime-owned model catalogs, independent of Neovim's
presentation. The P1 renderer adapter is
`require("phenix_client.transcript")`. See `spec/p1-client-sdk.md`
and the companion runtime PR for details.

## Nix

`packages.<system>.default` and `packages.<system>.phenix-ai-nvim` expose the complete plugin. The package installs the matching native `phenix` Lua module and configures the client to launch the matching packaged `phenix` product with `--mode acp`.

`packages.<system>.phenix-ai-nvim-provider-acceptance` runs the credentialed real-provider acceptance when `OPENAI_API_KEY` is set. `nix flake check` owns deterministic client, image, interaction, packaged-runtime, and restart/resume coverage.

`phenix-nvim` consumes this package. Phenix AI core does not depend on this repository.

The flake follows `github:matthis-k/phenix-ai`, and `flake.lock` pins the exact Phenix AI and transitive Nix dependency graph used by the standalone client. Normal validation does not update that lock implicitly.

## Opt-in real-model P1 test

With the HTTP preset from [phenix-ai PR #933](https://github.com/matthis-k/phenix-ai/pull/933),
the `phenix-ai-nvim-live` Nix output installs the normal Neovim UI but
launches `phenix-basic-http-acp` through the same P1 Lua SDK. It contains
no oldmain native Lua module or alternative protocol. The scripted
`phenix-ai-nvim-basic` output remains available for deterministic testing.

Set a real credential **in the shell environment**, then launch a prompt:

```sh
export OPENAI_API_KEY="..."  # or PHENIX_MODEL_HTTP_API_KEY
export PHENIX_MODEL_HTTP_MODEL="gpt-4.1-mini"
# Until the default lock is switched to M1, select the tested P1 runtime:
nix run \
  --override-input phenix-ai github:matthis-k/phenix-ai/8ad88aec18c34034beb53afc385af370771488b3 \
  .#phenix-ai-nvim-live-prompt -- "Describe the tools you can call"
```

The prompt runner puts the assistant response on stdout and session/model
diagnostics on stderr. The unmodified default lock remains on the legacy
runtime, so the live output requires the explicit override until cutover.

For interactive use, install `phenix-ai-nvim-live` in Neovim, then run
`:Phenix new`, write the prompt into the existing compose window and submit
with the ordinary UI. `:Phenix capabilities` shows the ACP-negotiated
session operations, available management operations, and selected Model
identity. It is an observation, not an authorization grant.

The HTTP endpoint defaults to OpenAI's compatible chat-completions URL;
use `PHENIX_MODEL_HTTP_ENDPOINT` for a different compatible provider.
The runtime manages the SQLite state file. Neovim never reads the API key
or stores it in its configuration. Model routing/authentication changes,
arbitrary editor tools, and interactive A2UI are not yet P1 features.

This opt-in package and runner are conditional on the selected `phenix-ai`
flake exporting `phenix-basic-http-acp`. Before merging the runtime PR,
a developer can test by overriding the `phenix-ai` flake input to
`github:matthis-k/phenix-ai/feat/p1-basic-http-real-model-preset-20261016`.

## Basic P1 migration package

The P1 migration currently ships an additional `phenix-ai-nvim-basic` package when
the selected `phenix-ai` flake exposes `phenix-basic-acp`. This package contains
the normal Neovim UI and standalone Lua client. Its defaults start the exact
packaged Basic ACP binary, select `backend = "p1"`, and do not install the
old native Lua binding. The existing `phenix-ai-nvim` package stays on its
legacy default until the Basic cutover is accepted.

The `p1-product` Nix check uses the installed Basic-only plugin and the real
P1 runtime to verify chat, tool calls, restart, and journal replay. It is
published only when the selected runtime has the Basic ACP artifact. The
P1 client workflow checks it against an exact M1 revision without changing
the legacy flake lock. Model mutation, provider authentication, session
enumeration/close, images, and logs remain unavailable through P1 ACP v1;
the frontend reports unsupported operations rather than using oldmain.

See [the client roadmap](spec/p1-p2-client-roadmap.md) for the acceptance
sequence and [runtime issue #891](https://github.com/matthis-k/phenix-ai/issues/891)
for authorized management contracts.

## Connection lifecycle

Requests made while connecting wait for readiness. `new_session(callback)` completes after the durable session is created. Model and authentication preferences are owned by Phenix and do not need a session. `disconnect()` cancels queued and pending callbacks and closes the owned runtime. Runtime failure settles pending work with its cause; call `connect()` explicitly to retry. Delayed authentication and selection UI callbacks cannot affect a replacement connection or session.

The client does not impose execution, request, or prompt deadlines. Phenix owns model/provider failures, retries, cancellation, and any opt-in execution limits. A failed Phenix request settles only that request, so the same live connection can submit the next prompt. The client terminates the connection only when the native process or transport reports a real connection failure.

## Models and authentication

`:Phenix select` works before a session exists. The model picker is built from Phenix discovery data. Phenix owns provider
display names, so the UI does not expose internal provider ids as labels. The
flow is:

```text
provider -> model -> thinking, when Phenix exposes multiple thinking variants
```

When a model has one effective variant, selecting the model applies it directly
instead of opening a one-item "default" thinking picker.

The plugin does not keep a provider or model allow-list. Phenix reports each
fixed model selection with its provider, model id, thinking level, and current
authentication state. Provider catalogs may attach thinking metadata to known
model ids without declaring those ids as available. This keeps remote model
enumeration dynamic while allowing provider-owned capability metadata. The
plugin does not know whether a model came from standards-based provider
discovery, a provider-declared catalog, or another Phenix catalog source.

If the selected provider needs authentication and no usable credential is
available, the plugin asks for one of the authentication methods reported by
Phenix. API-token providers use a secret input and Phenix stores the token in
its credential store. OAuth providers keep their provider-owned external flow.
`:Phenix auth` exposes the same discovered methods directly.

The selected model is stored as Phenix's global `model.default` option. New
sessions inherit it. Selecting a model while a session is active also updates
that session so the visible chat switches immediately.

Environment credentials remain valid inputs to provider discovery. They are
resolved by Phenix, not interpreted by the Neovim plugin.

The ownership boundary is strict:

- Phenix AI owns provider definitions, model catalog production, authentication,
  credential persistence, default selection persistence, derived direct-model
  routes, and explicit routing policy.
- Provider plugins may discover models through a supported protocol standard or
  declare models when no discovery standard exists.
- Phenix AI.nvim owns presentation and interaction only. It groups the normalized
  catalog as `provider -> model -> thinking` when thinking variants exist, asks
  for credentials when Phenix reports that authentication is required, and
  submits the chosen IDs back to Phenix. Provider labels also come from Phenix.
- A provider discovered only through authentication is still shown. After
  authentication, the plugin reloads Phenix selections and continues into the
  model picker.
- Phenix AI.nvim does not contain discovery URLs, provider-specific model names,
  API-key environment mappings, or provider compatibility tables.

## Persistence

Phenix owns the persistence formats and defaults. With no client setting it
uses its normal XDG state location. The client may choose only the root
directory:

```lua
require("phenix_nvim").setup({
  state_directory = vim.fn.stdpath("state") .. "/phenix",
})
```

That setting is passed as `PHENIX_STATE_DIR`. The runtime currently places its
application database, provider credential store, and OAuth credential store
under that root. Set `state_directory = false` to leave location selection
entirely to the inherited environment and Phenix defaults.

## Commands

The plugin exposes one command namespace instead of many top-level commands:

```text
:Phenix
:Phenix toggle
:Phenix send
:Phenix cancel
:Phenix reference
:Phenix reference pick
:Phenix reference at <path>
:Phenix image clipboard
:Phenix image <path>
:Phenix logs [session|execution|all]
:Phenix new [sidebar|tab|curr_window|fullscreen]
:Phenix session new
:Phenix session load <id>
:Phenix session close
:Phenix session select
:Phenix auth
:Phenix select
```

`:Phenix` with no subcommand toggles the current chat surface. A visible chat
surface is one real host split with transcript and compose floats anchored to it.
Closing either child with normal Vim window commands closes the whole surface
while preserving its hidden draft. Standard `<C-w>` movement, rotation,
exchange and resize operations are applied to the real host split and the floats
follow it. `<C-w>T` moves the host to a new tab. `<C-w>n` and `<C-w>v`
create another side-by-side chat surface; `<C-w>s` creates one below.
`:Phenix new` is the explicit equivalent for creating another chat; Phenix does
not add separate close or move commands.

Image pasting in the compose buffer uses the same clipboard-image path as
`:Phenix image clipboard`: the clipboard payload is materialized to a temporary
image file, snapshotted into the prompt attachment, and the temporary file is
removed.



## Logging

The client gives Phenix one log directory by default:

```text
stdpath("state")/phenix/
├── phenix.log
└── objects/
    └── sha256/...
```

`phenix.log` is the append-only chronological root. The client defaults to
reference-depth logging, so detailed records are stored in the shared immutable
object tree and referenced from the root log. Referenced objects may contain
further references.

`:Phenix logs` opens a read-only log document for the active session. Use
`:Phenix logs execution` for the active execution or `:Phenix logs all` for
the full local stream. Records stay compact until `<CR>` expands their
structured payload. Semantic labels distinguish agent, model, shell, read,
write, tool, runtime, and failed activity when Phenix records that identity.
Use `]e`/`[e` for failures, `]a`/`[a` for agent events, and
`]t`/`[t` for tool activity. `r` reloads the selected scope and `]l`
loads the next page. References remain visible while collapsed and `gf`,
`gF`, or `gd` open the referenced immutable object through Phenix. The
browser never parses the log directory layout itself.

Set `log_directory = false` to disable the client-provided sink, or set
`env.PHENIX_LOG` explicitly to select another core sink. An explicit legacy
`PHENIX_DEBUG_LOG` is also preserved.

## Non-Nix installs

The Lua source is a normal Neovim plugin, but it requires two runtime artifacts from the matching Phenix AI release: the native `phenix` Lua module and the `phenix` product executable. The client launches that executable with `--mode acp`. The Nix package wires both automatically. A release/install path for those matching artifacts is still required before raw plugin-manager installs are a supported zero-configuration path.

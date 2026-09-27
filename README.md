# Phenix AI.nvim

Canonical Neovim client for Phenix AI.

This repository owns the Neovim-specific Lua client, UI, interaction model, product acceptance, and Nix package. It depends on `matthis-k/phenix-ai` for the frontend-neutral runtime, host-neutral Lua binding, and ACP/default-Harness executable.

## Nix

`packages.<system>.default` and `packages.<system>.phenix-ai-nvim` expose the complete plugin. The package installs the matching native `phenix` Lua module and configures the client to launch the matching packaged `phenix-acp` runtime.

`packages.<system>.phenix-ai-nvim-provider-acceptance` runs the credentialed real-provider acceptance when `OPENAI_API_KEY` is set. `nix flake check` owns deterministic client, image, interaction, packaged-runtime, and restart/resume coverage.

`phenix-nvim` consumes this package. Phenix AI core does not depend on this repository.

The flake follows `github:matthis-k/phenix-ai`, and `flake.lock` pins the exact Phenix AI and transitive Nix dependency graph used by the standalone client. Normal validation does not update that lock implicitly.

## Connection lifecycle

Requests made while connecting wait for readiness. `new_session(callback)` completes after the durable session is created. Model and authentication preferences are owned by Phenix and do not need a session. `disconnect()` cancels queued and pending callbacks and closes the owned runtime. Runtime failure settles pending work with its cause; call `connect()` explicitly to retry. Delayed authentication and selection UI callbacks cannot affect a replacement connection or session.

Startup and ordinary requests default to 30-second deadlines. Prompts default to 10 minutes, including time spent waiting for user interaction. Configure `connect_timeout_ms`, `request_timeout_ms`, and `prompt_timeout_ms` with finite positive durations. A timeout closes the connection and settles outstanding callbacks with a structured `timeout` error. Timed-out mutations may have completed remotely, so the client never retries them automatically. Reconnect and inspect the durable session before repeating a mutation.

## Models and authentication

`:Phenix select` works before a session exists. The model picker is built from
Phenix discovery data and has three steps:

```text
provider -> model -> thinking
```

The plugin does not keep a provider or model allow-list. Phenix reports each
fixed model selection with its provider, model id, thinking level, and current
authentication state. The plugin does not know whether a model came from
standards-based provider discovery, a provider-declared catalog, or another
Phenix catalog source.

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
  credential persistence, default selection persistence, and routing.
- Provider plugins may discover models through a supported protocol standard or
  declare models when no discovery standard exists.
- Phenix AI.nvim owns presentation and interaction only. It groups the normalized
  catalog as `provider -> model -> thinking`, asks for credentials when Phenix
  reports that authentication is required, and submits the chosen IDs back to
  Phenix.
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
:Phenix new [sidebar|tab|curr_window|fullscreen]
:Phenix session new
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

Set `log_directory = false` to disable the client-provided sink, or set
`env.PHENIX_LOG` explicitly to select another core sink. An explicit legacy
`PHENIX_DEBUG_LOG` is also preserved.

## Non-Nix installs

The Lua source is a normal Neovim plugin, but it requires two runtime artifacts from the matching Phenix AI release: the native `phenix` Lua module and `phenix-acp`. The Nix package wires both automatically. A release/install path for those matching artifacts is still required before raw plugin-manager installs are a supported zero-configuration path.

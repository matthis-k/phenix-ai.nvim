# Phenix AI.nvim

Canonical Neovim client for Phenix AI.

This repository owns the Neovim-specific Lua client, UI, interaction model, product acceptance, and Nix package. It depends on `matthis-k/phenix-ai` for the frontend-neutral runtime, host-neutral Lua binding, and ACP/default-Harness executable.

## Nix

`packages.<system>.default` and `packages.<system>.phenix-ai-nvim` expose the complete plugin. The package installs the matching native `phenix` Lua module and configures the client to launch the matching packaged `phenix-acp` runtime.

`packages.<system>.phenix-ai-nvim-provider-acceptance` runs the credentialed real-provider acceptance when `OPENAI_API_KEY` is set. `nix flake check` owns deterministic client, image, interaction, packaged-runtime, and restart/resume coverage.

`phenix-nvim` consumes this package. Phenix AI core does not depend on this repository.

The flake follows `github:matthis-k/phenix-ai`, and `flake.lock` pins the exact Phenix AI and transitive Nix dependency graph used by the standalone client. Normal validation does not update that lock implicitly.

## Connection lifecycle

Requests made while connecting wait for readiness. `new_session(callback)` completes only after preferred routing is applied; a missing preferred route returns an error. `disconnect()` cancels queued and pending callbacks and closes the owned runtime. Runtime failure settles pending work with its cause; call `connect()` explicitly to retry. Delayed authentication and selection UI callbacks cannot affect a replacement connection or session.

Startup and ordinary requests default to 30-second deadlines. Prompts default to 10 minutes, including time spent waiting for user interaction. Configure `connect_timeout_ms`, `request_timeout_ms`, and `prompt_timeout_ms` with finite positive durations. A timeout closes the connection and settles outstanding callbacks with a structured `timeout` error. Timed-out mutations may have completed remotely, so the client never retries them automatically. Reconnect and inspect the durable session before repeating a mutation.

## Authentication

Routing defaults to `auto`: when a configured API-key environment variable is
present, the client prefers that provider's route; otherwise it prefers
`router.chatgpt-plus` and the existing ChatGPT OAuth flow. Set `selection`
explicitly to override this behavior, or to `false` to leave routing entirely
to the runtime. Resume reconciliation uses typed provider metadata from the
runtime, so changes to route descriptions do not change routing behavior.

API-key routes can be supplied directly in the environment:

```sh
OPENAI_API_KEY=... nvim
# or
OPENCODE_API_KEY=... nvim
```

The automatic route follows the configured credential: OpenAI selects
`router.openai-api`; OpenCode selects `router.opencode-go`. If neither is
present, ChatGPT OAuth remains the preferred route.

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
:Phenix session new
:Phenix session close
:Phenix session select
:Phenix window new
:Phenix window close
:Phenix window move <left|right|up|down|tab>
:Phenix auth
:Phenix select
```

`:Phenix` with no subcommand toggles the current chat surface. A visible chat
surface is one real host split with transcript and compose floats anchored to it.
Closing either child closes the whole surface while preserving its hidden draft.
Structural `<C-w>` operations are redirected to the host: movement, rotation,
exchange and resizing move the real split and the floats follow it. `<C-w>T`
moves the host to a new tab and recreates its child floats there. `<C-w>n` and
`<C-w>v` create another side-by-side chat surface; `<C-w>s` creates one below.

Image pasting in the compose buffer uses the same clipboard-image path as
`:Phenix image clipboard`: the clipboard payload is materialized to a temporary
image file, snapshotted into the prompt attachment, and the temporary file is
removed.


or only to the Phenix child process:

```lua
require("phenix_nvim").setup({
  env = {
    OPENAI_API_KEY = "...",
  },
})
```

`:Phenix auth` exposes both runtime authentication methods and frontend API-key
providers. If the selected API key is not already available through its
environment variable, the client opens a secret input field, reconnects the
Phenix ACP child with the entered value, resumes the active session, and selects
the provider's route. The entered key is kept in the client runtime environment;
it is not added to Phenix log records or written into the Neovim configuration.

Additional API-key providers can use the same frontend mechanism:

```lua
require("phenix_nvim").setup({
  api_key_providers = {
    {
      id = "example",
      name = "Example API key",
      env = "EXAMPLE_API_KEY",
      selection = "router.example",
    },
  },
})
```

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

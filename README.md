# Phenix AI.nvim

Canonical Neovim client for Phenix AI.

This repository owns the Neovim-specific Lua client, UI, interaction model, product acceptance, and Nix package. It depends on `matthis-k/phenix-ai` for the frontend-neutral runtime, host-neutral Lua binding, and ACP/default-Harness executable.

## Nix

`packages.<system>.default` and `packages.<system>.phenix-ai-nvim` expose the complete plugin. The package installs the matching native `phenix` Lua module and configures the client to launch the matching packaged `phenix-acp` runtime.

`packages.<system>.phenix-ai-nvim-provider-acceptance` runs the credentialed real-provider acceptance when `OPENAI_API_KEY` is set. `nix flake check` owns deterministic client, image, interaction, packaged-runtime, and restart/resume coverage.

`phenix-nvim` consumes this package. Phenix AI core does not depend on this repository.

The flake follows `github:matthis-k/phenix-ai`, and `flake.lock` pins the exact Phenix AI and transitive Nix dependency graph used by the standalone client. Normal validation does not update that lock implicitly.

## Authentication

Routing defaults to `auto`: when a configured API-key environment variable is
present, the client prefers that provider's route; otherwise it prefers
`router.chatgpt-plus` and the existing ChatGPT OAuth flow. Set `selection`
explicitly to override this behavior, or to `false` to leave routing entirely
to the runtime.

API-key routes can be supplied directly in the environment:

```sh
OPENAI_API_KEY=... nvim
# or
OPENCODE_API_KEY=... nvim
```

The automatic route follows the configured credential: OpenAI selects
`router.openai-api`; OpenCode selects `router.opencode-go`. If neither is
present, ChatGPT OAuth remains the preferred route.

or only to the Phenix child process:

```lua
require("phenix_nvim").setup({
  env = {
    OPENAI_API_KEY = "...",
  },
})
```

`:PhenixAuth` exposes both runtime authentication methods and frontend API-key
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

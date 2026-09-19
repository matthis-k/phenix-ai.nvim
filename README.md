# Phenix AI.nvim

Canonical Neovim client for Phenix AI.

This repository owns the Neovim-specific Lua client, UI, interaction model, product acceptance, and Nix package. It depends on `matthis-k/phenix-ai` for the frontend-neutral runtime, host-neutral Lua binding, and ACP/default-Harness executable.

## Nix

`packages.<system>.default` and `packages.<system>.phenix-ai-nvim` expose the complete plugin. The package installs the matching native `phenix` Lua module and configures the client to launch the matching packaged `phenix-acp` runtime.

`packages.<system>.phenix-ai-nvim-provider-acceptance` runs the credentialed real-provider acceptance when `OPENAI_API_KEY` is set. `nix flake check` owns deterministic client, image, interaction, packaged-runtime, and restart/resume coverage.

`phenix-nvim` consumes this package. Phenix AI core does not depend on this repository.

The flake follows `github:matthis-k/phenix-ai`, and `flake.lock` pins the exact Phenix AI and transitive Nix dependency graph used by the standalone client. Normal validation does not update that lock implicitly.

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

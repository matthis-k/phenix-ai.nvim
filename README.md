# Phenix AI.nvim

Neovim frontend for the [Phenix AI](https://github.com/matthis-k/phenix-ai) M1/P1 Basic agent. The supported Nix default is the real ACP client; no oldmain native Lua binding, agent loop or compatibility backend is packaged.

## Packages

- `phenix-ai-nvim` (also `default` and `phenix-ai-nvim-basic`): installed Basic ACP client, with the runtime's scripted Model for deterministic use.
- `phenix-ai-nvim-live`: the same Neovim UI connected to the runtime's HTTP Model.
- `phenix-ai-nvim-live-prompt`: headless real-model prompt runner (answer on stdout; diagnostics on stderr).

All outputs use the same `phenix_client` Lua SDK, Neovim UI and ACP v1 transport. The flake lock pins the matching Phenix M1 runtime; the distribution must follow this client/runtime pair.

## Interactive use

Install the plugin into Neovim and configure the normal frontend:

```lua
require("phenix_nvim").setup({ auto_connect = true })
```

The Basic package supplies its exact ACP executable without needing a PATH lookup. Editor presentation overrides such as `side`, `width` and `compose_height` are permitted. The client must not configure Phenix's credentials, process environment, state store, graph, logging policy or execution limits.

Use `:Phenix new` to open a chat, write into the compose window, and press Enter in normal mode or write the buffer to submit. The transcript, tool activity, multiple Neovim chat surfaces and status projection are rendered by the existing client UI. `:Phenix session load <id>` restores a durable session from the runtime's journal. `:Phenix cancel` requests cancellation, and `:Phenix capabilities` displays capabilities advertised by the connected runtime.

Model identity is read from ACP session configuration. `:Phenix select` can display that catalog, but the runtime does not yet expose authorized model mutation. Session listing is partial (sessions known to this connection). Full session discovery/close, routing changes, authentication menus, client-side tool admission, logs and image prompts remain unavailable in P1 and must report unsupported rather than falling back to a legacy client. Text and resource-link prompts are supported.

## Live HTTP Model

Supply credentials only to the runtime's process environment:

```sh
export OPENAI_API_KEY="..."  # alternatively PHENIX_MODEL_HTTP_API_KEY
export PHENIX_MODEL_HTTP_MODEL="gpt-4.1-mini"
nix run .#phenix-ai-nvim-live-prompt -- "Describe your available tools"
```

Set `PHENIX_MODEL_HTTP_ENDPOINT` for another OpenAI-compatible chat-completions endpoint. The default product does not incur an API charge: the live Model is opt-in. CI uses a local HTTP streaming fixture, not provider credentials.

## Contracts and verification

The runtime exclusively owns sessions, graph execution, model/provider catalogs, permissions, storage and durable history. `phenix_client` forwards ACP requests and subscribes to events. `phenix_nvim.runtime` projects those responses into the existing sidebar/transcript/compose controls, never a second authoritative state store.

`nix flake check -L` validates the installed P1 default and Basic ACP product. The product acceptance covers real Neovim chat, two turns with tool calls, resource links, failure/retry of a missing ACP executable and replay of SQLite-journal history. Unit tests cover request/permission validation and callback lifetime. No oldmain code path is exercised or shipped.

See [the client roadmap](spec/p1-p2-client-roadmap.md), [P1 SDK contract](spec/p1-client-sdk.md) and [runtime management issue #891](https://github.com/matthis-k/phenix-ai/issues/891). Advanced agent, MCP client-contributed capabilities and A2UI negotiation are additive later work, not alternative P1 backends.

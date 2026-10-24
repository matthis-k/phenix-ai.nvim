# Phenix AI.nvim

Neovim frontend for the [Phenix AI](https://github.com/matthis-k/phenix-ai) M1/P1 Basic agent. The supported Nix default is the real ACP client; no oldmain native Lua binding, agent loop or compatibility backend is packaged.

## Packages

- `phenix-ai-nvim` (also `default` and `phenix-ai-nvim-basic`): installed Basic ACP client, with the runtime's scripted Model for deterministic use.
- `phenix-ai-nvim-live`: the same Neovim UI connected to the runtime's HTTP Model.
- `phenix-ai-nvim-openai-api` (opt-in): verified OpenAI API-key login through the runtime-owned credential store, provider catalog, and account-scoped HTTP model selection.
- `phenix-ai-nvim-p1-auth` (opt-in): one native ACP client for OpenAI API keys (masked input or named environment source) and ChatGPT browser OAuth with provider-owned logout.
- `phenix-ai-nvim-live-prompt`: headless real-model prompt runner (answer on stdout; diagnostics on stderr).

All outputs use the same `phenix_client` Lua SDK, Neovim UI and ACP v1 transport. The flake lock pins the matching Phenix M1 runtime; the distribution must follow this client/runtime pair.

## Interactive use

Install the plugin into Neovim and configure the normal frontend:

```lua
require("phenix_nvim").setup({ auto_connect = true })
```

The Basic package supplies its exact ACP executable without needing a PATH lookup. Editor presentation overrides such as `side`, `width` and `compose_height` are permitted. The client must not configure Phenix's credentials, process environment, state store, graph, logging policy or execution limits.

Use `:Phenix new` to open a chat, write into the compose window, and press Enter in normal mode or write the buffer to submit. The transcript, tool activity, multiple Neovim chat surfaces and status projection are rendered by the existing client UI. `:Phenix session load <id>` restores a durable session from the runtime's journal. `:Phenix cancel` requests cancellation, and `:Phenix capabilities` displays capabilities advertised by the connected runtime.

Model identity is read from ACP session configuration; `:Phenix model` selects from currently authorized runtime choices. The opt-in OpenAI API preset supports `:Phenix auth` for the specifically admitted profile. The default Basic preset remains scripted and its provider management can be metadata-only. Session listing is partial (sessions known to this connection). The combined P1 auth package provides a separately authorized ChatGPT OAuth connection; this does not establish a particular ChatGPT subscription entitlement. Full cross-provider routing, arbitrary account switching, client-side tool admission, logs, and image prompts remain unsupported and must not fall back to a legacy client. Text and resource-link prompts are supported.

## Opt-in verified OpenAI API authentication

Use the `phenix-ai-nvim-openai-api` package (or distribution
`nvim-nix-openai-api`). Create a private credential directory outside the Nix
store and explicitly enable the file backend in the runtime environment:

```sh
mkdir -p "$HOME/.local/state/phenix/openai-api-credentials"
chmod 700 "$HOME/.local/state/phenix/openai-api-credentials"
export PHENIX_CREDENTIAL_FILE_DIRECTORY="$HOME/.local/state/phenix/openai-api-credentials"
export PHENIX_CREDENTIAL_FILE_CONSENT=1
```

Inside Neovim use `:Phenix auth`, enter the OpenAI API key through masked
input for the authorized `openai/api/personal` profile, then create a session
with `:Phenix new`, select an authorized model with `:Phenix model`, and
send a prompt. Credential import never means authenticated: the provider must
check its models endpoint and report the current `Authenticated` status.
`:Phenix auth revoke openai api personal` revokes this profile; session
restart and revoked selected models must not reuse it. Secrets are not
embedded in Nix source, history, ACP model selections, or frontend catalogs.

The opt-in file backend is protected by filesystem permissions but is not
encrypted at rest. Model discovery is not a guarantee of inference quota.
This API-only preset does not implement ChatGPT OAuth. Use the separate
`phenix-ai-nvim-p1-auth` composition for the combined authorized API and
ChatGPT browser sign-in paths.

## Opt-in combined OpenAI API and ChatGPT OAuth authentication

Install `phenix-ai-nvim-p1-auth` or use the corresponding distribution
package `nvim-nix-p1-auth`. Give the runtime an explicitly opted-in private
credential directory outside the Nix store:

```sh
mkdir -p "$HOME/.local/state/phenix/p1-auth-credentials"
chmod 700 "$HOME/.local/state/phenix/p1-auth-credentials"
export PHENIX_CREDENTIAL_FILE_DIRECTORY="$HOME/.local/state/phenix/p1-auth-credentials"
export PHENIX_CREDENTIAL_FILE_CONSENT=1
nix run 'github:matthis-k/phenix-nvim#nvim-nix-p1-auth'
```

Inside Neovim, `:Phenix auth` selects between the runtime-advertised
OpenAI API-key route and ChatGPT browser OAuth. The API key can be entered
through masked input or referenced by an environment-variable name; for
ChatGPT follow the browser challenge and complete its callback. Esc/q cancels
the browser flow. Then use `:Phenix new`, `:Phenix model`, and a prompt.
Sign out the explicit ChatGPT account with
`:Phenix auth revoke openai chatgpt personal` and confirmation.
If remote revocation cannot be confirmed, the UI warns that credentials
were removed locally and **does not claim server-side sign-out**. The
filesystem-protected credential backend is not encrypted at rest.

The combined editor and local deterministic product tests are verified in CI;
external-account eligibility, real inference, refresh and issuer-side
revocation still require a separate live acceptance test. See the
[distribution acceptance checklist](https://github.com/matthis-k/phenix-nvim/blob/main/docs/auth-ux-test.md).

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

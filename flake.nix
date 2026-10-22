{
  description = "Phenix AI Neovim client";

  inputs = {
    phenix-ai.url = "github:matthis-k/phenix-ai";
    nixpkgs.follows = "phenix-ai/nixpkgs";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      phenix-ai,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          source = pkgs.lib.cleanSource ./.;
          basicAcp = phenix-ai.packages.${system}.phenix-basic-acp;
          # The managed host exists only once its runtime implementation is
          # accepted and pinned. Do not alter the default Basic composition.
          hasManaged = builtins.hasAttr "phenix-basic-managed-acp" phenix-ai.packages.${system};
          # No change to default Basic: expose this only when the pinned
          # runtime actually provides the independently authorized preset.
          hasOpenAiApi = builtins.hasAttr "phenix-basic-openai-api-acp" phenix-ai.packages.${system};
          hasChatGpt = builtins.hasAttr "phenix-basic-chatgpt-acp" phenix-ai.packages.${system};
          realAcp = phenix-ai.packages.${system}.phenix-basic-http-acp;
          # Package each P1 composition with the same Neovim client.
          # No native oldmain Lua module is installed in either product.
          mkP1Plugin = pname: acpPackage: executable: pkgs.vimUtils.buildVimPlugin {
            inherit pname;
            version = "0";
            src = source;
            postInstall = ''
              substituteInPlace "$out/lua/phenix_nvim/config.lua" \
                --replace-fail 'command = "phenix-basic-acp"' \
                'command = "${acpPackage}/bin/${executable}"'
              mkdir -p "$out/share/phenix-ai.nvim"
              install -Dm644 ${source}/tests/p1_live_prompt.lua "$out/share/phenix-ai.nvim/p1_live_prompt.lua"
              printf '%s\n' ${pkgs.lib.escapeShellArg (phenix-ai.rev or "dirty")} \
                > "$out/share/phenix-ai.nvim/phenix-ai-revision"
            '';
          };
          p1Plugin = mkP1Plugin "phenix-ai.nvim-basic" basicAcp "phenix-basic-acp";
          managedPlugin = mkP1Plugin "phenix-ai.nvim-managed"
            phenix-ai.packages.${system}.phenix-basic-managed-acp
            "phenix-basic-managed-acp";
          realPlugin = mkP1Plugin "phenix-ai.nvim-live" realAcp "phenix-basic-http-acp";
          openAiApiPlugin = mkP1Plugin "phenix-ai.nvim-openai-api"
            phenix-ai.packages.${system}.phenix-basic-openai-api-acp
            "phenix-basic-openai-api-acp";
          chatGptPlugin = mkP1Plugin "phenix-ai.nvim-chatgpt"
            phenix-ai.packages.${system}.phenix-basic-chatgpt-acp
            "phenix-basic-chatgpt-acp";
          realPrompt = pkgs.writeShellApplication {
            name = "phenix-p1-live-prompt";
            runtimeInputs = [ pkgs.neovim ];
            text = ''
              if [ "$#" -eq 0 ]; then
                echo "Usage: phenix-p1-live-prompt PROMPT..." >&2
                echo "Set OPENAI_API_KEY or PHENIX_MODEL_HTTP_API_KEY in the environment." >&2
                exit 2
              fi
              export PHENIX_P1_PROMPT="$*"
              exec nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${realPlugin}"} \
                -l ${realPlugin}/share/phenix-ai.nvim/p1_live_prompt.lua
            '';
          };
        in
        {
          default = p1Plugin;
          phenix-ai-nvim = p1Plugin;
          phenix-ai-nvim-basic = p1Plugin;
        }
        // pkgs.lib.optionalAttrs hasManaged {
          phenix-ai-nvim-managed = managedPlugin;
        }
        // pkgs.lib.optionalAttrs hasOpenAiApi {
          phenix-ai-nvim-openai-api = openAiApiPlugin;
        }
        // pkgs.lib.optionalAttrs hasChatGpt {
          phenix-ai-nvim-chatgpt = chatGptPlugin;
        }
        // pkgs.lib.optionalAttrs (builtins.hasAttr "phenix-basic-http-acp" phenix-ai.packages.${system}) {
          phenix-ai-nvim-live = realPlugin;
          phenix-ai-nvim-live-prompt = realPrompt;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          source = pkgs.lib.cleanSource ./.;
          p1Plugin = self.packages.${system}.default;
        in
        {
          # Fast syntax-only gate, independent of Basic runtime/Cargo products.
          # Run first on PRs so malformed Lua tests do not fail only after a
          # costly full Nix integration build.
          lua-syntax = pkgs.runCommand "phenix-ai-nvim-lua-syntax"
            { nativeBuildInputs = [ pkgs.luajit ]; }
            ''
              set -euo pipefail
              while IFS= read -r -d "" file; do
                luajit -b "$file" /dev/null
              done < <(find ${source}/lua ${source}/tests -type f -name '*.lua' -print0)
              touch "$out"
            '';
          # Run UI-only regressions before building the Basic ACP binary.
          ui-fast = pkgs.runCommand "phenix-ai-nvim-ui-fast"
            { nativeBuildInputs = [ pkgs.neovim ]; }
            ''
              set -euo pipefail
              export HOME="$TMPDIR/home"
              export XDG_STATE_HOME="$TMPDIR/state"
              mkdir -p "$HOME" "$XDG_STATE_HOME"
              for test in p1_transcript_tail p1_transcript_updates p1_model_picker provider_auth_model_ux p1_native_auth_ui p1_auth_cancel p1_auth_env_source p1_oauth_ux_journey n5_submission_lifecycle n5_editor_context_isolation n5_client_tool_admission queue_lifecycle p1_runtime_generation p1_provider_catalog p1_provider_read_queries p1_credential_revoke p1_scoped_credential_ui; do
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${source}"} \
                  -l "${source}/tests/$test.lua"
              done
              touch "$out"
            '';
          provider-auth-ui = pkgs.runCommand "phenix-ai-nvim-provider-auth-ui"
            { nativeBuildInputs = [ pkgs.neovim ]; }
            ''
              set -euo pipefail
              export HOME="$TMPDIR/home"
              export XDG_STATE_HOME="$TMPDIR/state"
              mkdir -p "$HOME" "$XDG_STATE_HOME"
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/commands.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/provider_auth_model_ux.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_oauth_ux_journey.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_native_auth_ui.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_auth_cancel.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_auth_env_source.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_credential_revoke.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_scoped_credential_ui.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_model_config.lua
              touch "$out"
            '';
          p1-default-cutover = pkgs.runCommand "phenix-ai-nvim-p1-default-cutover"
            { nativeBuildInputs = [ pkgs.neovim ]; }
            ''
              set -euo pipefail
              defaultPlugin="${self.packages.${system}.default}"
              test ! -e "$defaultPlugin/lua/phenix.so"
              grep -F 'backend = "p1"' "$defaultPlugin/lua/phenix_nvim/config.lua"
              grep -F '/bin/phenix-basic-acp' "$defaultPlugin/lua/phenix_nvim/config.lua"
              export HOME="$TMPDIR/home"
              export XDG_STATE_HOME="$TMPDIR/state"
              mkdir -p "$HOME" "$XDG_STATE_HOME"
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/p1_package_default.lua
              # Local display-only projections; not an ACP extension or
              # an agent-facing A2UI protocol. Verify in the installed plugin.
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/structured_ui.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/p1_transcript_disclosure.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/p1_transcript_tail.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/p1_transcript_updates.lua
              # Presentation-only queue: runtime admission is owned by #891.
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/queue_lifecycle.lua
              # Editor callback lifecycle regressions use a deterministic
              # transport fake against the installed Lua presentation.
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/n5_submission_lifecycle.lua
              # Client-only editor buffers are not model-visible context.
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/n5_editor_context_isolation.lua
              # Missing negotiated client-tool admission must fail explicitly.
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/n5_client_tool_admission.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/p1_provider_catalog.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/p1_provider_read_queries.lua
              # Exercise delayed callbacks after disconnect without launching
              # an ACP process. This must pass for the installed P1 package.
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.default}"} \
                -l ${source}/tests/p1_runtime_generation.lua
              touch "$out"
            '';
          p1-product = pkgs.runCommand "phenix-ai-nvim-p1-product-check"
            {
              nativeBuildInputs = [ pkgs.neovim ];
            }
            ''
              set -euo pipefail
              export HOME="$TMPDIR/home"
              export XDG_STATE_HOME="$TMPDIR/state"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              export XDG_CONFIG_HOME="$TMPDIR/config"
              mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
              export PHENIX_BASIC_SQLITE_PATH="$TMPDIR/basic.sqlite"
              export PHENIX_P1_BIN="${phenix-ai.packages.${system}.phenix-basic-acp}/bin/phenix-basic-acp"
              test -x "$PHENIX_P1_BIN"
              test ! -e "${p1Plugin}/lua/phenix.so"
              grep -F 'backend = "p1"' "${p1Plugin}/lua/phenix_nvim/config.lua"
              test "$(cat ${p1Plugin}/share/phenix-ai.nvim/phenix-ai-revision)" = \
                ${pkgs.lib.escapeShellArg (phenix-ai.rev or "dirty")}
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_package_default.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_client_product.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_ui_product.lua
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${p1Plugin}"} \
                -l ${source}/tests/p1_startup_recovery.lua
              test -s "$PHENIX_BASIC_SQLITE_PATH"
              touch "$out"
            '';
        }
        // pkgs.lib.optionalAttrs (builtins.hasAttr "phenix-basic-openai-api-acp" phenix-ai.packages.${system}) {
          p1-openai-api-client = pkgs.runCommand "phenix-ai-nvim-openai-api-client"
            { nativeBuildInputs = [ pkgs.neovim ]; }
            ''
              set -euo pipefail
              plugin="${self.packages.${system}.phenix-ai-nvim-openai-api}"
              runtime="${phenix-ai.packages.${system}.phenix-basic-openai-api-acp}/bin/phenix-basic-openai-api-acp"
              test -x "$runtime"
              test ! -e "$plugin/lua/phenix.so"
              grep -F "$runtime" "$plugin/lua/phenix_nvim/config.lua"
              test "$(cat "$plugin/share/phenix-ai.nvim/phenix-ai-revision")" = \
                ${pkgs.lib.escapeShellArg (phenix-ai.rev or "dirty")}
              export HOME="$TMPDIR/home"
              export XDG_STATE_HOME="$TMPDIR/state"
              mkdir -p "$HOME" "$XDG_STATE_HOME"
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.phenix-ai-nvim-openai-api}"} \
                -l ${source}/tests/p1_scoped_credential_ui.lua
              touch "$out"
            '';
        }
        // pkgs.lib.optionalAttrs (builtins.hasAttr "phenix-basic-chatgpt-acp" phenix-ai.packages.${system}) {
          p1-chatgpt-auth-client = pkgs.runCommand "phenix-ai-nvim-chatgpt-auth-client"
            { nativeBuildInputs = [ pkgs.neovim ]; }
            ''
              set -euo pipefail
              plugin="${self.packages.${system}.phenix-ai-nvim-chatgpt}"
              runtime="${phenix-ai.packages.${system}.phenix-basic-chatgpt-acp}/bin/phenix-basic-chatgpt-acp"
              test -x "$runtime"
              test ! -e "$plugin/lua/phenix.so"
              grep -F "$runtime" "$plugin/lua/phenix_nvim/config.lua"
              test "$(cat "$plugin/share/phenix-ai.nvim/phenix-ai-revision")" = \
                ${pkgs.lib.escapeShellArg (phenix-ai.rev or "dirty")}
              export HOME="$TMPDIR/home"
              export XDG_STATE_HOME="$TMPDIR/state"
              mkdir -p "$HOME" "$XDG_STATE_HOME"
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.phenix-ai-nvim-chatgpt}"} \
                -l ${source}/tests/p1_oauth_ux_journey.lua
              touch "$out"
            '';
        }
        // pkgs.lib.optionalAttrs (builtins.hasAttr "phenix-basic-managed-acp" phenix-ai.packages.${system}) {
          p1-managed-provider-product = pkgs.runCommand "phenix-ai-nvim-managed-provider-product"
            { nativeBuildInputs = [ pkgs.neovim ]; }
            ''
              set -euo pipefail
              export HOME="$TMPDIR/home"
              export XDG_STATE_HOME="$TMPDIR/state"
              export XDG_CACHE_HOME="$TMPDIR/cache"
              export XDG_CONFIG_HOME="$TMPDIR/config"
              mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
              export PHENIX_BASIC_SQLITE_PATH="$TMPDIR/managed-basic.sqlite"
              export PHENIX_P1_MANAGED_BIN="${phenix-ai.packages.${system}.phenix-basic-managed-acp}/bin/phenix-basic-managed-acp"
              managedPlugin="${self.packages.${system}.phenix-ai-nvim-managed}"
              test -x "$PHENIX_P1_MANAGED_BIN"
              test "$(cat "$managedPlugin/share/phenix-ai.nvim/phenix-ai-revision")" = \
                ${pkgs.lib.escapeShellArg (phenix-ai.rev or "dirty")}
              grep -F '/bin/phenix-basic-managed-acp' "$managedPlugin/lua/phenix_nvim/config.lua"
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${self.packages.${system}.phenix-ai-nvim-managed}"} \
                -l ${source}/tests/p1_managed_provider_product.lua
              test -s "$PHENIX_BASIC_SQLITE_PATH"
              touch "$out"
            '';
        }
      );
    };
}

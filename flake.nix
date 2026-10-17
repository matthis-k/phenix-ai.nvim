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
          realPlugin = mkP1Plugin "phenix-ai.nvim-live" realAcp "phenix-basic-http-acp";
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
      );
    };
}

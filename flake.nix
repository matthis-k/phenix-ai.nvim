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
          luaBinding = phenix-ai.packages.${system}.phenix-binding-lua;
          phenixAcp = phenix-ai.packages.${system}.phenix-acp;
          plugin = pkgs.vimUtils.buildVimPlugin {
            pname = "phenix-ai.nvim";
            version = "0";
            src = source;
            postInstall = ''
              install -Dm755 ${luaBinding}/lib/lua/5.1/phenix.so "$out/lua/phenix.so"
              substituteInPlace "$out/lua/phenix_nvim/config.lua" \
                --replace-fail 'command = "phenix-acp"' \
                'command = "${phenixAcp}/bin/phenix-acp"'
              mkdir -p "$out/share/phenix-ai.nvim"
              printf '%s\n' ${pkgs.lib.escapeShellArg (phenix-ai.rev or "dirty")} \
                > "$out/share/phenix-ai.nvim/phenix-ai-revision"
            '';
          };
          providerAcceptance = pkgs.writeShellApplication {
            name = "phenix-ai-nvim-provider-acceptance";
            runtimeInputs = [ pkgs.neovim ];
            text = ''
              set -euo pipefail
              if test -z "''${OPENAI_API_KEY:-}"; then
                echo "OPENAI_API_KEY is required for real-provider acceptance" >&2
                exit 2
              fi

              state_dir="$(mktemp -d)"
              trap 'rm -rf "$state_dir"' EXIT
              export PHENIX_STATE_DB="$state_dir/provider-acceptance.sqlite"
              export PHENIX_SESSION_ID_FILE="$state_dir/session-id"
              export PHENIX_ACCEPTANCE_ACP="${phenixAcp}/bin/phenix-acp"

              export PHENIX_ACCEPTANCE_PHASE=run
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                -l ${source}/tests/provider_acceptance.lua
              test -s "$PHENIX_STATE_DB"
              test -s "$PHENIX_SESSION_ID_FILE"

              export PHENIX_ACCEPTANCE_PHASE=resume
              nvim --headless -u NONE \
                --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                -l ${source}/tests/provider_acceptance.lua

              echo "phenix-ai.nvim real-provider acceptance passed"
            '';
          };
        in
        {
          default = plugin;
          phenix-ai-nvim = plugin;
          phenix-ai-nvim-provider-acceptance = providerAcceptance;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          source = pkgs.lib.cleanSource ./.;
          phenixAcp = phenix-ai.packages.${system}.phenix-acp;
          phenixAcpFixture = phenix-ai.packages.${system}.phenix-acp-fixture;
          plugin = self.packages.${system}.phenix-ai-nvim;
        in
        {
          client =
            pkgs.runCommand "phenix-ai-nvim-client-check"
              {
                nativeBuildInputs = [
                  pkgs.neovim
                  phenixAcp
                  phenixAcpFixture
                ];
              }
              ''
                export HOME="$TMPDIR/home"
                export XDG_STATE_HOME="$TMPDIR/state"
                export XDG_CACHE_HOME="$TMPDIR/cache"
                export XDG_CONFIG_HOME="$TMPDIR/config"
                mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

                test "$(grep -R -l 'require(\"phenix\")' ${source}/lua | wc -l)" -eq 1
                if grep -R '_phenix/' ${source}/lua; then
                  echo "frontend Lua must not contain raw Phenix wire method ids" >&2
                  exit 1
                fi
                grep -F ${pkgs.lib.escapeShellArg "command = \"${phenixAcp}/bin/phenix-acp\""} \
                  ${plugin}/lua/phenix_nvim/config.lua >/dev/null

                nvim --headless -u NONE \
                  -c ${pkgs.lib.escapeShellArg "lua local f, err = loadfile('${source}/tests/provider_acceptance.lua'); if not f then io.stderr:write(err); vim.cmd('cquit 1') end"} \
                  -c qa

                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/runtime_lifecycle.lua
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/actions_lifecycle.lua
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/headless.lua
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/image.lua
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/interaction.lua

                export PHENIX_STATE_DB="$TMPDIR/phenix-ai-nvim-native-lifecycle.sqlite"
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/native_lifecycle.lua

                export PHENIX_STATE_DB="$TMPDIR/phenix-ai-nvim-acp.sqlite"
                export PHENIX_SESSION_ID_FILE="$TMPDIR/phenix-ai-nvim-session-id"
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -c ${pkgs.lib.escapeShellArg ''lua local ok, err = pcall(function() local frontend = require("phenix_nvim"); local runtime = require("phenix_nvim.runtime"); frontend.setup({ auto_connect = false }); local connected = false; local failure = nil; frontend.connect(function(_, err) failure = err; connected = true end); assert(vim.wait(10000, function() return connected end, 10), "packaged phenix-acp connection timed out"); assert(failure == nil, vim.inspect(failure)); frontend.new_session(); assert(vim.wait(10000, function() return runtime.active_session() ~= nil end, 10), "packaged session creation timed out"); local id = assert(runtime.active_session()); assert(vim.fn.writefile({ id }, vim.env.PHENIX_SESSION_ID_FILE) == 0, "could not persist test session id"); frontend.disconnect() end); if not ok then io.stderr:write(tostring(err)); vim.cmd("cquit 1") end''} \
                  -c qa
                test -s "$PHENIX_STATE_DB"
                test -s "$PHENIX_SESSION_ID_FILE"

                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -c ${pkgs.lib.escapeShellArg ''lua local ok, err = pcall(function() local frontend = require("phenix_nvim"); local runtime = require("phenix_nvim.runtime"); frontend.setup({ auto_connect = false }); local connected = false; local connection_error = nil; frontend.connect(function(_, err) connection_error = err; connected = true end); assert(vim.wait(10000, function() return connected end, 10), "packaged phenix-acp reconnect timed out"); assert(connection_error == nil, vim.inspect(connection_error)); local id = assert(vim.fn.readfile(vim.env.PHENIX_SESSION_ID_FILE)[1]); local resumed = false; local resume_error = nil; runtime.resume_session(id, function(snapshot, err) resume_error = err; resumed = snapshot ~= nil end); assert(vim.wait(10000, function() return resumed or resume_error ~= nil end, 10), "packaged session resume timed out"); assert(resume_error == nil, vim.inspect(resume_error)); assert(runtime.active_session() == id, "restart resumed the wrong session"); local projected = assert(runtime.session_state(), "restart must publish session state"); assert(projected.sessions[id] ~= nil, "resumed session must be reconstructed from durable runtime state"); frontend.disconnect() end); if not ok then io.stderr:write(tostring(err)); vim.cmd("cquit 1") end''} \
                  -c qa

                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/runtime_selection_auth.lua

                export PHENIX_STATE_DB="$TMPDIR/phenix-ai-nvim-fixture.sqlite"
                export PHENIX_FIXTURE_ACP="${phenixAcpFixture}/bin/phenix-acp-fixture"
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/runtime_startup_failure.lua
                export PHENIX_NVIM_LOG_DIRECTORY="$TMPDIR/phenix-ai-nvim-log"
                rm -rf "$PHENIX_NVIM_LOG_DIRECTORY"
                nvim --headless -u NONE \
                  --cmd ${pkgs.lib.escapeShellArg "set rtp^=${plugin}"} \
                  -l ${source}/tests/runtime_model_e2e.lua
                test -s "$PHENIX_NVIM_LOG_DIRECTORY/phenix.log"
                test -d "$PHENIX_NVIM_LOG_DIRECTORY/objects"

                touch "$out"
              '';
        }
      );
    };
}

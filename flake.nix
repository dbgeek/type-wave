{
  description = "Development shell with Zig and the local-backend release-gate runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            zig-overlay.packages.${system}.master
            pkgs.cmake
            pkgs.curl
            pkgs.ninja
            pkgs.python3
            pkgs.mypy
          ];

          # Dev-shell convenience: make sure OPENAI_API_KEY is exported — the dev
          # override for foreground runs (#33; the installed daemon reads the login
          # keychain instead). A legacy ~/.config/type-wave/env file is still sourced
          # if present so old setups keep working — but do not count on it: the
          # installed daemon now *removes* that file once the keychain provably holds
          # the key (#282), so a machine that has run the daemon exports the key some
          # other way.
          shellHook = ''
            if [ -z "''${OPENAI_API_KEY:-}" ] && [ -f "$HOME/.config/type-wave/env" ]; then
              . "$HOME/.config/type-wave/env"
            fi
            if [ -z "''${OPENAI_API_KEY:-}" ]; then
              echo "type-wave: OPENAI_API_KEY not exported - foreground runs need it (the installed daemon uses the keychain, issue #33)" >&2
            fi
          '';
        };
      });
}

{
  description = "Development shell with Zig";

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
          packages = [ zig-overlay.packages.${system}.master ];

          # Dev-shell convenience: make sure OPENAI_API_KEY is exported — the dev
          # override for foreground runs (#33; the installed daemon reads the login
          # keychain instead). A legacy ~/.config/type-wave/env file is still sourced
          # if present so old setups keep working; the daemon itself no longer reads
          # it (beyond a one-time migration into the keychain).
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

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

          # Load the OpenAI API key from an out-of-repo secrets file
          # (~/.config/type-wave/env, chmod 600) so the secret never enters
          # this repo or the home-manager-managed dotfiles. See issue #7.
          shellHook = ''
            if [ -f "$HOME/.config/type-wave/env" ]; then
              . "$HOME/.config/type-wave/env"
            fi
            if [ -z "''${OPENAI_API_KEY:-}" ]; then
              echo "type-wave: OPENAI_API_KEY not set - create ~/.config/type-wave/env (see issue #7)" >&2
            fi
          '';
        };
      });
}

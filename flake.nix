{
  description = "Zwanzig development environment";

  nixConfig = {
    extra-substituters = [ "https://forketyfork.cachix.org" ];
    extra-trusted-public-keys = [
      "forketyfork.cachix.org-1:+0f7K77HIlUgbueZCRgRHr1GM6gMAThMetrwt0DaF3U="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            just
            shellcheck
            zig.packages.${system}."0.15.2"
          ];

          buildInputs = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
            pkgs.gawk
            pkgs.gnused
          ];

          shellHook = ''
            echo "Zwanzig development environment"
            echo "Available commands: just --list"
          ''
          + (pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # On macOS, we unset the macOS SDK env vars that Nix sets up because
            # we rely on a system installation.
            unset SDKROOT
            unset DEVELOPER_DIR

            # We need to remove "xcrun" from the PATH. It is injected by
            # some dependency but we need to rely on system Xcode tools
            export PATH=$(echo "$PATH" | ${pkgs.gawk}/bin/awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | ${pkgs.gnused}/bin/sed 's/:$//')

            # Zig 0.15.2 cannot link correctly against the arm64e-only macOS 26.x SDK stubs.
            # Remove this once we move off Zig 0.15.2 or the upstream fix lands.
            # https://codeberg.org/ziglang/zig/issues/31756
            project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            . "$project_root/scripts/setup-macos-sdk-workaround.sh"
          '');
        };
      }
    );
}

{
  description = "A logic simulator written in Zig and powered by Raylib.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default";

    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      perSystem =
        {
          self',
          pkgs,
          system,
          ...
        }:
        {
          packages = {
            logic-sim = pkgs.callPackage ./. { };
            default = self'.packages.logic-sim;
          };

          devShells.default = pkgs.callPackage ./shell.nix {
            inherit (self'.packages) logic-sim;
          };
        };
    };
}

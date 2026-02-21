{
  description = "A logic simulator written in Zig and powered by Raylib.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=68b5fdce2dfce2dc676a13ed7a0bfb483bfda3ee";
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
            logic-sim = pkgs.callPackage ./default.nix { };
            default = self'.packages.logic-sim;
          };

          devShells.default = pkgs.callPackage ./shell.nix {
            inherit (self'.packages) logic-sim;
          };
        };
    };
}

{
  description = "forest.nix — easy declarative virtual machines";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm, sops-nix }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        inherit system;
        pkgs = import nixpkgs { inherit system; };
      });
    in {

      nixosModules.default = import ./forest {
        microvmSrc = microvm;
        sopsNixSrc = sops-nix;
      };

      checks = forAllSystems ({ pkgs, ... }:
        (import ./tests { inherit pkgs; }).checks);

      devShells = forAllSystems ({ pkgs, system, ... }:
        {
          default = import ./shell.nix { inherit pkgs system; };
        }
      );
    };
}

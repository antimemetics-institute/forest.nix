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

      nixosModules.default = { ... }@args: import ./forest (args // {
        inherit microvm sops-nix;
      });

      checks = forAllSystems ({ pkgs, ... }:
        let results = import ./tests { inherit pkgs; };
        in {
          utils =
            if results.allPassed
            then pkgs.runCommand "forest-utils-tests" {} "echo all tests passed; touch $out"
            else pkgs.runCommand "forest-utils-tests-failed" {
              failure = results.summary;
            } ''
              printf '%s\n' "$failure"
              exit 1
            '';
        });
    };
}

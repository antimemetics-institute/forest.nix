{
  description = "forest.nix — easy declarative virtual machines";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";

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

      # Imperative VMs: `nix run .#agents.claude` boots a sandboxed VM and drops
      # you in over ssh. See forest/imperative.
      apps = forAllSystems ({ pkgs, ... }:
        let
          launcherFor = import ./forest/imperative {
            inherit pkgs;
            forestModule = self.nixosModules.default;
          };
          # Wrap a built launcher in the flake-app schema `nix run` consumes.
          mkApp = spec: { type = "app"; program = pkgs.lib.getExe (launcherFor spec); };
        in {
          agents.claude = mkApp (import ./forest/imperative/agents/claude.nix);
        });

      checks = forAllSystems ({ pkgs, ... }:
        (import ./tests { inherit pkgs; }).checks);

      devShells = forAllSystems ({ pkgs, system, ... }:
        {
          default = import ./shell.nix { inherit pkgs system; };
        }
      );
    };
}

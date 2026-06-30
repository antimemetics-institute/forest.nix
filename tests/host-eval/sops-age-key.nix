{ lib, pkgs, ... }:

# Host-level eval test for the post-quantum sops age-key provisioning
# (forest/secrets/host.nix): the host-side key-generation service must appear
# exactly when at least one VM enables sops, and not otherwise.

let
  stateVersion = "24.11";

  forestModule = import ../../default.nix {};

  baseHost = {
    boot.loader.grub.devices = [ "nodev" ];
    fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
    system.stateVersion = stateVersion;
  };

  evalHost = userConfig: (pkgs.nixos ({ ... }: {
    imports = [ forestModule baseHost userConfig ];
  })).config;

  hasSetupService = cfg: cfg.systemd.services ? forest-sops-age-setup;

  testCases = {
    sopsEnabled = {
      input = {
        forest.enable = true;
        forest.vms.web = {
          sops = { enable = true; defaultSopsFile = ./dummy-secrets.yaml; };
          config = { system.stateVersion = stateVersion; };
        };
      };
      expected = true;
    };
    sopsDisabled = {
      input = {
        forest.enable = true;
        forest.vms.web = {
          config = { system.stateVersion = stateVersion; };
        };
      };
      expected = false;
    };
  };

  runCase = name: case:
    let
      actual = hasSetupService (evalHost case.input);
    in {
      inherit name actual;
      expected = case.expected;
      passed = actual == case.expected;
    };
in {
  tests = lib.mapAttrs runCase testCases;
}

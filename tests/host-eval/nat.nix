{ lib, pkgs, ... }:

# Host-level eval test: forest's host module must coexist with nixpkgs
# modules that touch the same surface. Historical regressions on the
# boot.kernel.sysctl forwarding keys are why this exists — both type-clashes
# (forest set 1, nat set true) and same-priority merge clashes have shipped.

let
  stateVersion = "24.11";

  forestModule = import ../../default.nix {};

  # pkgs.nixos forces the full NixOS module set, which declares assertions
  # like "you must define a root filesystem" and "you must set a bootloader".
  # Stubbing both with no-op values keeps those unrelated assertions from
  # polluting the failure signal we care about (forest's own assertions).
  baseHost = {
    boot.loader.grub.devices = [ "nodev" ];
    fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
    system.stateVersion = stateVersion;
  };

  evalHost = userConfig: (pkgs.nixos ({ ... }: {
    imports = [ forestModule baseHost userConfig ];
  })).config;

  extractSignal = cfg: {
    failingAssertions = lib.filter (a: !a.assertion) cfg.assertions;
  };

  testCases = {
    natEnabled = {
      forest.enable = true;
      forest.vms.web = {
        config = { system.stateVersion = stateVersion; };
      };
      networking.nat.enable = true;
      networking.nat.enableIPv6 = true;
    };
  };

  runCase = name: input:
    let
      signal = extractSignal (evalHost input);
      # deepSeq forces nested values so tryEval catches lazy throws too.
      result = builtins.tryEval (builtins.deepSeq signal signal);
      noFailingAssertions =
        result.success && result.value.failingAssertions == [];
    in {
      inherit name;
      passed = noFailingAssertions;
      expected = "evaluates cleanly with no failing assertions";
      actual =
        if !result.success then "eval threw during host config evaluation"
        else if result.value.failingAssertions != []
        then "assertion failed: ${(builtins.head result.value.failingAssertions).message}"
        else "OK";
    };
in {
  tests = lib.mapAttrs runCase testCases;
}

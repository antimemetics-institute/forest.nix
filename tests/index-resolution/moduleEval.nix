{ lib, utils, runners, ... }:

# Whole-module eval test: instantiates the forest module via `lib.evalModules`
# and confirms that the user-facing API actually wires `resolveIndices` into
# each VM's derived networking. Catches integration regressions (e.g. submodule
# specialArgs going stale, the `config` option name colliding with the module
# shorthand, fixpoint cycles in the resolution pass) that the pure-function
# tests for `resolveIndices` can't see.

let
  sources = import ../../npins;

  evalForest = vms: (lib.evalModules {
    modules = [
      (import ../../forest {
        microvmSrc = sources."microvm.nix";
        sopsNixSrc = sources."sops-nix";
      })
      ({ ... }: {
        _module.check = false;
      })
      ({ ... }: { forest.vms = vms; })
    ];
  }).config.forest.vms;

  # Pull just the resolved-index plus a couple of derived fields so we can
  # assert end-to-end that the resolution flowed through to networking values.
  pluck = vms: lib.mapAttrs (_: vm: {
    inherit (vm) ipv4 vsockCid;
    explicit = vm.index;
    resolved = vm._index;
  }) vms;

  # Each test pre-builds a `vms` attrset using deep paths so the user input
  # syntax exercises `forest.vms.X.config = ...; forest.vms.X.index = ...;`,
  # the same shape real consumers use.
  testCases = {
    autoAssignsAcrossEnabledVms = {
      input = {
        alpha.config = {};
        bravo.config = {};
      };
      expected = {
        alpha = { explicit = null; resolved = 0; ipv4 = "192.168.69.10"; vsockCid = 420; };
        bravo = { explicit = null; resolved = 1; ipv4 = "192.168.69.11"; vsockCid = 421; };
      };
    };

    explicitClampsAndAutoSkips = {
      input = {
        alpha.config = {};
        bravo.config = {};
        bravo.index = 5;
        charlie.config = {};
      };
      expected = {
        alpha = { explicit = null; resolved = 0; ipv4 = "192.168.69.10"; vsockCid = 420; };
        bravo = { explicit = 5;    resolved = 5; ipv4 = "192.168.69.15"; vsockCid = 425; };
        charlie = { explicit = null; resolved = 1; ipv4 = "192.168.69.11"; vsockCid = 421; };
      };
    };

    disabledVmStillReservesItsIndex = {
      input = {
        alpha.config = {};
        alpha.enable = false;
        alpha.index = 0;
        bravo.config = {};
      };
      expected = {
        alpha = { explicit = 0;    resolved = 0; ipv4 = "192.168.69.10"; vsockCid = 420; };
        bravo = { explicit = null; resolved = 1; ipv4 = "192.168.69.11"; vsockCid = 421; };
      };
    };
  };

  runEval = name: test:
    let actual = pluck (evalForest test.input);
    in {
      inherit name actual;
      inherit (test) expected;
      passed = actual == test.expected;
    };
in {
  tests = lib.mapAttrs runEval testCases;
}

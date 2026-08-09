{ lib, pkgs, ... }:

# forest.vmSubnet / vmSubnet6 / vmGateway / vmGateway6 are readOnly: their
# values are baked into per-VM address derivation, so a user override would
# silently break networking. This test pins both directions:
#   - reading each option yields the fixed value
#   - defining each option is an eval error
#
# Uses the lightweight evalModules harness — see allowEgressAssertions.nix.

let
  inputs = import ../../.tack;
  forestModule = import ../../forest {
    microvmSrc = inputs."microvm.nix";
    sopsNixSrc = inputs."sops-nix";
  };

  evalForest = extraConfig: (lib.evalModules {
    modules = [
      forestModule
      ({ ... }: {
        _module.check = false;
        _module.args.pkgs = pkgs;
      })
      extraConfig
    ];
  }).config.forest;

  fixedValues = {
    vmSubnet = "192.168.69.0/24";
    vmSubnet6 = "fd69::/64";
    vmGateway = "192.168.69.1";
    vmGateway6 = "fd69::1";
  };

  readCases = lib.mapAttrs' (opt: expected: {
    name = "${opt}Reads";
    value =
      let actual = (evalForest {}).${opt};
      in {
        name = "${opt}Reads";
        inherit actual expected;
        passed = actual == expected;
      };
  }) fixedValues;

  # Setting a readOnly option must throw; tryEval turns that into failure.
  setCases = lib.mapAttrs' (opt: value: {
    name = "${opt}RejectsOverride";
    value =
      let attempt = builtins.tryEval (evalForest { forest.${opt} = value; }).${opt};
      in {
        name = "${opt}RejectsOverride";
        actual = attempt.success;
        expected = false;
        passed = !attempt.success;
      };
  }) {
    vmSubnet = "10.0.0.0/24";
    vmSubnet6 = "fd42::/64";
    vmGateway = "10.0.0.1";
    vmGateway6 = "fd42::1";
  };
in {
  tests = readCases // setCases;
}

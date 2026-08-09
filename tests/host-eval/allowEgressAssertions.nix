{ lib, pkgs, ... }:

# Assertion test for forest.vms.<name>.allowEgress: destinations inside the
# forest subnets must be rejected, since VM-to-VM traffic never leaves the
# bridge and is governed by `dependsOn` alone.
#
# Uses the lightweight evalModules harness rather than `pkgs.nixos` — see
# tests/index-resolution/forwardPortsAssertions.nix for why. forest's other
# assertions may fail in this stub environment; we only inspect the ones whose
# message mentions `allowEgress`.

let
  inputs = import ../../.tack;
  forestModule = import ../../forest {
    microvmSrc = inputs."microvm.nix";
    sopsNixSrc = inputs."sops-nix";
  };

  evalAssertions = vms: (lib.evalModules {
    modules = [
      ({ ... }: {
        options.assertions = lib.mkOption {
          type = lib.types.listOf lib.types.unspecified;
          default = [];
        };
      })
      forestModule
      ({ ... }: {
        _module.check = false;
        _module.args.pkgs = pkgs;
        forest.vms = vms;
      })
    ];
  }).config.assertions;

  # Message check first — `&&` is left-to-right, so we never force `.assertion`
  # on unrelated entries (forest has another assertion that reads
  # boot.kernel.sysctl, undeclared in this minimal eval).
  hasAllowEgressFailure = vms:
    lib.any
      (a: lib.strings.hasInfix "allowEgress" a.message && !a.assertion)
      (evalAssertions vms);

  vm = allowEgress: { dev = { config = {}; inherit allowEgress; }; };

  testCases = {
    routedV4Passes = {
      input = vm [ { daddr = "10.10.0.3"; port = 22; } ];
      expected = false;
    };
    routedV6Passes = {
      input = vm [ { daddr = "fd00::3"; port = 22; } ];
      expected = false;
    };
    routedCidrPasses = {
      input = vm [ { daddr = "192.168.1.0/24"; port = 631; } ];
      expected = false;
    };
    noEntriesPasses = {
      input = vm [];
      expected = false;
    };
    # A public destination is allowed on purpose — that is how you build
    # "internetAccess = false, except this one API". Only forest-subnet
    # addresses are rejected.
    publicV4Passes = {
      input = vm [ { daddr = "160.79.104.10"; port = 443; } ];
      expected = false;
    };
    # Another forest VM's address — belongs in dependsOn.
    vmSubnetV4Fails = {
      input = vm [ { daddr = "192.168.69.10"; port = 22; } ];
      expected = true;
    };
    vmSubnetV6Fails = {
      input = vm [ { daddr = "fd69::10"; port = 22; } ];
      expected = true;
    };
    # A CIDR that *contains* the forest is just as bad as one inside it: the
    # accept precedes the inter-VM drop, so it would reach every VM on that
    # port regardless of dependsOn.
    supernetFails = {
      input = vm [ { daddr = "192.168.0.0/16"; port = 22; } ];
      expected = true;
    };
    defaultRouteFails = {
      input = vm [ { daddr = "0.0.0.0/0"; port = 22; } ];
      expected = true;
    };
    v6SupernetFails = {
      input = vm [ { daddr = "fd00::/8"; port = 22; } ];
      expected = true;
    };
    # ...but a v4 supernet must not trip on the v6 forest subnet, and a LAN
    # CIDR next door to the forest stays usable.
    adjacentLanCidrPasses = {
      input = vm [ { daddr = "192.168.1.0/24"; port = 631; } ];
      expected = false;
    };
    # A good entry alongside a bad one still fails.
    mixedFails = {
      input = vm [
        { daddr = "10.10.0.3"; port = 22; }
        { daddr = "192.168.69.11"; port = 5432; }
      ];
      expected = true;
    };
  };

  runCase = name: test:
    let actual = hasAllowEgressFailure test.input;
    in {
      inherit name actual;
      inherit (test) expected;
      passed = actual == test.expected;
    };
in {
  tests = lib.mapAttrs runCase testCases;
}

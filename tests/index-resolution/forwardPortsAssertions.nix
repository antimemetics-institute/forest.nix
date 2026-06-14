{ lib, pkgs, ... }:

# Assertion test for forest.vms.<name>.forwardPorts.
#
# We can't use `pkgs.nixos` here: forcing `config.assertions` through the full
# NixOS module set drags in microvm.nix's host module, which (against current
# nixpkgs) defines options the inner VM evaluator doesn't know about. That's
# unrelated to forest and out of scope.
#
# So we stay light: declare just the `assertions` option ourselves, evaluate
# forest, and filter the result by message text. forest's other assertions
# (e.g. the IP-forwarding sysctl one) may fail in this stub environment —
# we ignore those and only inspect ones that mention `forwardPorts`.

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
  # on non-forwardPort entries (forest has another assertion that reads
  # boot.kernel.sysctl, undeclared in this minimal eval).
  hasForwardPortFailure = vms:
    lib.any
      (a: lib.strings.hasInfix "forwardPorts" a.message && !a.assertion)
      (evalAssertions vms);

  testCases = {
    interfaceOnlyPasses = {
      input = {
        dev.config = {};
        dev.forwardPorts = [{ port = 22; protocol = "tcp"; interface = "tailscale0"; }];
      };
      expected = false;
    };

    bindAddressOnlyPasses = {
      input = {
        dev.config = {};
        dev.forwardPorts = [{ port = 80; protocol = "tcp"; bindAddress = "203.0.113.5"; }];
      };
      expected = false;
    };

    explicitAnyTokensPass = {
      input = {
        dev.config = {};
        dev.forwardPorts = [{ port = 80; protocol = "tcp"; bindAddress = [ "0.0.0.0" "::" ]; }];
      };
      expected = false;
    };

    unscopedFails = {
      input = {
        dev.config = {};
        dev.forwardPorts = [{ port = 22; protocol = "tcp"; }];
      };
      expected = true;
    };
  };

  runCase = name: test: {
    inherit name;
    actual = hasForwardPortFailure test.input;
    inherit (test) expected;
    passed = hasForwardPortFailure test.input == test.expected;
  };
in {
  tests = lib.mapAttrs runCase testCases;
}

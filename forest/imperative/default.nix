# Imperative runner entry point: a forest VM definition → a runnable launcher
# derivation. This module *is* that builder function; flake.nix wraps its output
# as a nix-run app.
#
# Composes the three pieces — evaluate the VM as a normal forest guest, build its
# imperative runner (forest/imperative/runner.nix), wrap it in the launcher
# (forest/imperative/launcher.nix).
#
# `forestModule` is the forest NixOS module — evaluating a minimal host with the VM
# defined is just the vehicle to get the guest config the runner extends (nothing is
# built beyond the runner). It defaults to the repo's own (tack-pinned) module, so
# non-flake callers pass nothing; the flake overrides it with
# `self.nixosModules.default` to pin microvm/sops via its own inputs instead. `pkgs`
# likewise defaults to <nixpkgs>.
{ pkgs ? import <nixpkgs> { }
, forestModule ? import ../../default.nix { }
}:

let
  lib = pkgs.lib;
  mkImperativeRunner = import ./runner.nix { inherit lib; };
  mkLauncher = import ./launcher.nix { inherit pkgs lib; };
in

# name    : VM name (state dir + hostname)
# vm      : forest VM definition (the forest.vms.<name> attrs)
# user    : ssh user the launcher logs in as (default root — uid 0 maps to your
#           host uid, so edits stay yours; override for a named user)
# command : entrypoint over ssh ("" = interactive login shell)
# shares  : high-level cwd/home/path shares (forest/imperative/shares.nix)
# seed    : $HOME-relative paths copied into the agent's home at launch (private
#           writable snapshot, not a mount)
{ name, vm, user ? "root", command ? "", shares ? [], seed ? [] }:

let
  # Lower `shares` to guest microvm.shares (baked via the VM's extraModules) +
  # a plant list the launcher resolves at run time.
  lowered = import ./shares.nix { inherit lib; } { inherit name shares; };
  vmWithShares = vm // {
    # The runner injects its own vsock auth (vm.nix for `user`), so the fleet's
    # root vsock-ssh path must be off — importing vm.nix twice would conflict.
    # Forced here so agent specs never deal with this fleet-only knob.
    vsockSsh = false;
    extraModules = (vm.extraModules or [ ]) ++ lib.optional (lowered.shares != [ ]) {
      microvm.shares = lowered.shares;
    };
  };

  # This bit is kind of ugly and magical (derogatory).
  # It evals a dummy host config and pulls out the vm definition for imperative usage.
  host = (pkgs.nixos ({ ... }: {
    imports = [
      forestModule
      {
        system.stateVersion = lib.mkDefault "26.05";
        forest.enable = true;
        forest.vms.${name} = vmWithShares;
      }
    ];
  })).config;
  guest = host.microvm.vms.${name}.config;

  runner = mkImperativeRunner { inherit guest user; };
in
# The launcher allocates a fresh vsock CID per launch (run-vm substitutes it into
# the runner's baked qemu command), so the guest's declared CID is unused.
mkLauncher { inherit name runner user command seed; plants = lowered.plants; }

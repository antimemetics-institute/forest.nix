# Host-side hot-switch wiring. Imported once by forest/default.nix.
#
# A *consumer* of forest/vsock-ssh (the shared host→VM management SSH channel):
# it reuses the management key and the vsock sshd set up there, and drives the
# switch through `microvm -s` — so forest owns no vsock-dialing code (the
# hypervisor branch, the mux handshake, host keys are all microvm/systemd's).
#
# Restart behaviour by updatePolicy:
#   - "switch":  microvm@ restartIfChanged = false (forest drives it). The
#                forest-update-<name> unit, on any change, diffs the booted vs
#                installed runner and either applies userspace in place over the
#                VM's vsock ssh (switch-to-configuration) or restarts the VM.
#   - "restart": microvm@ restartIfChanged = true, restartTriggers =
#                [ declaredRunner ] so any change — including a hardware-only one
#                that doesn't touch toplevel (e.g. memorySize) — restarts.
#   - "manual":  microvm@ restartIfChanged = false, nothing drives it; the new
#                runner is installed but the VM is left alone.
#
# The restart-vs-switch decision is made at runtime by comparing the two runners'
# actual launch scripts (bin/*), not an eval-time fingerprint: that surface is
# complete by construction (kernel, initrd, cmdline, mem, vcpu, shares, devices,
# hypervisor binary — everything) with nothing to enumerate or keep in sync. The
# runners reference the userspace toplevel in exactly one place
# (init=${toplevel}/init), which we normalize out so a userspace-only change
# compares equal and is hot-switched instead of restarted.
{ microvmSrc }:
{ config, lib, pkgs, ... }:

let
  cfg = config.forest;

  enabledVms = lib.filterAttrs (_: vm: vm.enable) cfg.vms;
  switchVms  = lib.filterAttrs (_: vm: vm.updatePolicy == "switch")  enabledVms;
  restartVms = lib.filterAttrs (_: vm: vm.updatePolicy == "restart") enabledVms;

  # Evaluated guest NixOS config for a VM (same access the microvm host module
  # uses for fully-declarative VMs).
  guestOf = name: config.microvm.vms.${name}.config.config;

  launchFingerprint = import ./launch-fingerprint.nix { inherit pkgs lib; };

  # microvm.nix's own management CLI; `microvm -s <vm>` picks the right vsock
  # target per hypervisor and connects over systemd-ssh-proxy. callPackage with
  # defaults matches forest's stateDir (/var/lib/microvms).
  microvmCommand = pkgs.callPackage "${microvmSrc}/pkgs/microvm-command.nix" { };

  # Drive the switch through `microvm -s`: it selects the vsock target, ssh logs
  # in as root (authenticating with the management key via the ssh client config
  # from forest/vsock-ssh/host.nix), and runs switch-to-configuration detached.
  #
  # The switch runs under `systemd-run --pipe --wait` so that even if it restarts
  # something fatal to the session, the activation completes under the guest's
  # PID 1; the severed ssh just exits non-zero and the retry re-runs the
  # idempotent switch. We use `test` (not `switch`): microvm guests have no in-VM
  # bootloader — the persistent config is whatever the host runner points init=
  # at on next cold boot — so `test` applies the new userspace now.
  vsockSwitcher = name: guest:
    let
      toplevel = guest.system.build.toplevel;
      systemdRun = "${guest.systemd.package}/bin/systemd-run";
    in
    pkgs.writeShellApplication {
      name = "forest-vsock-switch-${name}";
      runtimeInputs = [ microvmCommand ];
      text = ''
        microvm -s '${name}' \
          ${systemdRun} --pipe --wait --collect \
            '${toplevel}/bin/switch-to-configuration' test
      '';
    };

  hotswitchUnit = name: vm:
    let
      guest = guestOf name;
    in {
      description = "Hot-switch or restart MicroVM '${name}'";
      # Order after:
      #   - install-microvm-<name>: sets the `current` symlink to the new runner.
      #   - microvm@<name>: the guest is up (notify) — so its vsock sshd is
      #     reachable — and `booted` is settled (microvm-set-booted runs Before
      #     microvm@, so being after microvm@ is transitively after it).
      #   - forest-ssh-setup: the management key exists and is planted, so the
      #     ssh login can authenticate.
      after = [
        "install-microvm-${name}.service"
        "microvm@${name}.service"
        "forest-ssh-setup.service"
      ];
      wantedBy = [ "multi-user.target" ];
      # declaredRunner changes on *any* config change (hardware or userspace), so
      # this re-runs whenever something changed; the diff decides what to do.
      restartTriggers = [ guest.microvm.declaredRunner ];
      path = [ pkgs.coreutils config.systemd.package ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 300;
        SyslogIdentifier = "forest-update-${name}";
      };
      script = ''
        set -uo pipefail
        dir=/var/lib/microvms/${name}

        # If microvm is not running, switched config will come up next time it starts anyway.
        if ! systemctl is-active --quiet 'microvm@${name}.service'; then
          echo 'microvm@${name} is not running; nothing to do'
          exit 0
        fi

        booted=$(readlink "$dir/booted")
        current=$(readlink "$dir/current")

        # Should we restart the VM, or can we just switch? Great question.
        # We could enumerate each hardware option (microvm.*, hypervisor package version),
        # or we could try to do something smarter.
        # This function hashes the "runner's launch surface" (all bin/* scripts),
        # except the one userspace-varying thing: the toplevel path in init=.
        # Equal => only userspace changed (hot-switch);
        # Different => launch/hardware change (restart).
        # $booted reflects the actually-running kernel/hardware, which
        # switch-to-configuration never changes, so it stays the right baseline.
        if [ "$(${launchFingerprint} "$booted")" = "$(${launchFingerprint} "$current")" ]; then
          echo 'launch surface unchanged; switching ${name} userspace via vsock ssh'
          exec ${lib.getExe (vsockSwitcher name guest)}
        else
          echo 'launch surface changed; restarting ${name}'
          # Detach the restart into a transient unit. This unit is ordered After
          # microvm@<name>, so restarting it inline entangles with our own
          # activation transaction — systemd re-queues us after the VM cold-boots,
          # hanging `nixos-rebuild switch` for minutes. systemd-run runs it in its
          # own context, fully decoupled.
          exec systemd-run --collect --no-block \
            systemctl restart 'microvm@${name}.service'
        fi
      '';
    };
in
{
  config = lib.mkIf cfg.enable {
    # Only "restart" uses microvm's native restart-on-change. "switch" and
    # "manual" opt out; forest-update (switch) or nothing (manual) drives it.
    microvm.vms = lib.mapAttrs (_: vm: {
      restartIfChanged = vm.updatePolicy == "restart";
    }) enabledVms;

    systemd.services = lib.mkMerge (
      # switch VMs: imperatively decide whether the system should switch or restart
      # (restartIfChanged is set to false, so restartTriggers needs not be override).
      (lib.mapAttrsToList (name: vm: {
        "forest-update-${name}" = hotswitchUnit name vm;
      }) switchVms)
      # restart VMs: restart on any change.
      # microvm.nix only applies hardware changes upon imperative restarts
      # (its restartTriggers defaults to `system.build.toplevel`)
      # instead, we set it to `declaredRunner` which triggers on ANY guest config change.
      ++ (lib.mapAttrsToList (name: _: {
        "microvm@${name}".restartTriggers = lib.mkForce [ (guestOf name).microvm.declaredRunner ];
      }) restartVms)
    );

    # The switch rides the vsock ssh channel, so a "switch" VM must have it on.
    assertions = lib.mapAttrsToList (name: vm: {
      assertion = vm.vsockSsh;
      message = ''
        VM '${name}' has updatePolicy = "switch", which applies userspace in
        place over the vsock ssh channel, but vsockSsh = false. Set vsockSsh =
        true (the default), or use updatePolicy = "restart" / "manual".
      '';
    }) switchVms;
  };
}

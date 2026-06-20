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
  #
  # The exit code flows straight through to the unit (writeShellApplication's
  # `set -e` exits with the failed command's status), which is what decides
  # whether to retry. ssh (via systemd-ssh-proxy) returns 255 for connection-level
  # failures — right after a cold boot the guest's vsock device isn't created yet
  # ("No such device" / "Connection reset by peer" / no banner), so the dial fails
  # — and otherwise propagates the *remote* command's exit code. The
  # unit's `RestartForceExitStatus = 255` retries only on that; any other non-zero
  # is a real switch-to-configuration failure (config error, OOM, ...) and is left
  # to fail.
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
      #   - microvm@<name>: the VM is started and `booted` is settled
      #     (microvm-set-booted runs Before microvm@, so being after microvm@ is
      #     transitively after it). Note this does NOT guarantee the guest is
      #     reachable over vsock yet — the vsock device isn't created until the
      #     guest boots far enough, so the first connection can race it — so the
      #     unit retries on exit 255 (RestartForceExitStatus, below).
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
      # Retry only on a transient vsock connection failure (ssh exit 255), and
      # only that — any other non-zero is the switch's own failure (config error,
      # OOM, ...) which must not thrash. RestartForceExitStatus restarts on
      # exactly 255 regardless of Restart= (left at its default `no`); the start
      # limit bounds the retries before giving up, after which the next rebuild
      # tries again. switch-to-configuration waits for systemd events to settle
      # before its failure scan, and the retry traffic keeps that window open, so
      # a retry that heals within it (the normal first-boot case) is reported as a
      # started unit, not a failure — it only shows up failed if it never heals.
      startLimitIntervalSec = 300;
      startLimitBurst = 10;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 300;
        RestartForceExitStatus = 255;
        RestartSec = "5s";
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
          # Restart in a transient unit, and wait for it. Running `systemctl
          # restart` inline entangles with our own activation transaction:
          # because this unit is ordered After microvm@<name>, systemd folds the
          # restart into the in-flight transaction and re-queues us after the VM
          # cold-boots — hanging `nixos-rebuild switch` for minutes. systemd-run
          # submits the restart as its own job, decoupled from the transaction,
          # so that entanglement is gone. We still want to block until the VM is
          # actually back, though — otherwise rebuild returns while the restart
          # is mid-flight — so use --wait (not --no-block): it blocks here until
          # microvm@ is active again (Type=notify => VM up), bounded by
          # TimeoutStartSec. The transient unit has no ordering on us, so waiting
          # on it can't re-queue us the way inline restart did.
          exec systemd-run --collect --wait \
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

# The imperative runner keystone: boot a microvm runner in the foreground,
# unprivileged, and tear it down when the guest powers itself off.
#
# Orchestrator- and OS-agnostic by construction — every non-systemd driver (the
# bare `nix run`, launchd, devenv) calls this with a built runner and a state
# directory, and it does only the generic spine:
#
#   [enter userns] → cd state-dir → start virtiofsd → wait sockets → run VM → reap
#
# It does NOT build the runner, decide the net/store axis, populate the state
# dir, or pick a teardown policy — those belong to mkImperativeRunner and the
# guest. This stays the thin, shared launcher.
#
# Why the user namespace (Linux): microvm needs an external virtiofsd, and its
# `bin/virtiofsd-run` is a supervisord with `user = root` baked in — unusable as
# an unprivileged uid. Re-execing inside `unshare --map-root-user` makes us uid 0
# *in the namespace*, so supervisord (and microvm's whole virtiofs orchestration)
# runs UNMODIFIED — we lean on microvm instead of reimplementing it. The mapped
# uid also contains a hypervisor escape to a throwaway id, not your account. The
# remaining root-*capability* assumptions are defused by clean options the runner
# bakes (mkImperativeRunner: --sandbox=none, --rlimit-nofile=0, group=null).
#
# macOS/vfkit serves the FS in-process and ships no `virtiofsd-run`, so the whole
# block — userns included — is skipped, and only the final VM launch runs.
{ pkgs, lib }:

pkgs.writeShellApplication {
  name = "forest-run-vm";
  runtimeInputs = [ pkgs.coreutils pkgs.util-linux ];
  text = ''
    runner=''${1:?usage: forest-run-vm <runner> <state-dir> [vsock-cid]}
    stateDir=''${2:?usage: forest-run-vm <runner> <state-dir> [vsock-cid]}
    # Optional per-launch vsock CID. microvm bakes one literal guest-cid into the
    # qemu command; when the caller allocates a fresh CID per instance (so
    # concurrent VMs don't collide on the host-global CID) we substitute it below.
    cid=''${3:-}
    mkdir -p "$stateDir"

    # Linux only (gated on virtiofsd-run existing): enter a uid-0 user namespace
    # and re-exec, so microvm's root-assuming virtiofsd-run runs unmodified.
    if [ -e "$runner/bin/virtiofsd-run" ] && [ "''${FOREST_IN_USERNS:-}" != 1 ]; then
      # --map-root-user makes us uid 0 in the ns (so microvm's virtiofsd-run /
      # supervisord run unmodified); --map-auto additionally maps our subuid range
      # (/etc/subuid) to ns uids 1.., so the guest's own users (e.g. a uid-1000
      # account) have real backing uids and virtiofs file ownership/chown works —
      # otherwise an unmapped guest uid can't own files on the share. Needs setuid
      # newuidmap/newgidmap on PATH (shadow); standard wherever rootless containers
      # run, which is the same precondition as unprivileged userns itself.
      exec unshare --user --map-root-user --map-auto -- \
        env FOREST_IN_USERNS=1 "$0" "$runner" "$stateDir" "$cid"
    fi

    cd "$stateDir"

    pids=()
    cleanup() {
      [ ''${#pids[@]} -gt 0 ] && kill "''${pids[@]}" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    if [ -e "$runner/bin/virtiofsd-run" ]; then
      # Ensure each managed share's relative source dir exists. Absolute sources
      # (/nix/store) are host-provided; dynamic ones are caller-planted symlinks
      # (mkdir -p is a no-op on those).
      for d in "$runner"/share/microvm/virtiofs/*/; do
        src=$(cat "$d/source")
        case "$src" in /*) : ;; *) mkdir -p "$src" ;; esac
      done

      # microvm's supervisord-managed virtiofsd, unmodified. One PID owns every
      # virtiofsd child, so killing it in cleanup tears them all down.
      "$runner/bin/virtiofsd-run" &
      pids+=("$!")

      for s in "$runner"/share/microvm/virtiofs/*/socket; do
        sock=$(cat "$s")
        for _ in $(seq 1 200); do [ -S "$sock" ] && break; sleep 0.05; done
      done
    fi

    # Run the VM as a child (not exec) so a signal to us reaps both it and
    # virtiofsd instead of leaking qemu. Returns when the guest powers itself off,
    # or when we're signalled.
    #
    # With a per-launch CID, rewrite microvm's single baked `guest-cid=` (the one
    # host-global value; qmp/virtiofs sockets are relative and already isolated by
    # $stateDir) into a local copy and run that. Without one, run microvm's script
    # as-is. There is exactly one vhost-vsock device, so the swap is unambiguous.
    if [ -n "$cid" ]; then
      sed "s/guest-cid=[0-9]\+/guest-cid=$cid/" "$runner/bin/microvm-run" > microvm-run
      bash microvm-run &
    else
      "$runner/bin/microvm-run" &
    fi
    vm=$!
    pids+=("$vm")
    wait "$vm"
  '';
}

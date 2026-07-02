# mkLauncher: the `nix run` entrypoint for an imperative forest VM.
#
# Each launch is a fresh, independent instance: a per-launch state dir (mktemp)
# and a per-launch vsock CID, so N VMs of the same agent can run at once — even in
# the same directory — without colliding. The whole instance is ephemeral; its
# state dir is torn down with the VM on exit. (A future dev-style flow that wants
# to *reuse* a VM across invocations would keep a named instance dir + CID here
# instead of allocating fresh — deliberately the only spot that would branch.)
#
# ssh is over vsock (the same transport as the fleet's `forest ssh`), so there's
# no TCP port on the host — systemd-ssh-proxy dials the guest's CID directly.
{ pkgs, lib }:

# name    : agent name — prefix of the instance dir + display
# runner  : the mkImperativeRunner output (a built runner)
# user    : the ssh user the launcher logs in as (also the planted-key user)
# command : entrypoint run over ssh; "" = an interactive login shell
# plants  : share plant-list from shares.nix — launch-resolved sources + the cwd
#           workspace bind
{
  name,
  runner,
  user,
  command ? "",
  plants ? [ ],
  seed ? [ ]
}:

let
  runVm = import ./run-vm.nix { inherit pkgs lib; };
  sourceKind = import ./source.nix;   # the cwd/home/path matcher (shared with shares.nix)
  # AF_VSOCK dialer for `ssh <user>@vsock/<cid>` — the same primitive the fleet
  # reaches: `forest ssh` wraps `microvm -s`, which bottoms out in systemd-ssh-proxy
  # via the host ssh_config. We can't reuse `microvm -s` here — it needs root, a
  # name-registered VM under /var/lib/microvms, and a forest-host ssh_config, none
  # of which an unprivileged, ephemeral `nix run` has — so we point ssh at that same
  # dialer directly.
  sshProxy = "${pkgs.systemd}/lib/systemd/systemd-ssh-proxy";

  # Resolve each launch-time share source to a symlink under the instance dir. The
  # runner rebased these tags to relative sources; run-vm resolves them against the
  # instance dir, where these symlinks point them at the real host paths. Dispatched
  # by `kind` (validated in shares.nix): `path` sources are absolute and served by
  # microvm directly, so they plant nothing.
  plantScript = lib.concatMapStrings
    (p: {
      cwd = ''
        ln -sfn "$PWD" "$instanceDir/${p.tag}"
      '';
      home = ''
        mkdir -p "$HOME/${p.arg}"
        ln -sfn "$HOME/${p.arg}" "$instanceDir/${p.tag}"
      '';
      path = "";
    }.${p.kind})
    plants;

  # The cwd share (if any) is where the entrypoint runs. When its mountpoint leaf
  # is a runtime basename it was staged at a fixed path and we bind it to the nice
  # per-project path here; otherwise it's a literal path we just cd into. `wd` and
  # the project basename are computed host-side and passed literally to the guest.
  cwdPlant = lib.findFirst (p: p.kind == "cwd") null plants;
  workspaceScript =
    if cwdPlant == null then ''remotePrep=""''
    else if cwdPlant.bindUnder != null then ''
      wd="${cwdPlant.bindUnder}/$(basename "$PWD")"
      remotePrep="mkdir -p '$wd' && mount --bind ${cwdPlant.mountPoint} '$wd' && cd '$wd' && "
    ''
    else ''
      remotePrep="cd '${cwdPlant.mountPoint}' && "
    '';

  entrypoint = if command == "" then "bash -l" else command;

  # sshd is socket-activated and can answer before microvm's virtiofs mounts
  # settle, so "ssh works" doesn't imply "shares are mounted" — wait for both.
  # Every share's mountpoint is static (cwd's is its staging path), so we can check
  # them all before running the entrypoint (and before the cwd bind).
  readyCheck =
    if plants == [ ] then "true"
    else lib.concatMapStringsSep " && " (p: "mountpoint -q ${p.mountPoint}") plants;

  # Resolve a seed's typed source (the same cwd/home/path vocabulary as a share's
  # `from`) to a host-path expression — dispatched by `kind`, exactly like plantScript.
  seedSource = s: {
    cwd = ''"$PWD"'';
    home = ''"$HOME/${s.home}"'';
    path = lib.escapeShellArg s.path;
  }.${sourceKind s};

  # Copy each seed into the agent's home by basename, as a private, writable
  # snapshot — tar the source straight into the guest $HOME over the ssh we already
  # have. NOT a mount: the agent's changes stay in the VM, and concurrent agents
  # never share one live config. Best-effort — a missing source is skipped.
  seedScript = lib.concatMapStrings
    (s: ''
      src=${seedSource s}
      # --no-same-owner on extract: take the guest's uid (0 → your host uid via
      # --map-auto), not the archived host uid, which would land as an unremovable
      # subuid. Keeps the copy owned by you (and writable by the agent).
      tar --ignore-failed-read -C "$(dirname "$src")" -cf - "$(basename "$src")" 2>/dev/null \
        | ssh "''${sshOpts[@]}" "$target" 'mkdir -p "$HOME" && tar -C "$HOME" --no-same-owner -xf -' 2>/dev/null || true
    '')
    seed;
in
pkgs.writeShellApplication {
  name = "forest-launch-${name}";
  runtimeInputs = [ pkgs.coreutils pkgs.util-linux pkgs.openssh runVm ];
  text = ''
    stateRoot="''${XDG_STATE_HOME:-$HOME/.local/state}/forest/vms"
    keyDir="''${XDG_CONFIG_HOME:-$HOME/.config}/forest"
    mkdir -p "$stateRoot" "$keyDir"

    # Fresh, ephemeral per-launch instance dir. Holds this VM's virtiofs sources,
    # sockets, planted keys and console — all microvm-relative paths, so isolating
    # the dir isolates the whole instance. Torn down with the VM on exit.
    instanceDir=$(mktemp -d "$stateRoot/${name}.XXXXXXXX")
    mkdir -p "$instanceDir/host-keys"

    # Per-launch vsock CID (host-global; run-vm substitutes it into the baked qemu
    # command). Allocated as a monotonic counter behind a flock, not from a random
    # source: a CID is only 32 bits, so randomness can't be collision-free, whereas
    # a locked counter *guarantees* every launch — concurrent or not — a distinct
    # CID. The space is effectively inexhaustible (one launch/sec wraps in ~a
    # century) so we never reclaim; the counter just climbs. Base is above the
    # fleet's low, index-based CIDs.
    exec 9>"$stateRoot/.cid.lock"
    flock 9
    cid=$(cat "$stateRoot/.cid.next" 2>/dev/null || echo 10000)
    echo $(( cid + 1 )) > "$stateRoot/.cid.next"
    exec 9>&-  # close fd → release the lock

    # Per-user management key, generated once and kept; its public half is planted
    # into the host-keys share so the guest authorizes it (forest/vsock-ssh/vm.nix).
    # Double-checked lock: concurrent first-run launchers must not race to write the
    # same keypair (a half-written or mismatched key fails auth). The common path
    # (key already exists) skips the lock entirely.
    key="$keyDir/id_ed25519"
    if [ ! -f "$key" ]; then
      exec 8>"$keyDir/.key.lock"
      flock 8
      [ -f "$key" ] || ssh-keygen -t ed25519 -N "" -C forest-imperative -f "$key" >/dev/null
      exec 8>&-
    fi
    install -m 0644 "$key.pub" "$instanceDir/host-keys/forest-mgmt.pub"

    # Point launch-resolved share sources (cwd / ~-relative) at their real paths.
    ${plantScript}

    # Boot in the background; on exit reap the VM (and its virtiofsd/qemu) and drop
    # the ephemeral instance dir. The VM console goes to a log so the launcher's
    # stdout is just the user's session.
    console="$instanceDir/console.log"
    forest-run-vm ${runner} "$instanceDir" "$cid" >"$console" 2>&1 &
    vm=$!
    trap 'kill "$vm" 2>/dev/null || true; wait "$vm" 2>/dev/null || true; rm -rf "$instanceDir"' EXIT INT TERM

    # ssh over vsock — no TCP port. systemd-ssh-proxy dials this launch's CID.
    sshOpts=(
      -o "ProxyCommand=${sshProxy} %h %p"
      -o ProxyUseFdpass=yes
      -i "$key"
      -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null
      -o ConnectTimeout=5
    )
    target=${user}@vsock/$cid

    # Wait for the vsock sshd to answer AND the shares to finish mounting.
    until ssh "''${sshOpts[@]}" "$target" "${readyCheck}" 2>/dev/null; do
      kill -0 "$vm" 2>/dev/null || { echo "forest: VM exited before ssh was ready:" >&2; cat "$console" >&2; exit 1; }
      sleep 0.25
    done

    # Seed the agent's home (config snapshot) before handing over.
    ${seedScript}

    # Bind/cd into the workspace (if any), then run the entrypoint with a tty. The
    # entrypoint is single-quoted (escapeShellArg) so the *host* shell passes it
    # through untouched — only remotePrep, our own workspace shell, is host-expanded
    # for $wd; the guest shell is what interprets the command. When ssh returns, the
    # EXIT trap tears the VM down and removes the instance dir.
    ${workspaceScript}
    ssh -t "''${sshOpts[@]}" "$target" "''${remotePrep}exec "${lib.escapeShellArg entrypoint} || true
  '';
}

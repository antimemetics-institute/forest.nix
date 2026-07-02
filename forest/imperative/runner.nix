# mkImperativeRunner: re-evaluate a forest VM's guest with the imperative infra
# axis and return a runner launchable foreground by forest-run-vm.
#
# It's a pure `extendModules` over the already-evaluated fleet guest — no second
# guest assembly, no default.nix changes. The store axis is decided upstream by
# the VM's own `writableStore` (it gates the overlay import at host-eval); this
# only flips the net + virtiofsd + share axes that the fleet bakes for a root,
# tap-networked, systemd host:
#
#   qemu (only microvm hypervisor with unprivileged user-mode net)
#   + type=user + forwardPorts        → egress + a forwarded ssh port
#   + tap-up removed                  → no CAP_NET_ADMIN
#   + virtiofsd --sandbox=none, group=null → rootless virtiofsd
#   + guest DHCP                       → slirp 10.0.2.x instead of the fleet static IP
#   + relative share sources          → resolved against forest-run-vm's state dir
#
# See [[project-imperative-runner]] for why each knob is needed (all proven by
# hand-boot, ro + rw store).
{ lib }:

# guest    : the evaluated fleet guest, i.e. config.microvm.vms.<name>.config
# user     : the ssh user the launcher logs in as — its planted-key auth (the
#            imperative mgmt channel, analogous to the fleet's vsockSsh) is
#            injected here so VM definitions never wire it themselves
# mac      : guest NIC mac (slirp ignores it, but microvm wants one)
{ guest, user, mac ? "02:00:00:00:00:10" }:

let
  stateRoot = "/var/lib/microvms";

  # Derive the imperative share list from the guest's *already-declared* shares
  # (forest/lib/shares.nix's base set, store-overlay's nix-var, and whatever the
  # VM itself declares — e.g. agents.claude's cwd/.claude mounts). We only rebase
  # the managed state-dir sources — absolute under the fleet stateRoot — to
  # relative tag names, resolved against forest-run-vm's per-user state dir (where
  # the launcher plants each tag's runtime source). Host-path sources
  # (/nix/store, /nix/var) are unchanged. No share list is restated here.
  rebasedShares = lib.map
    (s: if lib.hasPrefix "${stateRoot}/" s.source
        then s // { source = baseNameOf s.source; }
        else s)
    guest.config.microvm.shares;

  imperative = guest.extendModules {
    modules = [{
      # Imperative mgmt channel: vsock sshd + planted-key auth + lockdown for
      # `user` — the same vsock-ssh guest module the fleet imports (with root).
      imports = [ (import ../vsock-ssh/vm.nix { inherit user; }) ];

      # qemu is required: it's the only microvm hypervisor with built-in
      # unprivileged (slirp) user-mode networking. Override at a priority stronger
      # than the fleet's normal setting (default.nix:81) but weaker than mkForce,
      # so a common cloud-hypervisor VM switches to qemu transparently, while a VM
      # that *forced* a different hypervisor keeps it and trips the assertion below
      # — surfacing a clear error instead of being silently steamrolled.
      microvm.hypervisor = lib.mkOverride 90 "qemu";
      # user-mode net (slirp) for egress only — no forwardPorts, so no TCP port on
      # the host. sshd is reached over vsock instead (below).
      microvm.interfaces = lib.mkForce [{ type = "user"; id = "usernet"; inherit mac; }];
      microvm.binScripts.tap-up = lib.mkForce "";

      # rootless virtiofsd (the fleet runs it as root)
      microvm.virtiofsd.extraArgs = [ "--sandbox=none" "--rlimit-nofile=0" ];
      microvm.virtiofsd.group = lib.mkForce null;

      # user-mode net: DHCP from slirp instead of the fleet's static IP
      systemd.network.networks."20-microvm".networkConfig = lib.mkForce { DHCP = "yes"; };

      microvm.shares = lib.mkForce rebasedShares;
    }];
  };
in
# Surface a clear error (rather than a deep microvm one) when a VM forced a
# non-qemu hypervisor — only qemu is supported imperatively for now.
assert lib.assertMsg (imperative.config.microvm.hypervisor == "qemu") ''
  forest: the imperative runner currently supports only the qemu hypervisor
  (it needs slirp user-mode networking for unprivileged egress), but this VM
  resolves to hypervisor = "${imperative.config.microvm.hypervisor}". Set the
  VM's hypervisor to "qemu" for imperative use, or drop the forced override.'';
imperative.config.microvm.declaredRunner

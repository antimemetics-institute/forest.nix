# Host-side vsock-SSH access. Imported once by forest/default.nix.
#
# Owns the shared host→VM management-SSH plumbing that both `forest ssh <vm>`
# (forest/cli) and the hot-switch (forest/hotswitch) consume:
#
#   - forest-ssh-setup: a gen-once management keypair whose public half is
#     planted into every vsock-ssh VM's host-keys share (idempotent each
#     rebuild). The guest authorizes it for root (forest/vsock-ssh/vm.nix). No
#     tight ordering is needed — a VM's first start is a cold boot, so the key is
#     long present by the time anything connects.
#   - the ssh client config that points the host's `ssh` (used by `microvm -s`,
#     hence by `forest ssh` and the switch) at that key for vsock targets.
#
# The actual dialing — `vsock-mux/<notify.vsock>` (cloud-hypervisor mux) vs
# `vsock/<cid>` (native vhost-vsock), and the mux handshake — is handled by
# systemd-ssh-proxy + `microvm -s`; forest maintains none of it.
{ config, lib, pkgs, ... }:

let
  cfg = config.forest;

  enabledVms   = lib.filterAttrs (_: vm: vm.enable) cfg.vms;
  vsockSshVms  = lib.filterAttrs (_: vm: vm.vsockSsh) enabledVms;
  anyVsockSsh  = vsockSshVms != {};

  mgmtKey = "/var/lib/forest/ssh/id_ed25519";
in
{
  config = lib.mkIf (cfg.enable && anyVsockSsh) {
    # One management keypair, public half planted per-VM into the host-keys share.
    systemd.services.forest-ssh-setup = {
      description = "Generate forest management SSH key and authorize it on vsock-ssh VMs";
      wantedBy = [ "multi-user.target" ];
      # tmpfiles creates the host-keys dirs we plant into.
      after = [ "systemd-tmpfiles-setup.service" ];
      path = [ pkgs.openssh pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "forest/ssh";
        StateDirectoryMode = "0700";
        SyslogIdentifier = "forest-ssh-setup";
      };
      script = ''
        if [ ! -f '${mgmtKey}' ]; then
          ssh-keygen -t ed25519 -N "" -C forest-host-management -f '${mgmtKey}'
        fi
        ${lib.concatMapStringsSep "\n"
          (name: "install -m 0644 '${mgmtKey}.pub' '/var/lib/microvms/${name}/host-keys/forest-mgmt.pub'")
          (lib.attrNames vsockSshVms)}
      '';
    };

    # microvm -s (used by `forest ssh` and the switch) runs `ssh` to vsock-mux/
    # and vsock/ targets with no `-i` flag (its arg parsing leaves no slot for one
    # alongside a remote command), so it relies on the client config to pick the
    # identity. Point those targets at the management key — whose public half the
    # guest authorizes for root (vsock-ssh/vm.nix). This is still strict key auth;
    # the key just comes from config instead of a flag. NixOS places
    # programs.ssh.extraConfig at the TOP of /etc/ssh/ssh_config, before
    # systemd-ssh-proxy's own `Host vsock-mux/* vsock/*` block (which supplies the
    # ProxyCommand), so IdentityFile/IdentitiesOnly here win. Scoped to root (the
    # only reader of the 0600 key, and the user the switch/forest-ssh run as).
    programs.ssh.extraConfig = ''
      Match localuser root host vsock-mux/*,vsock/*
        IdentityFile ${mgmtKey}
        IdentitiesOnly yes
        ConnectTimeout 10
    '';
  };
}

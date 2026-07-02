# Guest-side vsock-SSH access for a user. Imported by the fleet
# (forest/default.nix, user = "root") when vsockSsh = true — the shared host→VM
# management channel `forest ssh <vm>` and the hot-switch (forest/hotswitch) ride
# it — and injected by the imperative runner with its login user.
#
# It exposes sshd on vsock (microvm.vsock.ssh.enable) — socket-activated by
# systemd's ssh-generator, so each connection is its own sshd@ instance and a
# config switch that restarts sshd does not sever a live session — and
# authorizes the host's management key for `user`. No network port is opened;
# vsock is reachable only from the host.
#
# The host-side pieces (key generation/planting, the ssh client config) live in
# forest/vsock-ssh/host.nix.
{ user }:
{ pkgs, ... }:

{
  # sshd on vsock (microvm-managed, socket-activated). The host reaches us only
  # through the hypervisor's vsock.
  microvm.vsock.ssh.enable = true;

  # We expose sshd to the host, so lock it down: key-only auth, logins restricted
  # to `user` plus any ssh.users. These compose with forest/users.nix when present:
  # AllowUsers is a list and concatenates, PasswordAuthentication = false matches,
  # and plain-priority PermitRootLogin beats its mkDefault "no". PermitRootLogin is
  # unconditional because sshd gates root logins by uid, not name: the imperative
  # login user can be a uid-0 alias (agents/claude), which trips it too — while for
  # a real non-root `user` it simply has no effect (and root, lacking a planted
  # key, still can't log in).
  services.openssh.settings = {
    PasswordAuthentication = false;
    PermitRootLogin = "prohibit-password";
    AllowUsers = [ user ];
  };

  # Authorize the host's management key for `user`. The host plants its pubkey into
  # the host-keys share at /var/lib/host-keys/forest-mgmt.pub; sshd reads it from
  # there on every connection via AuthorizedKeysCommand, so there is no
  # sequencing at all — the first plant (once the VM is up) and any later re-plant
  # are both picked up on the next login attempt.
  #
  # Why the command lives in /etc rather than the nix store: sshd requires the
  # command and every directory above it (after resolving symlinks) to be
  # root-owned and not group/world-writable, and writableStore makes /nix/store
  # group-writable — so a store path (incl. the /etc/static symlink an ordinary
  # environment.etc entry resolves to) is rejected as "unsafe". An explicit mode
  # makes setup-etc COPY it into /etc as a real root-owned file, which passes.
  # Reading the planted key works because the share dir is 0711 on the host
  # (forest/default.nix tmpfiles), letting the unprivileged AuthorizedKeysCommandUser
  # traverse to the 0644 pubkey while the 0600 private host key stays unreadable.
  environment.etc."forest/mgmt-keys" = {
    mode = "0555";
    text = ''
      #!/bin/sh
      # sshd passes the user being authenticated as $1; only `${user}` carries the
      # forest management key.
      # Absolute path: sshd runs AuthorizedKeysCommand with a near-empty PATH, so
      # a bare `cat` exits 127 (command not found) and every login is rejected.
      [ "$1" = ${user} ] || exit 0
      exec ${pkgs.coreutils}/bin/cat /var/lib/host-keys/forest-mgmt.pub
    '';
  };
  services.openssh.authorizedKeysCommand = "/etc/forest/mgmt-keys %u";
  services.openssh.authorizedKeysCommandUser = "nobody";
}

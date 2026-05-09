# Per-VM users module. Imported conditionally by forest when ssh.users is non-empty.
{ users }:
{ lib, ... }:

let
  names = lib.attrNames users;
in {
  users.users = lib.mapAttrs (_: u: {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = u.shell;
    openssh.authorizedKeys.keys = u.sshKeys;
  }) users;

  # virtiofsd prevents createHome from working
  systemd.tmpfiles.rules = lib.mapAttrsToList (name: _:
    "d /home/${name} 0700 ${name} users -"
  ) users;

  services.openssh = {
    openFirewall = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      AllowUsers = names;
    };
  };

  security.sudo.wheelNeedsPassword = false;
}

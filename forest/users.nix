# Per-VM users module. Imported conditionally by forest when ssh.users is non-empty.
{ users }:
{ lib, ... }:

let
  names = lib.map (u: u.name) users;
in {
  users.users = lib.listToAttrs (lib.map (u: {
    inherit (u) name;
    value = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      shell = u.shell;
      openssh.authorizedKeys.keys = u.sshKeys;
    };
  }) users);

  # virtiofsd prevents createHome from working
  systemd.tmpfiles.rules = lib.map (u:
    "d /home/${u.name} 0700 ${u.name} users -"
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

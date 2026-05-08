# Per-VM sops-nix configuration module.
# Imported conditionally by forest when vm.sops.enable = true.
{ sops-nix, defaultSopsFile }:
{
  imports = [ sops-nix.nixosModules.sops ];

  fileSystems."/var/lib/host-keys".neededForBoot = true;
  sops.age.sshKeyPaths = [ "/var/lib/host-keys/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = defaultSopsFile;
}

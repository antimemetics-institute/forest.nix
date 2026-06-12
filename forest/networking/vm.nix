# Per-VM networking: tap interface, hostname, addresses, gateway, DNS, and
# dependsOn /etc/hosts entries. Imported per-VM by the forest module.
{ name, vm, cfg, lib, enabledVms }:
{ options, ... }:
{
  # The host side enslaves this tap into the forest bridge via networkd
  # (see networking/host.nix); no up/down hooks are involved.
  microvm.interfaces = [{
    type = "tap";
    id = vm.tapInterface;
    mac = vm.macAddress;
  }];

  networking.hostName = lib.mkForce name;
  networking.domain = lib.mkForce "forest.local";
  networking.useDHCP = lib.mkForce false;
  networking.useNetworkd = lib.mkForce true;

  networking.hosts = lib.mkMerge (
    lib.map (dep: let target = enabledVms.${dep.target}; in {
      "${target.ipv4}" = [ target.fqdn ];
      "${target.ipv6}" = [ target.fqdn ];
    }) vm.dependsOn
  );

  systemd.network = {
    enable = true;
    networks."20-microvm" = {
      # Match only physical VM interfaces, not veth/podman interfaces
      matchConfig.Name = "enp* ens* eth*";
      networkConfig = {
        DHCP = "no";
        Address = ["${vm.ipv4}/24" "${vm.ipv6}/64"];
        Gateway = [cfg.vmGateway cfg.vmGateway6];
        DNS = vm.dns.servers;
        IPv6AcceptRA = false;
      };
    };
  };

  # Feature-detect the resolved module shape (see forest/networking/host.nix
  # for the full rationale). 25.11 only has extraConfig; newer nixpkgs has
  # the structured `settings` attr.
  services.resolved = {
    enable = true;
  } // (if options.services.resolved ? settings then {
    settings.Resolve.FallbackDNS = [];
  } else {
    extraConfig = ''
      FallbackDNS=
    '';
  });
}

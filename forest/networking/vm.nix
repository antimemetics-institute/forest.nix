# Per-VM networking: hostname, addresses, gateway, DNS, and dependsOn
# /etc/hosts entries. Imported per-VM by the forest module.
{ name, vm, cfg, lib, enabledVms }:
{
  networking.hostName = lib.mkForce name;
  networking.domain = lib.mkForce "forest.local";
  networking.useDHCP = lib.mkForce false;
  networking.useNetworkd = lib.mkForce true;

  networking.hosts = lib.mkMerge (
    lib.map (dep: {
      "${enabledVms.${dep.target}.ipv4}" = [ "${dep.target}.forest.local" ];
      "${enabledVms.${dep.target}.ipv6}" = [ "${dep.target}.forest.local" ];
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

  services.resolved = {
    enable = true;
    fallbackDns = [];
  };
}

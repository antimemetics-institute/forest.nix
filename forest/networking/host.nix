# Host-side networking for forest: bridge, NAT, firewall, IP forwarding,
# and the per-VM TAP-after-bridge ordering. Imported by the forest module.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.forest;
  forestUtils = import ../utils { inherit lib; };
  enabledVms = lib.filterAttrs (_: vm: vm.enable) cfg.vms;
  internetVms = lib.filterAttrs (_: vm: vm.internetAccess) enabledVms;
  constrainedVms = lib.filterAttrs (_: vm: vm.dns.constrain) enabledVms;
in {
  config = mkIf cfg.enable {
    networking.hosts = mkMerge (lib.mapAttrsToList (name: vm: {
      "${vm.ipv4}" = [ "${name}.forest.local" ];
      "${vm.ipv6}" = [ "${name}.forest.local" ];
    }) enabledVms);

    # Forest needs IP forwarding for NAT and inter-bridge routing. mkDefault
    # so a user with a specific reason to disable it can still override.
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.ipv6.conf.all.forwarding" = lib.mkDefault 1;
    };

    networking.networkmanager.unmanaged =
      [ "interface-name:${cfg.bridgeInterface}" ]
      ++ lib.mapAttrsToList (_: vm: "interface-name:${vm.tapInterface}") enabledVms;

    networking.bridges.${cfg.bridgeInterface} = {
      interfaces = [ ];
    };

    networking.interfaces.${cfg.bridgeInterface} = {
      ipv4.addresses = [{
        address = cfg.vmGateway;
        prefixLength = 24;
      }];
      ipv6.addresses = [{
        address = cfg.vmGateway6;
        prefixLength = 64;
      }];
    };

    networking.firewall = {
      trustedInterfaces = [ cfg.bridgeInterface ];
    };

    networking.nftables.tables = {
      "forest_filter" = {
        family = "inet";
        content = ''
          chain input {
            type filter hook input priority -100; policy accept;

            # Allow established/related connections (handles return traffic from host-initiated connections)
            ct state { established, related } accept comment "Allow return traffic"

            # Per-VM DNS access to configured servers
            ${forestUtils.generateDnsInputRules enabledVms}

            # Allow essential ICMPv6 for IPv6 to work (neighbor discovery, etc)
            ip6 saddr ${cfg.vmSubnet6} icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert, echo-request, echo-reply } accept comment "Essential ICMPv6"

            # Block VM subnet from accessing other VMs or host services
            ip saddr ${cfg.vmSubnet} drop comment "Block VMs from other host services IPv4"
            ip6 saddr ${cfg.vmSubnet6} drop comment "Block VMs from other host services IPv6"
          }

          chain forward {
            type filter hook forward priority 0; policy accept;

            # Allow established/related connections (handles return traffic)
            ct state { established, related } accept comment "Allow established connections"

            # Per-VM DNS constrain rules (allow configured servers, drop the rest)
            ${forestUtils.generateDnsConstrainRules constrainedVms}

            # VM-specific dependency rules
            ${forestUtils.generateAllVmConnectionRules enabledVms}

            # Per-VM internet access (only VMs with internetAccess)
            ${forestUtils.generateInternetForwardRules internetVms}
          }
        '';
      };

      "forest_nat" = {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
${forestUtils.generateNat4Rules cfg.externalInterface internetVms}
          }
        '';
      };

      "forest_nat6" = {
        family = "ip6";
        content = ''
          chain postrouting {
            type nat hook postrouting priority 100; policy accept;
${forestUtils.generateNat6Rules cfg.externalInterface internetVms}
          }
        '';
      };
    };

    # Ensure TAP interfaces wait for the bridge — fixes a race at boot.
    systemd.services = lib.mapAttrs' (name: _vm:
      lib.nameValuePair "microvm-tap-interfaces@${name}" {
        after = [
          "microvm-netdev.service"
          "sys-subsystem-net-devices-${cfg.bridgeInterface}.device"
          "network-addresses-${cfg.bridgeInterface}.service"
        ];
        requires = [
          "microvm-netdev.service"
          "sys-subsystem-net-devices-${cfg.bridgeInterface}.device"
        ];
      }
    ) enabledVms;

    assertions = [
      {
        assertion = (config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1 ||
                     config.boot.kernel.sysctl."net.ipv4.ip_forward" == "1") &&
                    (config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == 1 ||
                     config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == "1");
        message = ''
          The forest module requires IP forwarding to be enabled for NAT to work.
          Forest sets these via lib.mkDefault, so something in your config has
          overridden them back to off. Either drop that override or accept that
          forest VMs won't reach the network:

          boot.kernel.sysctl = {
            "net.ipv4.ip_forward" = 1;
            "net.ipv6.conf.all.forwarding" = 1;
          };
        '';
      }
    ];
  };
}

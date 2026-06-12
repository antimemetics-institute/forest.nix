# Host-side networking for forest: bridge and tap enslavement (via
# systemd-networkd), NAT, firewall, IP forwarding. Imported by the forest
# module.
{ config, options, lib, ... }:

with lib;

let
  cfg = config.forest;
  forestUtils = import ../utils { inherit lib; };
  enabledVms = lib.filterAttrs (_: vm: vm.enable) cfg.vms;
  internetVms = lib.filterAttrs (_: vm: vm.internetAccess) enabledVms;
  restrictedVms = lib.filterAttrs (_: vm: vm.dns.restrict) enabledVms;
in {
  config = mkIf cfg.enable {
    networking.hosts = mkMerge (lib.mapAttrsToList (_: vm: {
      "${vm.ipv4}" = [ vm.fqdn ];
      "${vm.ipv6}" = [ vm.fqdn ];
    }) enabledVms);

    # Forest needs IP forwarding for NAT and inter-bridge routing. mkDefault
    # so a user with a specific reason to disable it can still override.
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = mkDefault true;
      "net.ipv6.conf.all.forwarding" = mkDefault true;
    };

    # Forest's firewall rules are written as nftables rules.
    networking.nftables.enable = mkDefault true;

    networking.networkmanager.unmanaged =
      [ "interface-name:${cfg.bridgeInterface}" ]
      ++ lib.mapAttrsToList (_: vm: "interface-name:${vm.tapInterface}") enabledVms;

    # The bridge and tap enslavement are declarative networkd state, not
    # scripted-networking oneshots. networkd reconciles continuously: a tap
    # is (re-)enslaved whenever the tap or the bridge (re)appears, so bridge
    # recreation on a rebuild can't strand running VMs' taps. The scripted
    # backend's <bridge>-netdev.service deletes and recreates the bridge on
    # every start, detaching all runtime-enslaved ports with no reconciler.
    systemd.network.enable = true;

    systemd.network.netdevs."10-forest-bridge" = {
      netdevConfig = {
        Kind = "bridge";
        Name = cfg.bridgeInterface;
      };
    };

    systemd.network.networks."10-forest-bridge" = {
      matchConfig.Name = cfg.bridgeInterface;
      address = [
        "${cfg.vmGateway}/24"
        "${cfg.vmGateway6}/64"
      ];
      # With all VMs stopped the bridge has no ports and thus no carrier;
      # configure its addresses anyway, and never block network-online on it.
      networkConfig.ConfigureWithoutCarrier = true;
      linkConfig.RequiredForOnline = "no";
    };

    systemd.network.networks."11-forest-taps" = lib.mkIf (enabledVms != { }) {
      matchConfig.Name =
        lib.concatStringsSep " " (lib.mapAttrsToList (_: vm: vm.tapInterface) enabledVms);
      networkConfig.Bridge = cfg.bridgeInterface;
      linkConfig.RequiredForOnline = "no";
    };

    networking.firewall = {
      trustedInterfaces = [ cfg.bridgeInterface ];
    };

    # When forest serves DNS to VMs via the host bridge, run systemd-resolved
    # and bind its stub to the bridge IPs so VMs can hit it. Users with their
    # own resolver on the bridge can disable this with forest.serveDns = false.
    #
    # Feature-detects the resolved module shape: newer nixpkgs uses structured
    # settings.Resolve; older nixpkgs uses the free-form extraConfig string.
    # Version-checking is unreliable here because the channel branch can ship
    # the new module before lib.version bumps to the next release.
    # FIXME: drop the extraConfig branch once 26.05 is released and 25.11 EOL.
    services.resolved = lib.mkIf cfg.serveDns ({
      enable = true;
    } // (if options.services.resolved ? settings then {
      settings.Resolve.DNSStubListenerExtra = [ cfg.vmGateway cfg.vmGateway6 ];
    } else {
      extraConfig = ''
        DNSStubListenerExtra=${cfg.vmGateway}
        DNSStubListenerExtra=${cfg.vmGateway6}
      '';
    }));

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

            # Block VM subnet from accessing host services
            ip saddr ${cfg.vmSubnet} drop comment "Block VMs from other host services IPv4"
            ip6 saddr ${cfg.vmSubnet6} drop comment "Block VMs from other host services IPv6"
          }

          chain forward {
            type filter hook forward priority 0; policy accept;

            # Allow established/related connections (handles return traffic)
            ct state { established, related } accept comment "Allow established connections"

            # Per-VM DNS restrict rules (allow configured servers, drop the rest)
            ${forestUtils.generateDnsRestrictRules restrictedVms}

            # VM-specific dependency rules
            ${forestUtils.generateAllVmConnectionRules enabledVms}

            # Block other inter-VM forward traffic
            ip saddr ${cfg.vmSubnet} ip daddr ${cfg.vmSubnet} drop comment "Block VM traffic from being forwarded IPv4"
            ip6 saddr ${cfg.vmSubnet6} ip6 daddr ${cfg.vmSubnet6} drop comment "Block VM traffic from being forwarded IPv6"

            # Per-VM internet access (only VMs with internetAccess)
            ${forestUtils.generateInternetForwardRules internetVms}

            # Block all other VM subnet forward traffic
            ip saddr ${cfg.vmSubnet} drop comment "Block VM traffic from being forwarded IPv4"
            ip6 saddr ${cfg.vmSubnet6} drop comment "Block VM traffic from being forwarded IPv6"
          }
        '';
      };

      "forest_nat" = {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
${forestUtils.generateNat4Rules cfg.bridgeInterface internetVms}
          }
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;
${forestUtils.generatePortForwardRules "ipv4" enabledVms}
          }
        '';
      };

      "forest_nat6" = {
        family = "ip6";
        content = ''
          chain postrouting {
            type nat hook postrouting priority 100; policy accept;
${forestUtils.generateNat6Rules cfg.bridgeInterface internetVms}
          }
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;
${forestUtils.generatePortForwardRules "ipv6" enabledVms}
          }
        '';
      };
    };

    assertions = [
      {
        assertion = (config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1 ||
                     config.boot.kernel.sysctl."net.ipv4.ip_forward" == "1" ||
                     config.boot.kernel.sysctl."net.ipv4.ip_forward" == true ||
                     config.boot.kernel.sysctl."net.ipv4.ip_forward" == "true") &&
                    (config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == 1 ||
                     config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == "1" ||
                     config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == true ||
                     config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == "true");
        message = ''
          Forest requires IP forwarding to be enabled for NAT to work:

          boot.kernel.sysctl = {
            "net.ipv4.ip_forward" = true;
            "net.ipv6.conf.all.forwarding" = true;
          };
        '';
      }
      {
        assertion = config.networking.nftables.enable;
        message = ''
          Forest requires nftables to be enabled:

          networking.nftables.enable = true;

          Forest's firewall (inter-VM isolation, NAT for internetAccess,
          inbound port forwards, DNS restrict) is implemented entirely as
          nftables tables, which the nftables module only loads when this
          option is true. Without it, VMs reach each other and the host
          freely, NAT masquerade doesn't happen, and DNAT doesn't work.
        '';
      }
    ]
    # Each forwardPort must scope itself: at least one of `interface` or
    # `bindAddress` must be explicitly set. The bindAddress default is null;
    # leaving both unset is a footgun (forwards every interface silently), so
    # we make the user opt in by writing the any-address tokens out.
    ++ lib.flatten (lib.mapAttrsToList (vmName: vm:
      lib.imap0 (i: pf: {
        assertion = pf.interface != null || pf.bindAddress != null;
        message = ''
          forest.vms.${vmName}.forwardPorts[${toString i}] (port ${toString pf.port},
          protocol ${pf.protocol}) sets neither `interface` nor `bindAddress`.
          One of them must be set so the forward is scoped to a specific
          interface or destination address — otherwise every inbound packet
          to that port on any interface would be redirected to the VM.

          Pick one:
            interface   = "tailscale0";        # tailnet only
            bindAddress = "203.0.113.5";       # specific public v4 only
            bindAddress = [ "0.0.0.0" "::" ];  # explicit "any address, both families"
        '';
      }) vm.forwardPorts
    ) enabledVms);
  };
}

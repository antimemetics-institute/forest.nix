# Host-side networking for forest: bridge, NAT, firewall, IP forwarding,
# and the per-VM TAP-after-bridge ordering. Imported by the forest module.
{ config, options, lib, pkgs, ... }:

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

            # Block VM subnet from accessing other VMs or host services
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

    # Ensure TAP interfaces wait for the bridge — fixes a race at boot.
    systemd.services = {
      # Bring the addresses unit up alongside the bridge after a rebuild restart;
      # WantedBy=network.target only fires at boot, so it would otherwise stay dead.
      "${cfg.bridgeInterface}-netdev".wants =
        [ "network-addresses-${cfg.bridgeInterface}.service" ];
    } // lib.mapAttrs' (name: _vm:
      lib.nameValuePair "microvm-tap-interfaces@${name}" {
        after = [
          "sys-subsystem-net-devices-${cfg.bridgeInterface}.device"
          "network-addresses-${cfg.bridgeInterface}.service"
        ];
        requires = [
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

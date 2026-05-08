{ config, pkgs, lib, microvm, sops-nix, ... }:

with lib;

let
  cfg = config.forest;
  forestUtils = import ./utils.nix { inherit lib; };

  userSubmodule = { ... }: {
    options = {
      name = mkOption {
        type = types.str;
        description = "Username.";
      };
      sshKeys = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "SSH public keys authorized to log in as this user.";
      };
      shell = mkOption {
        type = types.package;
        default = pkgs.bashInteractive;
        description = "Login shell for the user.";
      };
    };
  };

  vmSubmodule = { name, config, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "VM for running some services.";
      };

      index = mkOption {
        type = types.int;
        description = ''
          Stable index for this VM, used to derive its IPv4, IPv6, MAC address, and vsock CID.
          Must be unique across all VMs. The resulting IPv4 will be 192.168.69.(10 + index).
          Once assigned, never change it — just give new VMs the next unused number.
        '';
      };

      hypervisor = mkOption {
        type = types.str;
        default = "cloud-hypervisor";
        description = "What hypervisor implementation to use.";
      };

      tapInterface = mkOption {
        type = types.str;
        readOnly = true;
        description = "Interface name used by microvm.";
      };

      ipv4 = mkOption {
        type = types.str;
        readOnly = true;
        description = "IPv4 address derived from index.";
      };

      ipv6 = mkOption {
        type = types.str;
        readOnly = true;
        description = "IPv6 address derived from index.";
      };

      macAddress = mkOption {
        type = types.str;
        readOnly = true;
        description = "MAC address derived from index.";
      };

      vsockCid = mkOption {
        type = types.int;
        readOnly = true;
        description = "Vsock CID derived from index.";
      };

      memory = mkOption {
        type = types.int;
        default = 2048;
        description = "Memory allocation in MB.";
      };

      vcpu = mkOption {
        type = types.int;
        default = 4;
        description = "Number of virtual CPUs.";
      };

      stateVersion = mkOption {
        type = types.str;
        default = "25.11";
        description = ''
          system.stateVersion for the VM. Pinned at first deployment to preserve
          NixOS option defaults across host upgrades; bump only when you've reviewed
          the release notes and migrated any persistent state.
        '';
      };

      writableStore = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether the VM gets a writable nix store overlay on top of the host's
          read-only store. Lets nix-shell / nix build / etc. work inside the VM.
          The overlay image is wiped on each VM start (boots stay fast and clean).
        '';
      };

      pciPassthrough = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "0000:06:00.0" "0000:06:00.1" ];
        description = ''
          PCI device addresses to pass through to the VM via VFIO. The host
          unbinds each device from its current driver and rebinds to vfio-pci
          before the VM starts. Cloud-hypervisor's PCI passthrough is fragile,
          so this requires hypervisor = "qemu". The host-level IOMMU kernel
          params (intel_iommu=on, iommu=pt) are already set by forest.
        '';
      };

      config = mkOption {
        type = types.deferredModule;
        description = "A NixOS configuration module for the VM.";
      };

      sops = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable sops-nix secret management for this VM.";
        };
        defaultSopsFile = mkOption {
          type = types.path;
          description = "Path to the default sops secrets file for this VM.";
        };
      };

      ssh.users = mkOption {
        type = types.listOf (types.submodule userSubmodule);
        default = [];
        description = ''
          Users to create with SSH access to this VM. Each entry is
          { name; sshKeys; shell; }. When non-empty, sshd opens to the host network.
        '';
      };

      internetAccess = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this VM can reach the public internet.";
      };

      dns = {
        servers = mkOption {
          type = types.listOf types.str;
          default = cfg.dns.servers;
          defaultText = literalExpression "config.forest.dns.servers";
          description = "DNS servers this VM is configured to use.";
        };
        constrain = mkOption {
          type = types.bool;
          default = cfg.dns.constrain;
          defaultText = literalExpression "config.forest.dns.constrain";
          description = ''
            If true, this VM may only resolve via dns.servers — DNS to any other
            destination is dropped at the firewall.
          '';
        };
      };

      dependsOn = mkOption {
        type = types.listOf (types.submodule {
          options = {
            target = mkOption {
              type = types.str;
              description = "Target VM name.";
            };
            port = mkOption {
              type = types.port;
              description = "Port number to allow.";
            };
            protocol = mkOption {
              type = types.enum [ "tcp" "udp" "both" ];
              default = "tcp";
              description = "Protocol (tcp, udp, or both).";
            };
            ipVersion = mkOption {
              type = types.enum [ "ipv4" "ipv6" "both" ];
              default = "both";
              description = "IP version (ipv4, ipv6, or both).";
            };
          };
        });
        default = [];
        description = ''
          List of VMs this VM can connect to with specific ports/protocols.
          Connection tracking handles return traffic automatically.
          Example: [
            { target = "db"; port = 5432; protocol = "tcp"; ipVersion = "both"; }
            { target = "cache"; port = 6379; protocol = "tcp"; }
          ]
        '';
      };
    };
    config =
      let
        idx = config.index;
        macHex = lib.strings.toLower (lib.toHexString (1 + idx));
        macPadded = if builtins.stringLength macHex == 1 then "0${macHex}" else macHex;
      in {
        tapInterface = "vm-${name}";
        ipv4 = "192.168.69.${toString (10 + idx)}";
        ipv6 = "fd69::${toString (10 + idx)}";
        macAddress = "02:00:00:42:00:${macPadded}";
        vsockCid = 420 + idx;
      };
  };
in
{
  options.forest = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Forest VM management.";
    };

    vms = mkOption {
      type = types.attrsOf (types.submodule vmSubmodule);
      default = {};
      description = "VMs to create with microvm.";
    };

    commonConfig = mkOption {
      type = types.deferredModule;
      default = {};
      description = ''
        NixOS module applied to every VM in this forest. Useful for cross-cutting
        concerns like a shared kernel, packages, or sysctl. Supports
        `imports = [ ./foo.nix ];` like any other module.
      '';
    };

    externalInterface = mkOption {
      type = types.str;
      description = "External interface for internet access (used for NAT masquerade).";
    };

    vmSubnet = mkOption {
      type = types.str;
      default = "192.168.69.0/24";
      description = "IPv4 subnet for the VMs.";
    };

    vmSubnet6 = mkOption {
      type = types.str;
      default = "fd69::/64";
      description = "IPv6 subnet for the VMs.";
    };

    vmGateway = mkOption {
      type = types.str;
      default = "192.168.69.1";
      description = "Gateway/host IP for the VMs.";
    };

    vmGateway6 = mkOption {
      type = types.str;
      default = "fd69::1";
      description = "IPv6 gateway/host for the VMs.";
    };

    bridgeInterface = mkOption {
      type = types.str;
      default = "forest";
      description = "Bridge interface for NAT and VM networking.";
    };

    dns = {
      servers = mkOption {
        type = types.listOf types.str;
        default =
          if config.networking.nameservers != []
          then config.networking.nameservers
          else [ "1.1.1.1" "1.0.0.1" ];
        defaultText = literalExpression ''
          if config.networking.nameservers != []
          then config.networking.nameservers
          else [ "1.1.1.1" "1.0.0.1" ]
        '';
        description = ''
          Default DNS servers for VMs. Inherited per-VM via dns.servers, which
          can override individually.
        '';
      };
      constrain = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Default for per-VM dns.constrain. If true, VMs may only resolve via
          their dns.servers — DNS to any other destination is dropped at the firewall.
        '';
      };
    };
  };

  config = mkIf cfg.enable (
    let
      enabledVms = lib.filterAttrs (_: vm: vm.enable) cfg.vms;
      vmNames = lib.attrNames enabledVms;
      internetVms = lib.filterAttrs (_: vm: vm.internetAccess) enabledVms;
      constrainedVms = lib.filterAttrs (_: vm: vm.dns.constrain) enabledVms;
      forestCli = import ./cli { inherit lib pkgs vmNames; };
    in {
      networking.hosts = mkMerge (lib.mapAttrsToList (name: vm: {
        "${vm.ipv4}" = [ "${name}.forest.local" ];
        "${vm.ipv6}" = [ "${name}.forest.local" ];
      }) enabledVms);

      boot.kernelModules = [ "kvm-intel" ];
      boot.kernelParams = [
        "intel_iommu=on"
        "iommu=pt"
      ];

      environment.systemPackages = (with pkgs; [
        curl
        socat
        openssh
      ]) ++ [ forestCli.forest ];

      environment.etc."bash_completion.d/forest".source = forestCli.completion;

      users.groups.microvm = {};

      fileSystems."/var/lib/microvms" = {
        device = "/var/lib/microvms";
        fsType = "none";
        options = [ "bind" "nosuid" "nodev" "noexec" ];
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

      microvm = {
        autostart = lib.attrNames enabledVms;

        vms = lib.mapAttrs (name: vm: {
          config = {
            imports = [
              microvm.nixosModules.microvm
              cfg.commonConfig
              vm.config
            ] ++ lib.optional vm.writableStore ./store-overlay/vm.nix
            ++ lib.optional vm.sops.enable (import ./secrets.nix {
              inherit sops-nix;
              defaultSopsFile = vm.sops.defaultSopsFile;
            })
            ++ lib.optional (vm.ssh.users != []) (import ./users.nix {
              users = vm.ssh.users;
            });

            system.stateVersion = lib.mkDefault vm.stateVersion;

            microvm = {
              hypervisor = vm.hypervisor;
              mem = vm.memory;
              vcpu = vm.vcpu;
              vsock.cid = vm.vsockCid;
              devices = lib.map (path: { bus = "pci"; inherit path; }) vm.pciPassthrough;

              interfaces = [{
                type = "tap";
                id = vm.tapInterface;
                mac = vm.macAddress;
              }];

              binScripts.tap-up = lib.mkAfter ''
                ${pkgs.iproute2}/bin/ip link set dev ${vm.tapInterface} master ${cfg.bridgeInterface}
              '';

              shares = [
                {
                  proto = "virtiofs";
                  tag = "home";
                  source = "/var/lib/microvms/${name}/home";
                  mountPoint = "/home";
                }
                {
                  proto = "virtiofs";
                  tag = "logs";
                  source = "/var/lib/microvms/${name}/logs";
                  mountPoint = "/var/log";
                }
                # Persistent SSH host keys — stable identity across rebuilds.
                # sshd generates the key here on first boot if missing.
                # Public key can be converted to age format for sops: ssh-keyscan <ip> | ssh-to-age
                {
                  proto = "virtiofs";
                  tag = "host-keys";
                  source = "/var/lib/microvms/${name}/host-keys";
                  mountPoint = "/var/lib/host-keys";
                }
                {
                  proto = "virtiofs";
                  tag = "nix-store";
                  source = "/nix/store";
                  mountPoint = "/nix/.ro-store";
                }
              ];
            };

            services.openssh = {
              enable = true;
              openFirewall = lib.mkDefault false;
              hostKeys = [{
                type = "ed25519";
                path = "/var/lib/host-keys/ssh_host_ed25519_key";
              }];
            };

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
          };
        }) enabledVms;
      };

      systemd.tmpfiles.rules =
        [ "d /var/lib/microvms 0700 microvm microvm -" ]
        ++ lib.flatten (lib.mapAttrsToList (name: vm: [
          "d /var/lib/microvms/${name} 0700 microvm microvm -"
          "d /var/lib/microvms/${name}/home 0755 microvm microvm -"
          "d /var/lib/microvms/${name}/logs 0700 microvm microvm -"
          "d /var/lib/microvms/${name}/nix-store 0700 microvm microvm -"
          "d /var/lib/microvms/${name}/host-keys 0700 microvm microvm -"
        ]) enabledVms);

      systemd.services = lib.concatMapAttrs (name: vm: {
        # Ensure TAP interfaces wait for the bridge — fixes a race at boot.
        "microvm-tap-interfaces@${name}" = {
          after = [
            "microvm-netdev.service"
            "sys-subsystem-net-devices-${cfg.bridgeInterface}.device"
            "network-addresses-${cfg.bridgeInterface}.service"
          ];
          requires = [
            "microvm-netdev.service"
            "sys-subsystem-net-devices-${cfg.bridgeInterface}.device"
          ];
        };
      } // lib.optionalAttrs vm.writableStore (
        import ./store-overlay/host.nix { inherit name lib; }
      ) // lib.optionalAttrs (vm.pciPassthrough != []) {
        # PCI unbinding can flake on first attempt; retry with backoff so the
        # VM doesn't fail-to-start on a transient driver-busy.
        "microvm-pci-devices@${name}" = {
          serviceConfig = {
            RestartMode = "direct";
            Restart = "on-failure";
            RestartSec = "5s";
            StartLimitBurst = 3;
            StartLimitIntervalSec = 30;
          };
        };
      }) enabledVms;

      assertions = [
        {
          assertion = (config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1 ||
                       config.boot.kernel.sysctl."net.ipv4.ip_forward" == "1") &&
                      (config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == 1 ||
                       config.boot.kernel.sysctl."net.ipv6.conf.all.forwarding" == "1");
          message = ''
            The forest module requires IP forwarding to be enabled for NAT to work.
            Please add the following to your configuration:

            boot.kernel.sysctl = {
              "net.ipv4.ip_forward" = 1;
              "net.ipv6.conf.all.forwarding" = 1;
            };
          '';
        }
        {
          assertion = (lib.length vmNames) <= 245;
          message = ''
            Too many VMs configured! The forest module supports a maximum of 245 VMs.
            You have ${toString (lib.length vmNames)} VMs enabled.
            If you're hitting this wall, please open an issue! It's easy to fix.
          '';
        }
      ] ++ (let
        indexPairs = lib.mapAttrsToList (name: vm: { inherit name; idx = vm.index; }) enabledVms;
        findDuplicates = pairs:
          lib.filter (a:
            lib.any (b: a.name != b.name && a.idx == b.idx) pairs
          ) pairs;
        duplicates = findDuplicates indexPairs;
        duplicateMsg = lib.concatMapStringsSep ", " (d: "'${d.name}' (index ${toString d.idx})") duplicates;
      in [{
        assertion = duplicates == [];
        message = "Duplicate forest VM indices detected: ${duplicateMsg}. Each VM must have a unique index.";
      }])
      ++ (lib.mapAttrsToList (_: vm: {
        assertion = vm.index >= 0 && vm.index <= 244;
        message = "VM index ${toString vm.index} out of range. Must be 0-244 (maps to .10-.254).";
      }) enabledVms)
      ++ (lib.flatten (lib.mapAttrsToList (vmName: vm:
        lib.map (dep: {
          assertion = lib.elem dep.target vmNames;
          message = ''
            VM '${vmName}' depends on '${dep.target}', but VM '${dep.target}' does not exist or is not enabled.
            Available VMs: ${lib.concatStringsSep ", " vmNames}
          '';
        }) vm.dependsOn
      ) enabledVms))
      ++ (lib.mapAttrsToList (vmName: vm: {
        assertion = vm.pciPassthrough == [] || vm.hypervisor == "qemu";
        message = ''
          VM '${vmName}' has pciPassthrough set but hypervisor = "${vm.hypervisor}".
          PCI passthrough only works reliably under QEMU; set hypervisor = "qemu".
        '';
      }) enabledVms);
    }
  );
}

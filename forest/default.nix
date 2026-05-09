{ microvmSrc, sopsNixSrc }:
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.forest;
  forestUtils = import ./utils { inherit lib; };

  userSubmodule = { ... }: {
    options = {
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

  vmSubmodule = { name, config, allResolvedIndices, ... }: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "VM for running some services.";
      };

      index = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Optional explicit index for this VM. If null (default), an index is
          auto-assigned: VMs are walked in name order and given the lowest free
          slot, skipping any indices pinned by other VMs.

          Set this to pin a VM to a specific slot (e.g. to keep its IPv4 stable
          even if VMs sorting before it are added or removed). Once a VM is
          deployed, don't change its index — the resulting IPv4 is part of its
          identity.

          The resolved index drives IPv4 (192.168.69.[10+index]), IPv6, MAC,
          and vsock CID. Range: 0–244.
        '';
      };

      _index = mkOption {
        type = types.int;
        readOnly = true;
        internal = true;
        description = "Resolved index (explicit if set, else auto-assigned).";
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

      memorySize = mkOption {
        type = types.int;
        default = 2048;
        description = "Memory allocation in MB.";
      };

      cores = mkOption {
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
        type = types.attrsOf (types.submodule userSubmodule);
        default = {};
        description = ''
          Users to create with SSH access to this VM, keyed by username. Each
          entry is { sshKeys; shell; }. When non-empty, sshd opens to the
          host network.
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
        restrict = mkOption {
          type = types.bool;
          default = cfg.dns.restrict;
          defaultText = literalExpression "config.forest.dns.restrict";
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

      forwardPorts = mkOption {
        type = types.listOf (types.submodule {
          options = {
            port = mkOption {
              type = types.port;
              description = "Port inside the VM where the service listens.";
            };
            hostPort = mkOption {
              type = types.nullOr types.port;
              default = null;
              description = ''
                Port the host accepts the connection on. Defaults to `port`.
              '';
            };
            protocol = mkOption {
              type = types.enum [ "tcp" "udp" "both" ];
              description = "Protocol to forward (tcp, udp, or both).";
            };
            interface = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Host interface (iifname) to scope the forward to. Optional.
                Useful for "only forward packets arriving on tailscale0/wg0/...".
              '';
            };
            bindAddress = mkOption {
              type = types.nullOr (types.either types.str (types.listOf types.str));
              default = null;
              description = ''
                Host destination address(es) to scope the forward to. A single
                string or a list of strings. The IP family of each address is
                inferred (colon → IPv6); use the sentinels "0.0.0.0" and "::"
                to mean "any address" of that family.

                If left null and `interface` is set, defaults to
                [ "0.0.0.0" "::" ] (any address, both families). At least one
                of `interface` / `bindAddress` must be set explicitly — leaving
                both unset is rejected at eval time so a forward can't quietly
                expose a port on every interface.
              '';
            };
          };
        });
        default = [];
        description = ''
          List of inbound port forwards (DNAT) into this VM. Forest emits
          prerouting rules; you bring your own tunnel (tailscale, wireguard,
          a public NIC). Connection tracking handles return traffic.
          Example: [
            { port = 22; protocol = "tcp"; interface = "tailscale0"; }
            { port = 80; hostPort = 8080; protocol = "tcp"; bindAddress = "203.0.113.5"; }
          ]
        '';
      };
    };
    config =
      let
        idx = allResolvedIndices.${name};
        macHex = lib.strings.toLower (lib.toHexString (1 + idx));
        macPadded = if builtins.stringLength macHex == 1 then "0${macHex}" else macHex;
      in {
        _index = idx;
        tapInterface = "vm-${name}";
        ipv4 = "192.168.69.${toString (10 + idx)}";
        ipv6 = "fd69::${toString (10 + idx)}";
        macAddress = "02:00:00:42:00:${macPadded}";
        vsockCid = 420 + idx;
      };
  };
in
{
  imports = [
    ./networking/host.nix
    "${microvmSrc}/nixos-modules/host"
  ];

  options.forest = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Forest VM management.";
    };

    vms = mkOption {
      type = types.attrsOf (types.submoduleWith {
        # `cfg.common` is added to every VM's evaluation, so any VM option set
        # there flows into the per-VM merge under normal module-system rules:
        # lists concatenate, modules merge, scalars conflict (use mkDefault).
        modules = [ vmSubmodule cfg.common ];
        # Match what `types.submodule vm` does. Without this, the option named
        # `config` collides with the module-system reserved key and users
        # can't have both `config = {...}` and `index = N` on the same VM.
        shorthandOnlyDefinesConfig = true;
        # Resolve indices once at the type level and pass the result through
        # specialArgs. Reading `config.forest.vms` here is structurally OK:
        # `resolveIndices` only inspects each VM's user-set `index` (default
        # null), which doesn't depend on specialArgs, so there's no cycle.
        specialArgs = {
          allResolvedIndices = forestUtils.resolveIndices config.forest.vms;
        };
      });
      default = {};
      description = "VMs to create with microvm.";
    };

    common = mkOption {
      type = types.deferredModule;
      default = {};
      description = ''
        Module merged into every VM. Reuses the per-VM option schema, so any
        VM-level option (config, ssh.users, memorySize, dns, ...) can be set
        here as a shared default or addition.

        Definitions follow normal module-system merge rules:
          - attrsets (e.g. ssh.users) merge per-key with per-VM definitions;
            same key in both is a conflict (use lib.mkForce to override)
          - the inner `config` module merges as modules always do
          - scalars (e.g. memorySize) conflict with per-VM definitions; wrap
            in lib.mkDefault to make them overridable

        Example:
          forest.common = {
            ssh.users.ops.sshKeys = [ "ssh-ed25519 ..." ];
            memorySize = lib.mkDefault 4096;
            config = { pkgs, ... }: {
              environment.systemPackages = [ pkgs.htop ];
            };
          };
      '';
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
      restrict = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Default for per-VM dns.restrict. If true, VMs may only resolve via
          their dns.servers — DNS to any other destination is dropped at the firewall.
        '';
      };
    };
  };

  config = mkIf cfg.enable (
    let
      enabledVms = lib.filterAttrs (_: vm: vm.enable) cfg.vms;
      vmNames = lib.attrNames enabledVms;
      anyPciPassthrough = lib.any (vm: vm.pciPassthrough != []) (lib.attrValues enabledVms);
      forestCli = import ./cli { inherit lib pkgs vmNames; };
    in {
      # Load both KVM modules; the one whose hardware isn't present silently
      # no-ops (logged in dmesg, not fatal). Avoids forcing a CPU-vendor option.
      boot.kernelModules = [ "kvm-intel" "kvm-amd" ];

      # IOMMU is only needed for VFIO PCI passthrough. Set both vendors' params
      # when any VM declares pciPassthrough — the kernel ignores the irrelevant one.
      boot.kernelParams = lib.optionals anyPciPassthrough [
        "intel_iommu=on"
        "amd_iommu=on"
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

      microvm = {
        autostart = lib.attrNames enabledVms;

        vms = lib.mapAttrs (name: vm: {
          config = {
            imports = [
              "${microvmSrc}/nixos-modules/microvm"
              vm.config
              (import ./networking/vm.nix { inherit name vm cfg lib enabledVms; })
            ] ++ lib.optional vm.writableStore ./store-overlay/vm.nix
            ++ lib.optional vm.sops.enable (import ./secrets.nix {
              inherit sopsNixSrc;
              defaultSopsFile = vm.sops.defaultSopsFile;
            })
            ++ lib.optional (vm.ssh.users != {}) (import ./users.nix {
              users = vm.ssh.users;
            });

            system.stateVersion = lib.mkDefault vm.stateVersion;

            microvm = {
              hypervisor = vm.hypervisor;
              mem = vm.memorySize;
              vcpu = vm.cores;
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

      systemd.services = lib.concatMapAttrs (name: vm:
        lib.optionalAttrs vm.writableStore (
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
        }
      ) enabledVms;

      assertions = [
        {
          assertion = (lib.length vmNames) <= 245;
          message = ''
            Too many VMs configured! The forest module supports a maximum of 245 VMs.
            You have ${toString (lib.length vmNames)} VMs enabled.
            If you're hitting this wall, please open an issue! It's easy to fix.
          '';
        }
      ] ++ (let
        # Only explicit indices can collide — auto-assignment can't produce duplicates.
        explicitVms = lib.filterAttrs (_: vm: vm.index != null) enabledVms;
        indexPairs = lib.mapAttrsToList (name: vm: { inherit name; idx = vm.index; }) explicitVms;
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
      ++ (lib.mapAttrsToList (name: vm: {
        assertion = vm._index >= 0 && vm._index <= 244;
        message = "VM '${name}' resolved to index ${toString vm._index}, out of range. Must be 0-244 (maps to .10-.254).";
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

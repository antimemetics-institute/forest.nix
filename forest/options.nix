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

  vmSubmodule = { config, name, allResolvedIndices, ... }: {
    options = {
      # -------------------------------------------------------------------------------------
      # forest VM options
      # -------------------------------------------------------------------------------------
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

      fqdn = mkOption {
        type = types.str;
        readOnly = true;
        description = "FQDN (<name>.forest.local) for use in dependent VM configs.";
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
        default = 4096;
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
          default = [ cfg.vmGateway cfg.vmGateway6 ];
          defaultText = literalExpression "[ config.forest.vmGateway config.forest.vmGateway6 ]";
          description = ''
            DNS servers this VM resolves through. Defaults to the host bridge IPs;
            with the default in place, forest runs a stub on the host (see
            forest.serveDns) and the VM inherits whatever the host resolves to.

            Override per-VM, or across all VMs via forest.common.dns.servers.
          '';
        };
        restrict = mkOption {
          type = types.bool;
          default = false;
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

      # -------------------------------------------------------------------------------------
      # microvm.nix-specific options
      # https://github.com/microvm-nix/microvm.nix/blob/main/nixos-modules/host/options.nix
      # -------------------------------------------------------------------------------------
      nixpkgs = mkOption {
        type = types.path;
        default = if config.pkgs != null then config.pkgs.path else pkgs.path;
        defaultText = literalExpression "pkgs.path";
        description = ''
          The nixpkgs path to use for the MicroVM. Defaults to the
          host's nixpkgs.
        '';
      };

      pkgs = mkOption {
        type = types.nullOr types.unspecified;
        default = pkgs;
        defaultText = literalExpression "pkgs";
        description = ''
          The package set to use for the MicroVM. Must be a
          nixpkgs package set with the microvm overlay. Determines
          the system of the MicroVM.

          If set to null, a new package set will be instantiated.
        '';
      };

      specialArgs = mkOption {
        type = types.attrsOf types.unspecified;
        default = {};
        description = ''
          A set of special arguments to be passed to NixOS modules.
          This will be merged into the `specialArgs` used to evaluate
          the NixOS configurations.
        '';
      };

      extraModules = mkOption {
        type = types.listOf types.deferredModule;
        default = [];
        description = ''
          A list of additional NixOS modules to be merged into
          the MicroVM's system configuration.
        '';
        defaultText = literalExpression ''
          [
            flakeInputs.some-project.nixosModules.example
            flakeInputs.another-project.nixosModules.default
          ]
        '';
      };

      autostart = mkOption {
        description = "Add this MicroVM to config.microvm.autostart?";
        type = types.bool;
        default = true;
      };

      restartIfChanged = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Restart this MicroVM's services if the systemd units are changed,
          i.e. if it has been updated by rebuilding the host.

          Defaults to true for fully-declarative MicroVMs.
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
        # TODO use the subnet option instead of hardcoding
        ipv4 = "192.168.69.${toString (10 + idx)}";
        ipv6 = "fd69::${toString (10 + idx)}";
        fqdn = "${name}.forest.local";
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
      type = forestUtils.shorthandDeferredModule;
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

    serveDns = mkOption {
      type = types.bool;
      default = lib.any
        (vm: lib.any (s: s == cfg.vmGateway || s == cfg.vmGateway6) vm.dns.servers)
        (lib.attrValues (lib.filterAttrs (_: vm: vm.enable) cfg.vms));
      defaultText = literalExpression
        "true iff any enabled VM has a bridge IP in its dns.servers (the per-VM default)";
      description = ''
        Whether forest runs a DNS stub on the host bridge so VMs can resolve
        through the host's systemd-resolved. When true, forest enables
        services.resolved and adds DNSStubListenerExtra for both bridge IPs.

        Auto-detects: defaults true if any enabled VM points its dns.servers at
        a bridge IP (which is the per-VM default). Set false if you have your
        own resolver bound to the bridge IPs, or if no VM uses the host stub.
      '';
    };
  };
}

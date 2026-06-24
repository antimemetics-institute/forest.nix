{ microvmSrc, sopsNixSrc }:
{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.forest;
in
{
  imports = [
    ./options.nix
    ./networking/host.nix
    ./vsock-ssh/host.nix
    ./secrets/host.nix
    (import ./hotswitch/host.nix { inherit microvmSrc; })
    "${microvmSrc}/nixos-modules/host"
  ];

  config = mkIf cfg.enable (
    let
      enabledVms = lib.filterAttrs (_: vm: vm.enable) cfg.vms;
      vmNames = lib.attrNames enabledVms;
      anyPciPassthrough = lib.any (vm: vm.pciPassthrough != []) (lib.attrValues enabledVms);
      forestCli = pkgs.callPackage ./cli { inherit vmNames; };
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
      ]) ++ [ forestCli ];

      users.groups.microvm = {};

      fileSystems."/var/lib/microvms" = {
        device = "/var/lib/microvms";
        fsType = "none";
        options = [ "bind" "nosuid" "nodev" "noexec" ];
      };

      microvm = {
        vms = lib.mapAttrs (name: vm: {
          inherit (vm)
            nixpkgs
            pkgs
            specialArgs
            extraModules
            autostart
            ;

          config = {
            imports = [
              "${microvmSrc}/nixos-modules/microvm"
              vm.config
              (import ./networking/vm.nix { inherit name vm cfg lib enabledVms; })
            ] ++ lib.optional vm.writableStore ./store-overlay/vm.nix
            ++ lib.optional vm.vsockSsh (import ./vsock-ssh/vm.nix)
            ++ lib.optional vm.sops.enable (import ./secrets/vm.nix {
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
                ${lib.getExe' pkgs.iproute2 "ip"} link set dev ${vm.tapInterface} master ${cfg.bridgeInterface}
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
                # sshd generates the key here on first boot if missing. For sops
                # VMs this share also holds the post-quantum age key the host
                # provisions (forest/secrets/host.nix); `forest pubkey <vm>`
                # prints its recipient for .sops.yaml.
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
          "d /var/lib/microvms/${name}/logs 0755 microvm microvm -"
          # o+x (no read) so the guest's sshd AuthorizedKeysCommandUser can
          # traverse to the planted forest-mgmt.pub (vsock-ssh/vm.nix); the
          # private host key inside stays 0600.
          "d /var/lib/microvms/${name}/host-keys 0711 microvm microvm -"
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

# Host-side sops age-key provisioning. Imported once by forest/default.nix.
#
# For every sops-enabled VM, generate a post-quantum age keypair (hybrid
# ML-KEM-768 + X25519, `age-keygen -pq`) on the host, inside the VM's persistent
# host-keys share. The private half is the VM's sops age identity
# (forest/secrets/vm.nix points sops.age.keyFile at it, alongside the SSH host
# key as a second identity); the public recipient (`age1pq1…`) is written beside
# it for the operator to drop into .sops.yaml — surfaced by `forest pubkey <vm>`.
#
# Generated on the host (unlike the SSH host key, which sshd mints inside the
# guest) for two reasons: the recipient is then readable without booting the VM,
# and the identity is in place before sops-install-secrets runs at the VM's
# first boot. Files are owned by the microvm user — the uid virtiofsd serves the
# share as — so the guest (as root) can read the 0600 key and the 0644 .pub
# stays world-readable.
{ config, lib, pkgs, ... }:

let
  cfg = config.forest;

  enabledVms = lib.filterAttrs (_: vm: vm.enable) cfg.vms;
  sopsVms    = lib.filterAttrs (_: vm: vm.sops.enable) enabledVms;
  anySops    = sopsVms != {};

  hostKeysDir = name: "/var/lib/microvms/${name}/host-keys";
in
{
  config = lib.mkIf (cfg.enable && anySops) {
    # The age identity must exist before sops-install-secrets runs inside the
    # VM, so order VM startup after key generation. microvm.nix runs VMs from a
    # systemd template (`microvm@.service`); we merge the dependency into the
    # template — not a `microvm@<name>` instance, which would shadow it and drop
    # its ExecStart. This nudges every VM (sops or not) to wait on the gen-once
    # oneshot, which is cheap and only present at all when some VM uses sops.
    systemd.services."microvm@" = {
      after = [ "forest-sops-age-setup.service" ];
      wants = [ "forest-sops-age-setup.service" ];
    };

    systemd.services.forest-sops-age-setup = {
      description = "Generate post-quantum age keys for sops-enabled forest VMs";
      wantedBy = [ "multi-user.target" ];
      # tmpfiles creates the host-keys dirs we write into.
      after = [ "systemd-tmpfiles-setup.service" ];
      path = [ pkgs.age pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Run as the microvm user so the keys are owned by the uid virtiofsd
        # serves the share as; the guest (root) can then read the 0600 key.
        User = "microvm";
        Group = "microvm";
        UMask = "0077";
        SyslogIdentifier = "forest-sops-age-setup";
      };
      script = ''
        gen() {
          dir="$1"
          key="$dir/age-pq.key"
          pub="$dir/age-pq.pub"
          # Generate once and keep stable so the VM's sops identity (and thus
          # which recipients can decrypt its secrets) survives rebuilds.
          # age-keygen writes the identity file 0600 itself.
          if [ ! -f "$key" ]; then
            age-keygen -pq -o "$key" 2>/dev/null
          fi
          # Re-derive the recipient each activation: keeps age-pq.pub in sync
          # and self-heals if it's ever removed. World-readable for `forest
          # pubkey` / the operator.
          ( umask 022; age-keygen -y "$key" > "$pub" )
        }
        ${lib.concatMapStringsSep "\n"
          (name: "gen '${hostKeysDir name}'")
          (lib.attrNames sopsVms)}
      '';
    };
  };
}

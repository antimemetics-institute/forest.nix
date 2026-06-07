{ pkgs }:

# Syntax-check forest's rendered nftables ruleset by forcing the realization
# of nixpkgs' nftables service derivation. That derivation has a `checkPhase`
# (services.nftables `checkRuleset`, on by default) which pipes the ruleset
# through `nft --check -f -` under lkl-hijack. If forest emits a rule that
# nft can't parse — wrong family qualifier, malformed set literal, typo in
# a meta key — this build fails.
#
# The fixture is deliberately wide: VMs that exercise dependsOn,
# internetAccess on/off, DNS restrict with mixed-family servers, and a
# forwardPort. If `nft --check` is happy with this config, every rule
# generator we ship is producing parseable output.

let
  lib = pkgs.lib;
  stateVersion = "24.11";

  forestModule = import ../default.nix {};

  # pkgs.nixos forces the full NixOS module set, which declares assertions
  # like "you must define a root filesystem". Stub them so the failure
  # signal we care about (nft --check) isn't drowned in unrelated noise.
  baseHost = {
    boot.loader.grub.devices = [ "nodev" ];
    fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
    system.stateVersion = stateVersion;
  };

  fixture = {
    forest.enable = true;
    forest.vms = {
      # Internet-enabled VM with a dependsOn fan-out. Exercises
      # generateAllVmConnectionRules across protocols and IP versions.
      web = {
        internetAccess = true;
        dependsOn = [
          { target = "db"; port = 5432; protocol = "tcp"; ipVersion = "both"; }
          { target = "cache"; port = 6379; protocol = "tcp"; }
        ];
        forwardPorts = [
          { port = 80; protocol = "tcp"; bindAddress = [ "0.0.0.0" "::" ]; }
        ];
        config = { system.stateVersion = stateVersion; };
      };
      # No internet, no dependsOn → falls through to the chain-end catch-all.
      db = {
        internetAccess = false;
        config = { system.stateVersion = stateVersion; };
      };
      cache = {
        internetAccess = false;
        config = { system.stateVersion = stateVersion; };
      };
      # DNS restrict with mixed v4/v6 servers — generateDnsRestrictRules
      # has to emit the right family qualifier for each.
      isolated = {
        internetAccess = false;
        dns = {
          servers = [ "1.1.1.1" "2606:4700:4700::1111" ];
          restrict = true;
        };
        config = { system.stateVersion = stateVersion; };
      };
    };
  };

  cfg = (pkgs.nixos ({ ... }: {
    imports = [ forestModule baseHost fixture ];
  })).config;

in
  # ExecStart resolves to a list of store paths; one of them is the
  # `rulesScript` derivation whose checkPhase runs `nft --check`. Pulling
  # the list into a build input forces nix to realize each path, which
  # triggers the check. If it fails, this derivation fails to build and
  # the failure surfaces with nft's error message.
  pkgs.runCommandLocal "forest-firewall-syntax" {
    nftablesExecStart = cfg.systemd.services.nftables.serviceConfig.ExecStart;
  } ''
    printf 'forest nftables ruleset accepted by nft --check\n%s\n' "$nftablesExecStart"
    touch $out
  ''

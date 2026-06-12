{ lib, pkgs, ... }:

# Host-level eval test: the bridge and tap enslavement must be declared as
# systemd-networkd state, not scripted-networking oneshots. The scripted
# backend's <bridge>-netdev.service deletes and recreates the bridge on every
# start, silently detaching the taps of running VMs (which nothing would then
# re-enslave). networkd reconciles continuously, so this pins:
#   - the bridge netdev + its addresses come from systemd.network
#   - every enabled VM's tap is matched into the bridge
#   - the scripted backend has no bridge config to fight over

let
  stateVersion = "24.11";

  forestModule = import ../../default.nix {};

  baseHost = {
    boot.loader.grub.devices = [ "nodev" ];
    fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
    system.stateVersion = stateVersion;
  };

  fixture = {
    forest.enable = true;
    forest.vms = {
      web = { config = { system.stateVersion = stateVersion; }; };
      db = { config = { system.stateVersion = stateVersion; }; };
      # Disabled VMs must not appear in the tap match list.
      ghost = {
        enable = false;
        config = { system.stateVersion = stateVersion; };
      };
    };
  };

  cfg = (pkgs.nixos ({ ... }: {
    imports = [ forestModule baseHost fixture ];
  })).config;

  bridge = cfg.forest.bridgeInterface;

  check = name: expected: actual: {
    inherit name expected actual;
    passed = expected == actual;
  };
in {
  tests = {
    networkdEnabled = check "networkdEnabled"
      true
      cfg.systemd.network.enable;

    bridgeNetdevDeclared = check "bridgeNetdevDeclared"
      { Kind = "bridge"; Name = bridge; }
      cfg.systemd.network.netdevs."10-forest-bridge".netdevConfig;

    bridgeAddresses = check "bridgeAddresses"
      [ "${cfg.forest.vmGateway}/24" "${cfg.forest.vmGateway6}/64" ]
      cfg.systemd.network.networks."10-forest-bridge".address;

    # ConfigureWithoutCarrier: with all VMs stopped the bridge has no ports
    # and no carrier, but the gateway addresses must still be configured.
    bridgeConfiguredWithoutCarrier = check "bridgeConfiguredWithoutCarrier"
      true
      cfg.systemd.network.networks."10-forest-bridge".networkConfig.ConfigureWithoutCarrier;

    tapsEnslavedToBridge = check "tapsEnslavedToBridge"
      bridge
      cfg.systemd.network.networks."11-forest-taps".networkConfig.Bridge;

    # Exactly the enabled VMs' taps, no disabled ones.
    tapMatchCoversEnabledVms = check "tapMatchCoversEnabledVms"
      (lib.sort lib.lessThan [
        cfg.forest.vms.web.tapInterface
        cfg.forest.vms.db.tapInterface
      ])
      (lib.sort lib.lessThan
        (lib.splitString " " cfg.systemd.network.networks."11-forest-taps".matchConfig.Name));

    # The scripted backend must own nothing about the bridge: its netdev
    # service is the delete-and-recreate actor this migration removes.
    noScriptedBridge = check "noScriptedBridge"
      false
      (cfg.networking.bridges ? ${bridge});

    noScriptedBridgeAddresses = check "noScriptedBridgeAddresses"
      false
      (cfg.networking.interfaces ? ${bridge});
  };
}

{ lib, pkgs, ... }:

# updatePolicy must wire the restart machinery correctly:
#   - "switch":  microvm@ does NOT auto-restart (restartIfChanged false); a
#                forest-update-<name> unit exists, triggered on the runner.
#   - "restart": microvm@ auto-restarts, restartTrigger = the whole runner (so a
#                hardware-only change that doesn't touch toplevel still restarts),
#                no switch unit.
#   - "manual":  microvm@ does NOT auto-restart, no switch unit.
# vsock-ssh is a separate, default-on capability (forest ssh + the switch ride
# it): switch VMs require it, manual/restart VMs get it unless toggled off. The
# switch consumes the shared forest-ssh-setup + ssh client config, and a switch
# VM with vsockSsh = false trips a forest assertion.

let
  forestModule = import ../../default.nix {};

  baseHost = {
    boot.loader.grub.devices = [ "nodev" ];
    fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
    system.stateVersion = "25.11";
  };

  evalForest = vms: (pkgs.nixos ({ ... }: {
    imports = [ forestModule baseHost ({ forest = { enable = true; inherit vms; }; }) ];
  })).config;

  cfg = evalForest {
    # switch: rides vsock-ssh (default on)
    web   = { updatePolicy = "switch";  config = { system.stateVersion = "25.11"; }; };
    # restart with vsock-ssh explicitly OFF: exercises the per-VM toggle
    db    = { updatePolicy = "restart"; vsockSsh = false; config = { system.stateVersion = "25.11"; }; };
    # manual but vsock-ssh still on (default): forest ssh works regardless of policy
    cache = { updatePolicy = "manual";  config = { system.stateVersion = "25.11"; }; };
  };

  svc = cfg.systemd.services;
  dbTrigger = toString (builtins.head svc."microvm@db".restartTriggers);
  guestWeb   = cfg.microvm.vms.web.config.config;
  guestDb    = cfg.microvm.vms.db.config.config;
  guestCache = cfg.microvm.vms.cache.config.config;

  checks = {
    switchHasUnit    = svc ? "forest-update-web";
    restartHasNoUnit = ! (svc ? "forest-update-db");
    manualHasNoUnit  = ! (svc ? "forest-update-cache");

    # only "restart" keeps microvm's native restart-on-change
    switchNoAutoRestart  = cfg.microvm.vms.web.restartIfChanged == false;
    restartAutoRestarts  = cfg.microvm.vms.db.restartIfChanged == true;
    manualNoAutoRestart  = cfg.microvm.vms.cache.restartIfChanged == false;

    restartTriggerIsRunner = lib.hasInfix "microvm-cloud-hypervisor" dbTrigger;

    # vsock-ssh capability: default-on, independent of updatePolicy, toggleable
    switchGuestVsockSsh  = guestWeb.microvm.vsock.ssh.enable == true;
    manualGuestVsockSsh  = guestCache.microvm.vsock.ssh.enable == true;
    toggledOffNoVsockSsh = guestDb.microvm.vsock.ssh.enable == false;

    # guests with vsock-ssh authorize the host management key for root
    guestAuthorizesMgmtKey =
      (guestWeb.environment.etc ? "forest/mgmt-keys")
      && guestWeb.services.openssh.authorizedKeysCommandUser == "nobody";
    toggledOffNoMgmtKey = ! (guestDb.environment.etc ? "forest/mgmt-keys");

    # shared host plumbing: keypair-setup unit + ssh client config pointing at it
    sshSetupPresent = svc ? "forest-ssh-setup";
    sshClientConfigPointsAtKey =
      lib.hasInfix "vsock-mux/" cfg.programs.ssh.extraConfig
      && lib.hasInfix "/var/lib/forest/ssh/id_ed25519" cfg.programs.ssh.extraConfig;

    # the switch consumes the channel via microvm -s, ordered after the setup
    hotswitchDialsVsock =
      lib.hasInfix "forest-vsock-switch-web" svc."forest-update-web".script;
    hotswitchAfterSetup =
      lib.elem "forest-ssh-setup.service" svc."forest-update-web".after;

    noFailingAssertions = lib.filter (a: !a.assertion) cfg.assertions == [];

    # switch + vsockSsh = false must trip the forest assertion
    switchWithoutVsockSshAsserts =
      let bad = evalForest {
        web = { updatePolicy = "switch"; vsockSsh = false; config = { system.stateVersion = "25.11"; }; };
      };
      in lib.any (a: !a.assertion) bad.assertions;
  };
in {
  tests = lib.mapAttrs (name: actual: {
    inherit name actual;
    expected = true;
    passed = actual == true;
  }) checks;
}

{ pkgs, enabledVms, config }:
let
  inherit (pkgs) lib;
in

lib.genAttrs (lib.attrNames enabledVms) (forestName:
  let
    vm = enabledVms.${forestName};

    autologinUser =
      let
        names = lib.attrNames vm.ssh.users;
      in
      if names == [] then null else lib.head names;

    runner = (config.microvm.vms.${forestName}.config.extendModules {
      modules = [{
        # User networking
        microvm.interfaces = lib.mkForce [{
          type = "user"; id = "qemu-user"; mac = vm.macAddress;
        }];
        microvm.binScripts.tap-up = lib.mkForce "";

        # Disable the writable store overlay for interactive launches
        microvm.writableStoreOverlay = lib.mkForce null;
        microvm.volumes = lib.mkForce [];

        # Remove store-overlay shares for interactive launches
        microvm.shares = lib.mkForce [
          {
            proto = "virtiofs";
            tag = "home";
            source = "/var/lib/microvms/${forestName}/home";
            mountPoint = "/home";
          }
          {
            proto = "virtiofs";
            tag = "logs";
            source = "/var/lib/microvms/${forestName}/logs";
            mountPoint = "/var/log";
          }
          {
            proto = "virtiofs";
            tag = "host-keys";
            source = "/var/lib/microvms/${forestName}/host-keys";
            mountPoint = "/var/lib/host-keys";
          }
          {
            proto = "virtiofs";
            tag = "nix-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
          }
        ];

        # Fall back to the default Nix store for interactive launches
        environment.etc."nix/nix-daemon-env" = lib.mkForce { text = ""; enable = true; };
        systemd.services.nix-daemon.serviceConfig.EnvironmentFile = lib.mkForce null;
        nix.settings.experimental-features = lib.mkForce [ "nix-command" "flakes" ];

        # Auto-login with default user
        services.getty.autologinUser = lib.mkDefault autologinUser;
      }];
    }).config.microvm.declaredRunner;

    scratchTags = [ "home" "logs" "host-keys" ];
  in

  pkgs.writeShellApplication {
    name = "forest-runner-${forestName}";
    runtimeInputs = [ pkgs.coreutils pkgs.virtiofsd ];
    text = ''
      # Persistent local state
      STATE_DIR="''${FOREST_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/forest/${forestName}}"
      mkdir -p "$STATE_DIR"/{home,logs,host-keys}
      cd "$STATE_DIR"

      PIDS=()
      cleanup() {
        for p in "''${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
        stty sane 2>/dev/null || true
      }
      trap cleanup EXIT INT TERM

      for tag in ${lib.concatStringsSep " " scratchTags}; do
        virtiofsd \
          --socket-path="$STATE_DIR/${forestName}-virtiofs-$tag.sock" \
          --shared-dir="$STATE_DIR/$tag" \
          --sandbox=none &
        PIDS+=($!)
      done

      virtiofsd \
        --socket-path="$STATE_DIR/${forestName}-virtiofs-nix-store.sock" \
        --shared-dir=/nix/store \
        --sandbox=none --readonly &
      PIDS+=($!)

      for tag in ${lib.concatStringsSep " " scratchTags} nix-store; do
        for _ in $(seq 1 50); do
          [ -S "$STATE_DIR/${forestName}-virtiofs-$tag.sock" ] && break
          sleep 0.1
        done
      done

      exec ${runner}/bin/microvm-run
    '';
  }
)

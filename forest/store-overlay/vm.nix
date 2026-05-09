# Writable nix store using nix's experimental local-overlay-store.
#
# The host's /nix/store is mounted read-only via virtiofs (forest module)
# at /nix/.ro-store. microvm's writableStoreOverlay sets up an OverlayFS
# merging that with a writable volume at /nix/.rw-store, giving us:
#
#   /nix/store (overlay) = /nix/.ro-store (lower, ro) + /nix/.rw-store/store (upper, rw)
#
# We also share the host's nix database read-only so the lower store can
# query path validity and references.
#
# We then configure nix-daemon to use the local-overlay store backend so
# nix *understands* the layering. This means:
#   - GC only touches the upper (writable) layer
#   - Lower (host) store paths are never deleted or whited-out
#   - nix-shell, nix shell, etc. all work correctly
#
# The overlay volume is wiped on each VM start (see host.nix).
#
# Requires a nix implementation that ships the `local-overlay-store` experimental
# feature. CppNix and Determinate Nix have it; Lix does not (the daemon would
# refuse to open `local-overlay://...`). The assertion below denies known-bad
# implementations by pname; expand the deny list if other forks turn up.
{ pkgs, lib, config, ... }:
let
  # Path where microvm mounts the host nix store (set by forest module)
  roStore = "/nix/.ro-store";
  # Path where the host's nix var (containing db) is mounted read-only
  roVar = "/nix/.ro-var";
  # Path for the writable overlay volume
  rwStore = "/nix/.rw-store";
  # Remount script needed after GC deletes upper paths that shadow lower paths
  remountScript = pkgs.writeShellScript "remount-nix-store" ''
    ${lib.getExe' pkgs.util-linux "mount"} -o remount /nix/store
  '';
  # Lower store URI: a local store with physical paths pointing at the
  # read-only virtiofs mounts. URL-encoded because it's nested inside
  # the outer store URL (only encode the URI delimiters, not path slashes).
  # state points to /nix/.ro-var/nix because the host's /nix/var is mounted
  # at /nix/.ro-var, and nix's state lives under /nix/var/nix/ (so db is at
  # /nix/.ro-var/nix/db/db.sqlite).
  # Decoded: local://?real=/nix/.ro-store&state=/nix/.ro-var/nix&read-only=true
  lowerStoreUri = "local%3A//%3Freal%3D${roStore}%26state%3D${roVar}/nix%26read-only%3Dtrue";
in
{
  assertions = [
    {
      assertion = (config.nix.package.pname or "nix") != "lix";
      message = ''
        forest's writable store overlay requires the `local-overlay-store`
        experimental feature, which Lix does not implement. The nix daemon
        will refuse to open `local-overlay://...` and fail to start.
        For clarity, the host can still run Lix, just the VM needs to 
        support the `local-overlay-store` experimental feature.

        Either:
          - set forest.vms.<this VM>.writableStore = false, or
          - use a nix implementation that supports the feature (default
            pkgs.nix, any pkgs.nixVersions.*, or Determinate Nix).
      '';
    }
  ];

  microvm.writableStoreOverlay = rwStore;

  microvm.volumes = [{
    image = "nix-store-overlay.img";
    mountPoint = rwStore;
    size = 512000; # 500 GB sparse
  }];

  # Share host's nix var directory (contains db.sqlite) for the lower store
  microvm.shares = [{
    proto = "virtiofs";
    tag = "nix-var";
    source = "/nix/var";
    mountPoint = roVar;
  }];

  # Configure nix-daemon to use the local-overlay store backend.
  #
  # The store URL is passed via NIX_REMOTE to the daemon only — putting it in
  # nix.conf would make clients try to open the overlay store directly, failing
  # with permission errors. Clients use the default "daemon" store (unix socket).
  #
  # check-mount=false because microvm's initrd mounts the overlay with
  # /sysroot-prefixed paths, which confuses nix's mount verification.
  nix.settings.experimental-features = [ "nix-command" "flakes" "local-overlay-store" "read-only-local-store" ];
  environment.etc."nix/nix-daemon-env".text =
    "NIX_REMOTE=local-overlay://?upper-layer=${rwStore}/store&lower-store=${lowerStoreUri}&check-mount=false&remount-hook=${remountScript}\n";
  systemd.services.nix-daemon.serviceConfig.EnvironmentFile = "/etc/nix/nix-daemon-env";

  # Let nix-shell -p and <nixpkgs> work
  nix.nixPath = [ "nixpkgs=${pkgs.path}" ];
}

# Host-side configuration for the writable nix store overlay.
# Wipes the overlay volume before VM startup.
{
  systemd.services."microvm@dev".preStart = ''
    OVERLAY_IMG="/var/lib/microvms/dev/nix-store-overlay.img"
    if [ -f "$OVERLAY_IMG" ]; then
      echo "Wiping stale nix store overlay..."
      rm -f "$OVERLAY_IMG"
    fi
  '';
}

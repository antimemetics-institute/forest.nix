# Host-side configuration for a VM's writable nix-store overlay.
# Wipes the overlay image before the VM starts so boots stay clean.
# Imported per-VM by the forest module when writableStore = true.
{ name, lib }:
{
  "microvm@${name}".preStart = lib.mkBefore ''
    OVERLAY_IMG="/var/lib/microvms/${name}/nix-store-overlay.img"
    if [ -f "$OVERLAY_IMG" ]; then
      echo "Wiping stale nix store overlay..."
      rm -f "$OVERLAY_IMG"
    fi
  '';
}

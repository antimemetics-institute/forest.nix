# Non-flake entry point. Pins microvm and sops-nix via tack.
# Returns a NixOS module:
#
#   imports = [ (import (fetchTarball "https://github.com/.../forest.nix/archive/<rev>.tar.gz") {}) ];
#
# To override the pinned sources (e.g. to share a microvm pin you already have):
#
#   import (fetchTarball "...") { microvmSrc = ./vendored-microvm; }
{
  inputs ? import ./.tack,
  microvmSrc ? inputs."microvm.nix",
  sopsNixSrc ? inputs.sops-nix,
}:
import ./forest { inherit microvmSrc sopsNixSrc; }

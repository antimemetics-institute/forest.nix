# Non-flake entry point. Pins microvm and sops-nix via npins.
# Returns a NixOS module:
#
#   imports = [ (import (fetchTarball "https://github.com/.../forest.nix/archive/<rev>.tar.gz") {}) ];
#
# To override the pinned sources (e.g. to share a microvm pin you already have):
#
#   import (fetchTarball "...") { microvmSrc = ./vendored-microvm; }
{ sources    ? import ./npins
, microvmSrc ? sources."microvm.nix"
, sopsNixSrc ? sources."sops-nix"
}:
import ./forest { inherit microvmSrc sopsNixSrc; }

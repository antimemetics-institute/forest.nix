{ lib }:

# Aggregates the per-topic utility files so callers can use a single
# `import ./utils { inherit lib; }` and get every helper.
(import ./nftables.nix { inherit lib; })
// (import ./indices.nix { inherit lib; })
// (import ./types.nix { inherit lib; })

# Hashes a microvm runner's "launch surface" so two runners can be compared for
# whether they need the same VM process (same kernel/hardware) or differ only in
# userspace. Self-contained (bakes its own PATH) so it runs identically from the
# hot-switch unit and from tests/hotswitch.
{ pkgs, lib }:

pkgs.writeShellScript "forest-launch-fingerprint" ''
  set -euo pipefail
  export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused ]}

  runner="$1"
  # Normalize the two userspace-varying tokens in the cmdline so a userspace-only
  # change hashes equal (anything else differing means a real launch/hardware
  # change → restart). '#' is the sed delimiter because store paths contain '/'.
  #   - init=<toplevel>/init : this runner's own system closure. Read the path
  #     off share/microvm/system and rewrite it.
  #   - regInfo=<closure-info>/registration : the nix DB registration of the whole
  #     closure, so it changes on every userspace rebuild. A hot-switch reloads it
  #     (sshSwitch runs nix-store --load-db), so it doesn't need a reboot either.
  cat "$runner"/bin/* \
    | sed "s#$(readlink "$runner/share/microvm/system")#@TOP@#g" \
    | sed -E "s#regInfo=[^ ']*#regInfo=@REG@#g" \
    | sha256sum
''

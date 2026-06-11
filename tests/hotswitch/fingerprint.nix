{ pkgs, ... }:

# Build-time test of forest/hotswitch/launch-fingerprint.nix — the script that
# decides "same VM process or not" by hashing a runner's bin/* with the
# userspace-varying tokens normalized out. The two load-bearing properties:
#   - userspace-invariant: two runners from a pure userspace rebuild must hash
#     equal, or the VM cold-restarts on every rebuild instead of hot-switching.
#   - hardware-sensitive: a launch-arg change (here, --memory) must hash differently.
#
# A real userspace rebuild changes TWO tokens in the cmdline — `init=<toplevel>`
# and `regInfo=<closure-info>` (the nix DB registration of the whole closure).
# Both must be normalized; missing `regInfo` was a real false-positive-restart
# bug. So the userspace fixture below differs in BOTH.
#
# We build synthetic runners with the same shape the real ones have (a
# bin/microvm-run cmdline + a share/microvm/system symlink) and run the real
# script against them — no microvm eval needed.

let
  lib = pkgs.lib;
  launchFingerprint = import ../../forest/hotswitch/launch-fingerprint.nix { inherit pkgs lib; };
in
pkgs.runCommandLocal "forest-launch-fingerprint-test" { } ''
  set -euo pipefail

  # mk <dir> <toplevel> <closure-info> <memory>
  mk() {
    mkdir -p "$1/bin" "$1/share/microvm"
    ln -s "$2" "$1/share/microvm/system"
    printf 'cloud-hypervisor --memory %s --kernel /nix/store/kkk-kernel --cmdline %s\n' \
      "$4" "'init=$2/init regInfo=$3/registration console=ttyS0'" > "$1/bin/microvm-run"
    printf 'ip link set tap0 master br0\n' > "$1/bin/tap-up"
  }

  TOP_A=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-toplevel
  TOP_B=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-toplevel
  REG_A=/nix/store/1111111111111111111111111111111-closure-info
  REG_B=/nix/store/2222222222222222222222222222222-closure-info

  # userspace rebuild: both toplevel and closure-info change; hardware identical.
  mk base   "$TOP_A" "$REG_A" 4096
  mk uspace "$TOP_B" "$REG_B" 4096
  # hardware change: only --memory differs.
  mk hw     "$TOP_A" "$REG_A" 8192

  fpBase=$(${launchFingerprint} base)
  fpUspace=$(${launchFingerprint} uspace)
  fpHw=$(${launchFingerprint} hw)

  printf 'base=%s\nuspace=%s\nhw=%s\n' "$fpBase" "$fpUspace" "$fpHw"

  if [ "$fpBase" != "$fpUspace" ]; then
    echo "FAIL: a userspace-only change (toplevel + regInfo) altered the fingerprint" >&2
    exit 1
  fi
  if [ "$fpBase" = "$fpHw" ]; then
    echo "FAIL: a hardware change (--memory) did not alter the fingerprint" >&2
    exit 1
  fi

  echo "ok: launch fingerprint is userspace-invariant and hardware-sensitive"
  touch $out
''

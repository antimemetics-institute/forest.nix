{ pkgs }:

let
  lib = pkgs.lib;

  cli = import ../forest/cli {
    inherit lib pkgs;
    vmNames = [ "web" "db" ];
  };

  mkStub = name: pkgs.writeShellScriptBin name ''
    {
      printf '%s' ${lib.escapeShellArg name}
      for arg in "$@"; do
        printf ' %s' "$arg"
      done
      printf '\n'
    } >> "$CAPTURE"
  '';

  fakeSudo = mkStub "sudo";
  fakeSystemctl = mkStub "systemctl";
  fakeJournalctl = mkStub "journalctl";

in pkgs.runCommandLocal "forest-cli-tests" {
  nativeBuildInputs = [
    cli.forest
    fakeSudo
    fakeSystemctl
    fakeJournalctl
    pkgs.diffutils
  ];
} ''
  set -euo pipefail
  export CAPTURE="$PWD/capture"

  fail() { echo "FAIL: $1" >&2; exit 1; }
  pass() { echo "PASS: $1"; }

  expect() {
    local label="$1" expected="$2"
    if ! diff -u <(printf '%s\n' "$expected") "$CAPTURE" >/dev/null; then
      echo "--- expected ---" >&2; printf '%s\n' "$expected" >&2
      echo "--- actual ---"   >&2; cat "$CAPTURE"            >&2
      fail "$label"
    fi
    pass "$label"
  }

  run() {
    : > "$CAPTURE"
    forest "$@"
  }

  expect_rc() {
    local want="$1"; shift
    local label="$1"; shift
    : > "$CAPTURE"
    local rc=0
    forest "$@" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$want" ] || fail "$label: expected rc=$want, got $rc"
    pass "$label"
  }

  # ---- command dispatch ----
  run list;        expect "list"        "systemctl list-units microvm@* --all --no-pager"
  run ls;          expect "ls alias"    "systemctl list-units microvm@* --all --no-pager"
  run status web;  expect "status"      "systemctl status microvm@web"
  run up web;      expect "up"          "sudo systemctl start microvm@web"
  run start db;    expect "start alias" "sudo systemctl start microvm@db"
  run down web;    expect "down"        "sudo systemctl stop microvm@web"
  run stop db;     expect "stop alias"  "sudo systemctl stop microvm@db"
  run restart web; expect "restart"     "sudo systemctl restart microvm@web"
  run logs web;    expect "logs"        "journalctl -u microvm@web"
  run journal web; expect "journal"     "sudo journalctl -i /var/lib/microvms/web/logs/journal/*/system.journal"
  run logs web -f;            expect "logs passthrough"    "journalctl -u microvm@web -f"
  run journal web -b 0;       expect "journal passthrough" "sudo journalctl -i /var/lib/microvms/web/logs/journal/*/system.journal -b 0"

  # ---- error paths ----
  expect_rc 2 "missing-vm exits 2"     up
  expect_rc 2 "unknown command exits 2" bogus
  expect_rc 0 "help exits 0"            help
  expect_rc 0 "-h exits 0"              -h
  expect_rc 0 "--help exits 0"          --help

  # ---- bash completion ----
  # The completion script uses `complete` and `compgen`, which are programmable
  # completion builtins not present in stdenv's minimal bash. Run this subtest
  # under bashInteractive.
  cat > completion-test.sh <<'TEST_EOF'
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$1"

  COMP_WORDS=(forest u "")
  COMP_CWORD=1
  COMPREPLY=()
  _forest_complete
  verbs=" ''${COMPREPLY[*]:-} "
  case "$verbs" in
    *" up "*) echo "PASS: completion verbs include 'up'" ;;
    *) echo "FAIL: completion verbs missing 'up' (got:$verbs)" >&2; exit 1 ;;
  esac

  COMP_WORDS=(forest up "")
  COMP_CWORD=2
  COMPREPLY=()
  _forest_complete
  vms=" ''${COMPREPLY[*]:-} "
  case "$vms" in *" web "*) ;; *) echo "FAIL: completion VMs missing 'web' (got:$vms)" >&2; exit 1 ;; esac
  case "$vms" in *" db "*)  ;; *) echo "FAIL: completion VMs missing 'db' (got:$vms)"  >&2; exit 1 ;; esac
  echo "PASS: completion VM names baked in"
  TEST_EOF

  ${lib.getExe' pkgs.bashInteractive "bash"} completion-test.sh ${cli.completion}

  echo "All forest CLI tests passed"
  touch "$out"
''

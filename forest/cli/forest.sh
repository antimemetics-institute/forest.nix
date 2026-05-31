#!/usr/bin/env bash
# shellcheck shell=bash
# forest CLI — manage microvm-backed forest VMs from one entry point.

cmd="${1:-help}"
vm="${2:-}"

usage() {
  cat <<'EOF'
Usage: forest <command> [vm] [args...]

Commands:
  list                       List forest VMs and their state
  status   <vm>              Show systemd status for a VM
  up       <vm>              Start a VM
  down     <vm>              Stop a VM
  restart  <vm>              Restart a VM
  logs     <vm> [args...]    Show journalctl for the systemd unit (extra args go to journalctl)
  journal  <vm> [args...]    Open the VM's own journal (extra args go to journalctl)
  help                       Show this message
EOF
}

require_vm() {
  if [ -z "$vm" ]; then
    printf "error: '%s' requires a VM name\n" "$cmd" >&2
    usage >&2
    exit 2
  fi
}

case "$cmd" in
  list|ls)
    systemctl list-units 'microvm@*' --all --no-pager
    ;;
  status)
    require_vm
    systemctl status "microvm@$vm"
    ;;
  up|start)
    require_vm
    sudo systemctl start "microvm@$vm"
    ;;
  down|stop)
    require_vm
    sudo systemctl stop "microvm@$vm"
    ;;
  restart)
    require_vm
    sudo systemctl restart "microvm@$vm"
    ;;
  logs)
    require_vm
    shift 2
    journalctl -u "microvm@$vm" "$@"
    ;;
  journal)
    require_vm
    shift 2
    sudo journalctl -i "/var/lib/microvms/$vm/logs/journal/"*"/system.journal" "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    printf "error: unknown command '%s'\n" "$cmd" >&2
    usage >&2
    exit 2
    ;;
esac

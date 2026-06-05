#!/bin/sh
# shellcheck shell=sh
# forest CLI — manage microvm-backed forest VMs from one entry point.

cmd="${1:-help}"
vm="${2:-}"
vmNames="@VM_NAMES@"
if [ -z "$vmNames" ]; then
  vmArg="N/A"
else
  vmArg="One of: $vmNames"
fi

usage() {
  echo "Usage: forest <command> [vm] [args...]"
  echo ""
  echo "Commands:"
  echo "  list                       List forest VMs and their state"
  echo "  status   <vm>              Show systemd status for a VM"
  echo "  up       <vm>              Start a VM"
  echo "  down     <vm>              Stop a VM"
  echo "  restart  <vm>              Restart a VM"
  echo "  logs     <vm> [args...]    Show journalctl for the systemd unit"
  echo "  journal  <vm> [args...]    Open the VM's own journal"
  echo "  help                       Show this message"
  echo ""
  echo "Arguments:"
  echo "  <vm>         $vmArg"
  echo "  [args...]    Extra args to journalctl"
}

require_vm() {
  if [ -z "$vm" ]; then
    printf "error: '%s' requires a VM name\n" "$cmd" >&2
    usage >&2
    exit 2
  fi
  if [ -z "$vmNames" ]; then
    printf "error: '%s' requires at least one VM to be enabled.\n" "$cmd" >&2
    usage >&2
    exit 2
  elif echo "$vmNames" | grep -v -w -q "$vm"; then
    printf "error: '%s' is not a valid VM name. Valid options are: $vmNames\n" "$vm" >&2
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

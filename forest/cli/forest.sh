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
  echo "  ssh      <vm> [args...]    Open an SSH shell in the VM over vsock"
  echo "  logs     <vm> [args...]    Show journalctl for the systemd unit"
  echo "  journal  <vm> [args...]    Open the VM's own journal"
  echo "  pubkey   <vm>              Print the VM's post-quantum age public key (for .sops.yaml)"
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
  ssh)
    require_vm
    shift 2
    # microvm -s selects the vsock target and authenticates with the forest
    # management key (root-only) via the system ssh client config; run as root.
    sudo microvm -s "$vm" "$@"
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
  pubkey)
    require_vm
    # The post-quantum age recipient the host provisions for this VM's sops
    # identity (forest/secrets/host.nix). Lives in the host-keys share, under
    # /var/lib/microvms (0700 microvm), so reading it needs privilege.
    if ! sudo cat "/var/lib/microvms/$vm/host-keys/age-pq.pub" 2>/dev/null; then
      printf "error: no age public key for '%s' yet.\n" "$vm" >&2
      printf "It's provisioned for sops-enabled VMs on host activation. Set 'sops.enable = true' and rebuild the host.\n" >&2
      exit 1
    fi
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

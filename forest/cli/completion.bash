# shellcheck shell=bash
# bash completion for the forest CLI.

__forest_complete() {
  local cmds="list ls status up start down stop restart logs journal help"
  local vm_cmds="status up start down stop restart logs journal"
  local journalctl_cmds="logs journal"
  local vms="@VM_NAMES@"
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()
  if [ "$COMP_CWORD" = 1 ]; then
    mapfile -t COMPREPLY < <(compgen -W "$cmds" -- "$cur")
  elif [ "$COMP_CWORD" = 2 ] && echo "$vm_cmds" | grep -w -q "${COMP_WORDS[1]}"; then
    mapfile -t COMPREPLY < <(compgen -W "$vms" -- "$cur")
  elif [ "$COMP_CWORD" -ge 3 ] && echo "$journalctl_cmds" | grep -w -q "${COMP_WORDS[1]}"; then
    # Get completions from journalctl
    if ! complete -p journalctl &>/dev/null; then
      # shellcheck source=/dev/null
      source "@JOURNALCTL_COMPLETIONS@" 2>/dev/null
    fi
    local journalctl_func
    journalctl_func="$(complete -p journalctl 2>/dev/null | sed 's/.*-F \([^ ]*\) .*/\1/')"
    if [ -n "$journalctl_func" ]; then
      COMP_WORDS=("journalctl" "${COMP_WORDS[@]:3}")
      COMP_CWORD=$(( COMP_CWORD - 2 ))
      $journalctl_func
    fi
  fi
}

complete -F __forest_complete forest

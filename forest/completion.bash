# shellcheck shell=bash
# bash completion for the forest CLI.

_forest_complete() {
  local cmds="list ls status up start down stop restart logs journal help"
  local vms="@VM_NAMES@"
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=()
  if [ "$COMP_CWORD" = 1 ]; then
    mapfile -t COMPREPLY < <(compgen -W "$cmds" -- "$cur")
  elif [ "$COMP_CWORD" = 2 ]; then
    mapfile -t COMPREPLY < <(compgen -W "$vms" -- "$cur")
  fi
}
complete -F _forest_complete forest

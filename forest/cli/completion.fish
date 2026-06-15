# fish completion for the forest CLI.

function __forest_command
  set -l tokens (commandline -opc)
  test (count $tokens) -eq 1
end

function __forest_using_command
  set -l cmd $argv[1]
  set -l tokens (commandline -opc)
  test (count $tokens) -ge 2 && test $tokens[2] = $cmd
end

function __forest_vm
  set -l tokens (commandline -opc)
  test (count $tokens) -eq 2 && not __forest_command
end

function __forest_journalctl
  set -l tokens (commandline -opc)
  test (count $tokens) -ge 3 && contains -- $tokens[2] logs journal
end

function __forest_journalctl_completions
  set -l tokens (commandline -opc)
  set -l current (commandline -ct)
  complete -C "journalctl $tokens[3..-1] $current" | string match -- '-*'
end

complete -c forest -f

complete -c forest -n __forest_command -a "list ls" -d "List forest VMs and their state"
complete -c forest -n __forest_command -a status -d "Show systemd status for a VM"
complete -c forest -n __forest_command -a "up start" -d "Start a VM"
complete -c forest -n __forest_command -a "down stop" -d "Stop a VM"
complete -c forest -n __forest_command -a restart -d "Restart a VM"
complete -c forest -n __forest_command -a ssh -d "Open an SSH shell in the VM over vsock"
complete -c forest -n __forest_command -a logs -d "Show journalctl for the systemd unit"
complete -c forest -n __forest_command -a journal -d "Open the VM's own journal"
complete -c forest -n __forest_command -a help -d "Show help"

for _cmd in status up start down stop restart ssh logs journal
  complete -c forest -n "__forest_using_command $_cmd && __forest_vm" -a '@VM_NAMES@' -d 'forest VM'
end

complete -c forest -n __forest_journalctl -xa '(__forest_journalctl_completions)'

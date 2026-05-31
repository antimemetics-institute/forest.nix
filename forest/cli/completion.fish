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

function __forest_journal
 set -l tokens (commandline -opc)
 test (count $tokens) -ge 3 && contains -- $tokens[2] logs journal
end

complete -c forest -f -n __forest_command -a "list ls" -d "List forest VMs and their state"
complete -c forest -f -n __forest_command -a status -d "Show systemd status for a VM"
complete -c forest -f -n __forest_command -a "up start" -d "Start a VM"
complete -c forest -f -n __forest_command -a "down stop" -d "Stop a VM"
complete -c forest -f -n __forest_command -a restart -d "Restart a VM"
complete -c forest -f -n __forest_command -a logs -d "Show journalctl for the systemd unit"
complete -c forest -f -n __forest_command -a journal -d "Open the VM's own journal"
complete -c forest -f -n __forest_command -a help -d "Show help"

for _cmd in status up start down stop restart logs journal
 complete -c forest -f -n "__forest_using_command $_cmd && __forest_vm" -a '@VM_NAMES@' -d 'forest VM'
end

# https://github.com/fish-shell/fish-shell/blob/master/share/completions/journalctl.fish
complete -c forest -n __forest_journal -f -s h -l help -d 'Prints a short help text and exits'
complete -c forest -n __forest_journal -f -l version -d 'Prints a short version string and exits'
complete -c forest -n __forest_journal -f -l no-pager -d 'Do not pipe output into a pager'
complete -c forest -n __forest_journal -f -s a -l all -d 'Show all fields in full'
complete -c forest -n __forest_journal -f -s f -l follow -d 'Show live tail of entries'
complete -c forest -n __forest_journal -f -s e -l pager-end -d 'Skip to the end of the journal'
complete -c forest -n __forest_journal -f -s n -l lines -d 'Controls the number of journal lines'
complete -c forest -n __forest_journal -f -l no-tail -d 'Show all lines, even in follow mode'
complete -c forest -n __forest_journal -f -s o -l output -d 'Controls the formatting' -xa '(printf %s\t\n (command journalctl --output=help))'
complete -c forest -n __forest_journal -f -s q -l quiet -d 'Suppress warning about normal user'
complete -c forest -n __forest_journal -f -s m -l merge -d 'Show entries interleaved from all journals'
complete -c forest -n __forest_journal -f -l this-boot -d 'Show data only from the current boot'
complete -c forest -n __forest_journal -f -s b -l boot -d 'Show data only from a certain boot' -xa '(command journalctl 2>/dev/null --list-boots --no-pager | while read -l a b c; echo -e "$a\\t$c"; end)'
complete -c forest -n __forest_journal -f -s u -l unit -d 'Show data only of the specified unit' -xa "(__fish_systemctl_services)"
complete -c forest -n __forest_journal -f -s p -l priority -d 'Filter by priority' -xa 'emerg 0 alert 1 crit 2 err 3 warning 4 notice 5 info 6 debug 7'
complete -c forest -n __forest_journal -f -s c -l cursor -d 'Start from the passing cursor'
complete -c forest -n __forest_journal -f -l since -d 'Entries on or newer than DATE' -xa 'yesterday today tomorrow now'
complete -c forest -n __forest_journal -f -l until -d 'Entries on or older than DATE' -xa 'yesterday today tomorrow now'
complete -c forest -n __forest_journal -f -s F -l field -d 'Print all possible data values of FIELD' -xa '(printf %s\t\n (command journalctl --fields))'
complete -c forest -n __forest_journal -f -s D -l directory -d 'Specify journal directory' -xa "(__fish_complete_directories)"
complete -c forest -n __forest_journal -f -l new-id128 -d 'Generate a new 128 bit ID'
complete -c forest -n __forest_journal -f -l header -d 'Show internal header information'
complete -c forest -n __forest_journal -f -l disk-usage -d 'Shows the current disk usage'
complete -c forest -n __forest_journal -f -l setup-keys -d 'Generate Forward Secure Sealing key pair'
complete -c forest -n __forest_journal -f -l interval -d 'Change interval for the sealing'
complete -c forest -n __forest_journal -f -l verify -d 'Check journal for internal consistency'
complete -c forest -n __forest_journal -f -l verify-key -d 'Specifies FSS key for --verify'
complete -c forest -n __forest_journal -f -s r -l reverse -d "Reverse output to show newest entries first"
complete -c forest -n __forest_journal -f -l utc -d "Express time in Coordinated Universal Time (UTC)"
complete -c forest -n __forest_journal -f -l no-hostname -d "Don't show the hostname field"
complete -c forest -n __forest_journal -f -s x -l catalog -d "Augment log lines with explanation texts from the message catalog"
complete -c forest -n __forest_journal -f -l list-boots -d "Show a list of boot numbers, their IDs and timestamps"
complete -c forest -n __forest_journal -f -s k -l dmesg -d "Show only kernel messages"
complete -c forest -n __forest_journal -f -s N -l fields -d "Print all field names used in all entries of the journal"
complete -c forest -n __forest_journal -f -l update-catalog -d "Update the message catalog index"
complete -c forest -n __forest_journal -f -l sync -d "Write all unwritten journal data and sync journals"
complete -c forest -n __forest_journal -f -l flush -d "Flush log data from /run/log/journal/ into /var/log/journal/"
complete -c forest -n __forest_journal -f -l relinquish-var -d "Write to /run/log/journal/ instead of /var/log/journal/"
complete -c forest -n __forest_journal -f -l smart-relinquish-var -d "Similar to --relinquish-var"
complete -c forest -n __forest_journal -f -l rotate -d "Mark active journal files as archived and create new empty ones"
complete -c forest -n __forest_journal -f -l output-fields -d "List of fields to be included in the output"
complete -c forest -n __forest_journal -f -s t -l identifier -d "Show messages for specified syslog identifier" -xa '(printf %s\t\n (command journalctl -F SYSLOG_IDENTIFIER))'
complete -c forest -n __forest_journal -f -l user-unit -d "Show messages for the specified user session unit" -xa '(printf %s\t\n (command journalctl -F _SYSTEMD_USER_UNIT))'
complete -c forest -n __forest_journal -f -l facility -d "Filter output by syslog facility"
complete -c forest -n __forest_journal -f -s g -l grep -d "Show entries where MESSAGE field matches regex"
complete -c forest -n __forest_journal -f -l case-sensitive -d "Toggle pattern matching case sensitivity"
complete -c forest -n __forest_journal -F -l cursor-file -d "Load cursor from file or save to file, if missing"
complete -c forest -n __forest_journal -f -l after-cursor -d "Show entries after the passed cursor"
complete -c forest -n __forest_journal -f -l show-cursor -d "Show cursor after the last entry"
complete -c forest -n __forest_journal -f -l user -d "Show messages from service of current user"
complete -c forest -n __forest_journal -f -l system -d "Show messages from system services and the kernel"
complete -c forest -n __forest_journal -f -s M -l machine -d "Show messages from a running, local container"
complete -c forest -n __forest_journal -f -l file -d "Operate only on journal files matching glob"
complete -c forest -n __forest_journal -f -l root -d "Use specified directory instead of the root directory" -xa "(__fish_complete_directories)"
complete -c forest -n __forest_journal -f -l namespace -d "Show log data of specified namespace"
complete -c forest -n __forest_journal -f -l vacuum-size -d "Reduce disk usage below specified SIZE"
complete -c forest -n __forest_journal -f -l vacuum-time -d "Remove journal files older than TIME"
complete -c forest -n __forest_journal -f -l vacuum-files -d "Leave only INT number of journal files"
complete -c forest -n __forest_journal -f -l list-catalog -d "Show message catalog entries as a table"
complete -c forest -n __forest_journal -f -l dump-catalog -d "Show message catalog entries"

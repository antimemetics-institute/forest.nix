{
  lib,
  bashInteractive,
  fishMinimal,
  runCommand,
  systemd,
  shellcheck-minimal,
  withShell ? "${bashInteractive}/bin/bash --norc",
  withVmNames ? [ ],
}:

runCommand "forest"
  {
    VM_NAMES = lib.concatStringsSep " " withVmNames;
    SHELL = withShell;
    JOURNALCTL_COMPLETIONS = "${systemd}/share/bash-completion/completions/journalctl";
  }
  ''
    mkdir -p $out/bin
    substitute ${./forest.bash} $out/bin/forest --subst-var SHELL --subst-var VM_NAMES
    chmod +x $out/bin/forest

    mkdir -p $out/share/bash-completion/completions
    substitute ${./completion.bash} $out/share/bash-completion/completions/forest --subst-var VM_NAMES --subst-var JOURNALCTL_COMPLETIONS

    mkdir -p $out/share/fish/vendor_completions.d
    substitute ${./completion.fish} $out/share/fish/vendor_completions.d/forest.fish --subst-var VM_NAMES

    # Check syntax for scripts
    ${lib.getExe shellcheck-minimal} $out/bin/forest
    ${lib.getExe shellcheck-minimal} $out/share/bash-completion/completions/forest
    ${lib.getExe fishMinimal} -n $out/share/fish/vendor_completions.d/forest.fish
  ''

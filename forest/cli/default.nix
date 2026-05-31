{ lib, pkgs, vmNames }:

pkgs.runCommand "forest"
  {
    VM_NAMES = lib.concatStringsSep " " vmNames;
  }
  ''
    mkdir -p $out/share/bash-completion/completions
    mkdir -p $out/share/fish/vendor_completions.d

    install -Dm755 ${./forest.sh} $out/bin/forest
    ${lib.getExe pkgs.shellcheck-minimal} $out/bin/forest

    substitute ${./completion.bash} $out/share/bash-completion/completions/forest --subst-var VM_NAMES
    substitute ${./completion.fish} $out/share/fish/vendor_completions.d/forest.fish --subst-var VM_NAMES
  ''

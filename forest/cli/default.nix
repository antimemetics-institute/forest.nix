{ lib, pkgs, vmNames }:

let
  forest = pkgs.runCommand "forest" {
    VM_NAMES = lib.concatStringsSep " " vmNames;
  } ''
    mkdir -p $out/share/fish/vendor_completions.d
    install -Dm755 ${./forest.sh} $out/bin/forest
    substitute ${./completion.fish} $out/share/fish/vendor_completions.d/forest.fish --subst-var VM_NAMES
  '';

  completion = pkgs.runCommand "forest-completion.bash" {
    src = ./completion.bash;
    vmNames = lib.concatStringsSep " " vmNames;
  } ''
    substitute "$src" "$out" --replace-fail '@VM_NAMES@' "$vmNames"
  '';
in {
  inherit forest completion;
}

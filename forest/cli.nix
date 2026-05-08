{ lib, pkgs, vmNames }:

let
  forest = pkgs.writeShellApplication {
    name = "forest";
    text = builtins.readFile ./forest.sh;
  };

  completion = pkgs.runCommand "forest-completion.bash" {
    src = ./completion.bash;
    vmNames = lib.concatStringsSep " " vmNames;
  } ''
    substitute "$src" "$out" --replace-fail '@VM_NAMES@' "$vmNames"
  '';
in {
  inherit forest completion;
}

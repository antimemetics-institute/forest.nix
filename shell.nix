{
  system ? builtins.currentSystem,
  inputs ? import ./.tack,
  pkgs ? inputs.nixpkgs.legacyPackages.${system},
}:

pkgs.mkShell {
  packages = [
    pkgs.gnumake
    pkgs.tack
  ];
}

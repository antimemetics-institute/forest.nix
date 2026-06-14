{
  system ? builtins.currentSystem,
  inputs ? import ./.tack,
  pkgs ? inputs.nixpkgs.legacyPackages.${system},
  tackPkgs ? inputs.tack.packages.${system},
}:

pkgs.mkShell {
  packages = [
    pkgs.gnumake
    tackPkgs.tack
  ];
}

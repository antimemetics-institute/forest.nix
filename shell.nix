{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = [
    pkgs.npins
    pkgs.gnumake
  ];
}

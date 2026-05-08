# Unit tests for forest/utils.nix
# Run: nix-instantiate --eval ./tests -A summary
#      nix-instantiate --eval ./tests -A allPassed
{ pkgs ? import <nixpkgs> {} }:

let
  lib = pkgs.lib;
  utils = import ../forest/utils.nix { inherit lib; };

  normalize = s:
    lib.concatStringsSep "\n"
      (lib.filter (l: l != "") (lib.splitString "\n" (lib.trim s)));

  runners = {
    inherit normalize;

    runStringTest = fn: name: test:
      let actual = fn test.input;
      in {
        inherit name actual;
        inherit (test) expected;
        passed = normalize actual == normalize test.expected;
      };
  };

  args = { inherit lib utils runners; };

  importTestsFrom = dir:
    let
      entries = builtins.readDir dir;
      nixFiles = lib.filter
        (name: entries.${name} == "regular" && lib.hasSuffix ".nix" name)
        (lib.attrNames entries);
    in
      lib.foldl' (acc: name: acc // (import (dir + "/${name}") args)) {} nixFiles;

  sections = importTestsFrom ./nftables-generation;

  allResults = lib.foldl' (acc: s: acc // s) {} (builtins.attrValues sections);

  formatSection = results:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: r:
      "  ${name}: ${if r.passed then "PASS" else "FAIL"}"
    ) results);

  formatFailures = results:
    lib.concatStringsSep "\n" (lib.filter (s: s != "") (lib.mapAttrsToList (name: r:
      if r.passed then "" else ''
        ${name}:
          Expected: ${builtins.toJSON r.expected}
          Actual:   ${builtins.toJSON r.actual}
      ''
    ) results));

  formatAllSections = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (sectionName: results:
    "${sectionName}:\n${formatSection results}"
  ) sections);

in rec {
  allPassed = builtins.all (r: r.passed) (builtins.attrValues allResults);

  summary = ''
    Forest Utils Test Results
    =========================

    ${formatAllSections}

    Overall: ${if allPassed then "All tests passed!" else "Some tests FAILED!"}
    ${lib.optionalString (!allPassed) "\n    Failures:\n${formatFailures allResults}"}
  '';

  inherit allResults;
}

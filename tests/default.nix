# Forest tests entry point.
#
# Eval-time unit tests for forest/utils:
#   nix-instantiate --eval ./tests -A summary
#   nix-instantiate --eval ./tests -A allPassed
#
# Build-time checks (consumed by flake.nix):
#   .checks.tests  — derivation that fails iff any unit test fails
#   .checks.cli    — derivation that exercises forest/cli/forest.sh against stubs
#
# Adding a new test section: drop a directory of .nix files next to this one.
# Each .nix file receives `{ lib, utils, runners }` and returns an attrset of
# named test results. Sections are auto-discovered.
{ pkgs ? import <nixpkgs> {} }:

let
  lib = pkgs.lib;
  utils = import ../forest/utils { inherit lib; };

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

  args = { inherit lib pkgs utils runners; };

  importTestsFrom = dir:
    let
      entries = builtins.readDir dir;
      nixFiles = lib.filter
        (name: entries.${name} == "regular" && lib.hasSuffix ".nix" name)
        (lib.attrNames entries);
    in
      lib.foldl' (acc: name: acc // (import (dir + "/${name}") args)) {} nixFiles;

  # Auto-discover test directories next to this file. Subdirectories are
  # purely organizational — each .nix file inside returns `{ section = tests; }`
  # and those are flattened into one map of section -> tests.
  sectionDirs =
    let entries = builtins.readDir ./.;
    in lib.filter (name: entries.${name} == "directory") (lib.attrNames entries);

  sections = lib.foldl' (acc: dir:
    acc // (importTestsFrom (./. + "/${dir}"))
  ) {} sectionDirs;

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

  checks = {
    tests =
      if allPassed
      then pkgs.runCommand "forest-tests" {} "echo all tests passed; touch $out"
      else pkgs.runCommand "forest-tests-failed" { failure = summary; } ''
        printf '%s\n' "$failure"
        exit 1
      '';

    cli = import ./cli.nix { inherit pkgs; };
  };
}

# Forest tests entry point.
#
# Eval-time unit tests for forest/utils:
#   nix-instantiate --eval ./tests -A summary
#   nix-instantiate --eval ./tests -A allPassed
#
# Build-time checks (consumed by flake.nix):
#   .checks.tests  — derivation that fails if any unit test fails
#   .checks.cli    — derivation that exercises forest/cli/forest.sh against stubs
#
# Adding a test file:
#   Drop a `.nix` file inside any subdirectory next to this one. It receives
#   `{ lib, pkgs, utils, runners }` and returns EITHER:
#     - a pure-eval unit-test file: { tests = { caseName = result; ... }; }
#       where each result has `passed`, `expected`, `actual`; or
#     - a build-time check: a derivation (realized via `.checks.<dir>-<file>`,
#       like the top-level cli/firewall checks). Importing it is still pure eval;
#       only `nix build`/`nix flake check` realizes it.
#
#   The file is responsible for flattening multiple groups into one shallow
#   `tests` attrset (collisions inside a single file are the file's problem,
#   but cross-file collisions are impossible — sections are keyed by file path).
{
  system ? builtins.currentSystem,
  inputs ? import ../.tack,
  pkgs ? inputs.nixpkgs.legacyPackages.${system},
}:

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

  sectionDirs =
    let entries = builtins.readDir ./.;
    in lib.filter (name: entries.${name} == "directory") (lib.attrNames entries);

  # Import every subdir .nix once, keyed "<dir>/<file>" (path-unique, so
  # cross-file collisions are impossible). Each is classified below as a pure-eval
  # test file (has `tests`) or a build-check (a derivation).
  subdirEntries = lib.concatMap (dir:
    let
      dirPath = ./. + "/${dir}";
      entries = builtins.readDir dirPath;
      nixFiles = lib.filter
        (name: entries.${name} == "regular" && lib.hasSuffix ".nix" name)
        (lib.attrNames entries);
      stripExt = name: lib.removeSuffix ".nix" name;
    in lib.map (file: {
      name = "${dir}/${stripExt file}";
      value = import (dirPath + "/${file}") args;
    }) nixFiles
  ) sectionDirs;

  badFiles = lib.filter (e: !(e.value ? tests) && !(lib.isDerivation e.value)) subdirEntries;

  # sections : { "<dir>/<file>" = <flat-tests-attrset>; } — pure-eval test files.
  sections = lib.listToAttrs (lib.map (e: { inherit (e) name; value = e.value.tests; })
    (lib.filter (e: e.value ? tests) subdirEntries));

  # discoveredChecks : { "<dir>-<file>" = <derivation>; } — build-check files.
  discoveredChecks = lib.throwIf (badFiles != [])
    "tests: ${(lib.head badFiles).name}.nix must return { tests = {...}; } or a derivation"
    (lib.listToAttrs (lib.map
      (e: { name = lib.replaceStrings [ "/" ] [ "-" ] e.name; value = e.value; })
      (lib.filter (e: lib.isDerivation e.value) subdirEntries)));

  allResults = lib.foldlAttrs (acc: sectionPath: results:
    acc // (lib.mapAttrs' (caseName: r:
      lib.nameValuePair "${sectionPath}/${caseName}" r
    ) results)
  ) {} sections;

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

  formatAllSections = lib.concatStringsSep "\n\n" (lib.mapAttrsToList (sectionPath: results:
    "${sectionPath}:\n${formatSection results}"
  ) sections);

in rec {
  allPassed = builtins.all (r: r.passed) (builtins.attrValues allResults);

  summary = ''
    Forest Tests
    ============

    ${formatAllSections}

    Overall: ${if allPassed then "All tests passed!" else "Some tests FAILED!"}
    ${lib.optionalString (!allPassed) "\n    Failures:\n${formatFailures allResults}"}
  '';

  inherit allResults;

  checks = {
    tests =
      if allPassed
      then pkgs.runCommand "forest-tests" { passing = summary; } ''
        printf '%s\n' "$passing"
        touch $out
      ''
      else pkgs.runCommand "forest-tests-failed" { failure = summary; } ''
        printf '%s\n' "$failure"
        exit 1
      '';

    cli = import ./cli.nix { inherit pkgs; };

    firewall = import ./firewall.nix { inherit pkgs; };
  } // discoveredChecks;
}

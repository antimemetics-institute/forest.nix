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
# Adding a new test file:
#   Drop a `.nix` file inside any subdirectory next to this one. The file
#   receives `{ lib, pkgs, utils, runners }` and must return:
#     { tests = { caseName = result; ... }; }
#   where each result has `passed`, `expected`, `actual`.
#
#   The file is responsible for flattening multiple groups into one shallow
#   `tests` attrset (collisions inside a single file are the file's problem,
#   but cross-file collisions are impossible — sections are keyed by file path).
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

  loadTestFile = path:
    let
      imported = import path args;
      hasTests = imported ? tests;
    in if hasTests
       then imported.tests
       else throw "test file ${toString path} must return { tests = { ... }; } (got attrs: ${lib.concatStringsSep ", " (lib.attrNames imported)})";

  sectionDirs =
    let entries = builtins.readDir ./.;
    in lib.filter (name: entries.${name} == "directory") (lib.attrNames entries);

  # sections : { "<dir>/<file>" = <flat-tests-attrset>; }
  # The path key is filesystem-unique so cross-file collisions are impossible.
  sections = lib.listToAttrs (lib.concatMap (dir:
    let
      dirPath = ./. + "/${dir}";
      entries = builtins.readDir dirPath;
      nixFiles = lib.filter
        (name: entries.${name} == "regular" && lib.hasSuffix ".nix" name)
        (lib.attrNames entries);
      stripExt = name: lib.removeSuffix ".nix" name;
    in lib.map (file: {
      name = "${dir}/${stripExt file}";
      value = loadTestFile (dirPath + "/${file}");
    }) nixFiles
  ) sectionDirs);

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
  };
}

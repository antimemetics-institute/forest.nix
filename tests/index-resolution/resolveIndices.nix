{ lib, utils, runners, ... }:

let
  # Each input maps a VM name to its explicit `index` (or null for auto).
  # The fn under test only reads `.index`, so we wrap each int/null in a stub VM.
  mkVms = indexMap: lib.mapAttrs (_: idx: { index = idx; }) indexMap;

  testCases = {
    empty = {
      input = mkVms {};
      expected = {};
    };

    allAuto = {
      input = mkVms { alpha = null; bravo = null; charlie = null; };
      expected = { alpha = 0; bravo = 1; charlie = 2; };
    };

    allExplicit = {
      input = mkVms { alpha = 5; bravo = 1; charlie = 9; };
      expected = { alpha = 5; bravo = 1; charlie = 9; };
    };

    # bravo is pinned to 0, so alpha (auto) must skip 0 and take 1; charlie
    # (auto, walks last) takes 2.
    autoSkipsLowPinned = {
      input = mkVms { alpha = null; bravo = 0; charlie = null; };
      expected = { alpha = 1; bravo = 0; charlie = 2; };
    };

    # A pinned high index leaves all the low slots free for auto VMs.
    pinnedHighLeavesLowFree = {
      input = mkVms { alpha = null; bravo = 100; charlie = null; };
      expected = { alpha = 0; bravo = 100; charlie = 1; };
    };

    # charlie's pin (1) is reserved upfront, so when bravo (auto, second) goes
    # looking for a slot it must skip 0 (taken by alpha) and 1 (charlie's pin).
    autoSkipsExplicitPinFromAnyOrder = {
      input = mkVms { alpha = null; bravo = null; charlie = 1; };
      expected = { alpha = 0; bravo = 2; charlie = 1; };
    };

    # Explicit values can be in any range — no clamping happens here.
    explicitOutOfRangePassesThrough = {
      input = mkVms { alpha = 1000; };
      expected = { alpha = 1000; };
    };

    # Names are walked in lib.attrNames order (lexicographic), so adding a name
    # that sorts later doesn't perturb earlier auto-assignments.
    addingLaterNameDoesNotShift = {
      input = mkVms { alpha = null; bravo = null; zeta = null; };
      expected = { alpha = 0; bravo = 1; zeta = 2; };
    };

    # Pin matches alphabetical position: nothing shifts. charlie is 3rd
    # alphabetically and pinned to index 2 (its natural position), so the
    # auto-assigned VMs around it land where they would've anyway.
    pinMatchingNaturalPosition = {
      input = mkVms {
        alpha = null;
        bravo = null;
        charlie = 2;
        delta = null;
        echo = null;
      };
      expected = { alpha = 0; bravo = 1; charlie = 2; delta = 3; echo = 4; };
    };

    # Pin held by the alphabetically-last VM: every auto VM that comes before
    # it has to step over the pinned slot. echo pins 2, so charlie and delta
    # (both auto, sorted before echo) get shifted up to 3 and 4.
    pinHeldByLastNameShiftsAutosAroundIt = {
      input = mkVms {
        alpha = null;
        bravo = null;
        charlie = null;
        delta = null;
        echo = 2;
      };
      expected = { alpha = 0; bravo = 1; charlie = 3; delta = 4; echo = 2; };
    };
  };

  runResolve = name: test:
    let actual = utils.resolveIndices test.input;
    in {
      inherit name actual;
      inherit (test) expected;
      passed = actual == test.expected;
    };
in {
  resolveIndices = lib.mapAttrs runResolve testCases;
}

{ lib }:

{
  # Resolve VM indices for an attrset of `{ name = { index = nullable int; ... } }`.
  # Returns `{ name = int; }`, one entry per input VM.
  #
  # Explicit indices win — those VMs keep the index they were given. The
  # remaining VMs are walked in `lib.attrNames` order (lexicographic) and each
  # is assigned the lowest free slot, where "free" means not pinned by an
  # explicit index and not already given to an earlier auto-assigned VM.
  #
  # No range or duplicate-conflict checks happen here — the caller asserts those.
  resolveIndices = vms:
    let
      names = lib.attrNames vms;
      pinned = lib.foldl' (acc: n:
        let i = vms.${n}.index;
        in if i != null then acc // { ${toString i} = true; } else acc
      ) {} names;
      step = state: name:
        let explicit = vms.${name}.index;
        in if explicit != null then {
          resolved = state.resolved // { ${name} = explicit; };
          inherit (state) usedAuto;
        } else let
          isTaken = c: (pinned ? ${toString c}) || (lib.elem c state.usedAuto);
          findFree = c: if isTaken c then findFree (c + 1) else c;
          assigned = findFree 0;
        in {
          resolved = state.resolved // { ${name} = assigned; };
          usedAuto = state.usedAuto ++ [ assigned ];
        };
    in
      (lib.foldl' step { resolved = {}; usedAuto = []; } names).resolved;
}

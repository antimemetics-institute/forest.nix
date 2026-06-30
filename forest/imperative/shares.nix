# Lower an agent's high-level `shares` list to the plumbing that realizes it:
# `microvm.shares` the guest bakes, plus a plant-list the launcher acts on at run
# time. (microvm itself turns each share into a guest mount; this just gives that
# a friendlier, guest-oriented spelling.)
#
# Each entry is `{ from; into; }`:
#   from = { cwd = true; }        the directory `nix run` was invoked from
#        | { home = "rel/path"; } resolved against the invoking user's $HOME
#        | { path = "/abs"; }     a literal host path
#   into = "/guest/path"          a literal mountpoint (normal mount semantics:
#                                 the source's contents appear exactly there)
#        | { under = "/dir"; }    land at "/dir/<basename of source>"
#
# `into.under` works with any `from` — it just appends the source's basename. For
# static sources (home/path) that basename is known at eval, so the mountpoint is
# baked like any other. Only `from.cwd` has a *runtime* basename, so it's the sole
# case that can't bake its final mountpoint: it lands at a fixed staging point and
# the launcher binds it to `<under>/<basename $PWD>` once the VM is up.
#
# Sources: `path` is a literal host dir microvm serves directly. `cwd`/`home` are
# resolved at launch, so they get a placeholder source (a state-dir tag the runner
# rebases and the launcher plants as a symlink — same mechanism as the managed
# shares).
{ lib }:

{ name, shares }:

let
  sourceKind = import ./source.nix;
  stateRoot = "/var/lib/microvms";

  entry = i: s:
    let
      tag = "fshare${toString i}";
      from = s.from;
      kind = sourceKind from;

      # `path` is served in place; cwd/home are launch-resolved via a planted symlink.
      source = if kind == "path" then from.path else "${stateRoot}/${name}/${tag}";
      arg = if kind == "home" then from.home else if kind == "path" then from.path else "";

      isUnder = lib.isAttrs s.into && s.into ? under;
      # Only cwd's basename is unknown at eval; home/path resolve statically.
      runtimeLeaf = isUnder && kind == "cwd";
      staticLeaf = if kind == "home" then baseNameOf from.home else baseNameOf from.path;

      staging = "/run/forest/${tag}";
      mountPoint =
        if !isUnder then s.into
        else if runtimeLeaf then staging
        else "${s.into.under}/${staticLeaf}";
    in
    {
      share = { proto = "virtiofs"; inherit tag source mountPoint; };
      plant = {
        inherit tag kind arg mountPoint;
        # For the one runtime-leaf case the launcher binds `staging` to
        # `<under>/<basename $PWD>` in the guest; null everywhere else.
        bindUnder = if runtimeLeaf then s.into.under else null;
      };
    };

  entries = lib.imap0 entry shares;
in
{
  shares = map (e: e.share) entries;
  plants = map (e: e.plant) entries;
}

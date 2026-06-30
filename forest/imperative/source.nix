# The source vocabulary shared by a share's `from` (forest/imperative/shares.nix)
# and a `seed` entry (forest/imperative/launcher.nix): a source is exactly one of
#
#   { cwd = true; }        | { home = "rel/path"; } | { path = "/abs"; }
#
# This is the matcher naming which one it is (rejecting anything else), so every
# consumer branches on the same three cases the same way — typically by dispatching
# an attrset with `(sourceKind src)`.
src:
if src ? cwd then "cwd"
else if src ? home then "home"
else if src ? path then "path"
else throw "forest/imperative: source must be one of cwd, home, path"

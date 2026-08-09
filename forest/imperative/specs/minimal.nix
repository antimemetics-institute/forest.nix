# The default imperative VM — an ephemeral sandbox in your current directory,
# run with `nix run .#default` (or a bare `nix run` on the flake).
#
# The minimal spec: no `user` (defaults to root — under the rootless runner
# guest-uid-0 maps back to *your* host uid, so edits to the mounted cwd come
# back owned by you), no `command` (empty means an interactive login shell),
# one share mounting the launch directory into root's home.
{
  name = "minimal";

  shares = [
    { from = { cwd = true; }; into = { under = "/root"; }; }
  ];

  vm.config = { };
}

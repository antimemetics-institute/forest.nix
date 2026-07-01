# agents.claude: a sandboxed, ephemeral Claude Code VM, run with
# `nix run .#agents.claude`.
#
# Pure data — the flake feeds this spec to the imperative builder
# (forest/imperative). The imperative infra (qemu / user-net / rootless virtiofsd)
# and the planted-key vsock auth are applied by mkImperativeRunner; the entrypoint
# runs over ssh as `user`. `config` is a normal NixOS module, so its `pkgs` is
# resolved lazily during the guest eval — nothing needs injecting here.
{
  name = "claude";
  user = "claude";
  # entrypoint run over ssh; claude is on PATH via the package installed below.
  # IS_SANDBOX=1 tells Claude Code it's in a sandbox, so it allows
  # --dangerously-skip-permissions as root (uid 0) instead of refusing — correct
  # here, since the unprivileged-namespace VM is itself the boundary. Via `env`
  # because the entrypoint is exec'd (a bare VAR=val prefix would be the command).
  command = "env IS_SANDBOX=1 claude --dangerously-skip-permissions";

  # The dir you launched from is mounted at /home/claude/<its basename>, edited as
  # uid 0 so changes come back owned by you (forest/imperative/shares.nix).
  shares = [
    { from = { cwd = true; }; into = { under = "/home/claude"; }; }
  ];

  # Claude's config (the ~/.claude dir *and* the ~/.claude.json file beside it) is
  # copied into the agent's home by basename as a private, writable snapshot — NOT
  # mounted. It's the agent's session identity, not its output: we lend it your
  # auth, but its changes (history, token churn) stay in the VM and never touch your
  # host config. Mounting would also race across concurrent agents sharing one live
  # config. Sources use the same cwd/home/path vocabulary as `shares`; missing ones
  # are skipped.
  seed = [
    { home = ".claude"; }
    { home = ".claude.json"; }
  ];

  vm = {
    config = { pkgs, lib, ... }: {
      # `claude` is a uid-0 alias, not a separate unprivileged user. Under the
      # runner's user namespace (--map-auto) guest-uid-0 maps to *your* host uid,
      # so the agent's edits to the mounted cwd land owned by you — no keep-id or
      # uid-shifting. It logs in as `claude` (HOME=/home/claude) with root's
      # powers, which is fine: the VM itself is the sandbox boundary.
      #
      # A second uid-0 entry alongside root trips NixOS's UID-uniqueness assertion,
      # which enforceIdUniqueness = false is meant to waive (it's the supported knob
      # for uid aliases).
      users.enforceIdUniqueness = false;
      users.users.claude = {
        uid = 0;
        group = "root";
        home = "/home/claude";
        createHome = true;
        shell = pkgs.bashInteractive;
        description = "Claude agent";
      };
      # claude-code is unfree; pull it from a package set that allows exactly it, so
      # `nix run .#agents.claude` needs no NIXPKGS_ALLOW_UNFREE and nothing else
      # unfree can slip in. Self-contained here — no whole-guest pkgs swap, no builder
      # special-casing. `import pkgs.path {…}` re-instantiates nixpkgs for this one
      # leaf package; same source ⇒ same derivation, so no store duplication.
      environment.systemPackages = [
        (import pkgs.path {
          inherit (pkgs.stdenv.hostPlatform) system;
          config.allowUnfreePredicate = p: lib.getName p == "claude-code";
        }).claude-code
      ];
    };
  };
}

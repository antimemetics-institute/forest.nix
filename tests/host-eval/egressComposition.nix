{ lib, pkgs, ... }:

# Host-level eval test for the egress *composition* in networking/host.nix —
# the layer the generator unit tests bypass. Those tests call the rule
# generators with pre-filtered VM sets; here we evaluate a full host config
# and assert on the rendered nftables table contents, pinning:
#
#   1. The filters at the top of host.nix: scoped allowEgress masquerade is
#      emitted for no-internet VMs only (internet VMs ride the blanket rule),
#      and the blanket masquerade is emitted for internet VMs only.
#   2. Rule order in the forward chain: allowEgress accepts precede every
#      drop — the inter-VM drop, the private-range drops, and the chain-end
#      catch-all. The generators can't get this wrong; the string
#      interpolation in host.nix can, and nft --check wouldn't notice.

let
  stateVersion = "24.11";

  forestModule = import ../../default.nix {};

  # Same stubs as nat.nix: satisfy the full NixOS module set's unrelated
  # assertions (root fs, bootloader) so they don't pollute the signal.
  baseHost = {
    boot.loader.grub.devices = [ "nodev" ];
    fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
    system.stateVersion = stateVersion;
  };

  # Both sides of internetAccess carry carveouts, so the NAT filter has
  # something to include *and* something to exclude. `db` also has a public
  # daddr — the "deny the internet, allow one API" shape whose ordering
  # against the catch-all is the whole point of allowEgress.
  fixture = {
    forest.enable = true;
    forest.vms = {
      web = {
        internetAccess = true;
        allowEgress = [
          { daddr = "10.10.0.3"; port = 22; }
        ];
        config = { system.stateVersion = stateVersion; };
      };
      db = {
        internetAccess = false;
        allowEgress = [
          { daddr = "10.10.0.4"; port = 5432; }
          { daddr = "fd00::4"; port = 5432; }
          { daddr = "160.79.104.10"; port = 443; }
        ];
        config = { system.stateVersion = stateVersion; };
      };
    };
  };

  cfg = (pkgs.nixos ({ ... }: {
    imports = [ forestModule baseHost fixture ];
  })).config;

  web = cfg.forest.vms.web;
  db = cfg.forest.vms.db;

  nat4 = cfg.networking.nftables.tables."forest_nat".content;
  nat6 = cfg.networking.nftables.tables."forest_nat6".content;
  # Ordering claims are about the forward chain; the input chain above it
  # has its own drops that would satisfy a whole-content search spuriously.
  forward = lib.last (lib.splitString "chain forward" cfg.networking.nftables.tables."forest_filter".content);

  posOf = hay: needle: lib.stringLength (lib.head (lib.splitString needle hay));
  precedes = hay: a: b:
    lib.hasInfix a hay && lib.hasInfix b hay && posOf hay a < posOf hay b;

  interVmDrop = "ip saddr ${cfg.forest.vmSubnet} ip daddr ${cfg.forest.vmSubnet} drop";
  catchAllDrop = ''ip saddr ${cfg.forest.vmSubnet} drop comment "Block VM traffic from being forwarded IPv4"'';
  # generateInternetForwardRules renders web's private-range drop as a set.
  privateRangeDrop = "ip saddr ${web.ipv4} ip daddr {";

  testCases = {
    # ── NAT filtering (host.nix internetVms / allowEgressNatVms) ──
    scopedNatForNoInternetVm = {
      check = lib.hasInfix
        ''ip saddr ${db.ipv4} ip daddr 10.10.0.4 oifname != "${cfg.forest.bridgeInterface}" masquerade''
        nat4;
      expected = "scoped v4 masquerade for db's private carveout";
      actualOnFail = nat4;
    };
    scopedNatForPublicDaddr = {
      check = lib.hasInfix "ip saddr ${db.ipv4} ip daddr 160.79.104.10 oifname" nat4;
      expected = "scoped v4 masquerade for db's public carveout";
      actualOnFail = nat4;
    };
    scopedNat6ForNoInternetVm = {
      check = lib.hasInfix
        ''ip6 saddr ${db.ipv6} ip6 daddr fd00::4 oifname != "${cfg.forest.bridgeInterface}" masquerade''
        nat6;
      expected = "scoped v6 masquerade for db's v6 carveout";
      actualOnFail = nat6;
    };
    # The internet VM's carveout must NOT reach the scoped NAT pass — its
    # blanket masquerade already covers it. Its daddr appearing here would
    # mean the allowEgressNatVms filter stopped excluding internetAccess.
    noScopedNatForInternetVm = {
      check = !(lib.hasInfix "ip daddr 10.10.0.3" nat4);
      expected = "no scoped masquerade for web's carveout";
      actualOnFail = nat4;
    };
    blanketNatForInternetVm = {
      check = lib.hasInfix
        ''ip saddr ${web.ipv4} oifname != "${cfg.forest.bridgeInterface}" masquerade''
        nat4;
      expected = "blanket v4 masquerade for web";
      actualOnFail = nat4;
    };
    # The blanket rule is saddr-then-oifname with no daddr in between, so
    # this substring can't be satisfied by db's scoped rules.
    noBlanketNatForNoInternetVm = {
      check = !(lib.hasInfix "ip saddr ${db.ipv4} oifname" nat4);
      expected = "no blanket v4 masquerade for db";
      actualOnFail = nat4;
    };
    noBlanketNat6ForNoInternetVm = {
      check = !(lib.hasInfix "ip6 saddr ${db.ipv6} oifname" nat6);
      expected = "no blanket v6 masquerade for db";
      actualOnFail = nat6;
    };

    # ── Forward-chain ordering (host.nix interpolation order) ──
    egressAcceptBeforeInterVmDrop = {
      check = precedes forward "ip daddr 160.79.104.10" interVmDrop;
      expected = "db's carveout accept precedes the inter-VM drop";
      actualOnFail = forward;
    };
    egressAcceptBeforeCatchAll = {
      check = precedes forward "ip daddr 160.79.104.10" catchAllDrop;
      expected = "db's carveout accept precedes the chain-end catch-all";
      actualOnFail = forward;
    };
    egressAcceptBeforePrivateRangeDrop = {
      check = precedes forward "ip saddr ${web.ipv4} ip daddr 10.10.0.3" privateRangeDrop;
      expected = "web's carveout accept precedes web's private-range drop";
      actualOnFail = forward;
    };
    privateRangeDropBeforeCatchAll = {
      check = precedes forward privateRangeDrop catchAllDrop;
      expected = "web's private-range drop precedes the chain-end catch-all";
      actualOnFail = forward;
    };
  };

  runCase = name: t:
    let
      # deepSeq under tryEval so a lazy throw inside the rendered content
      # reads as a failure, not an eval abort of the whole suite.
      result = builtins.tryEval (builtins.deepSeq t.check t.check);
      passed = result.success && result.value;
    in {
      inherit name passed;
      inherit (t) expected;
      actual =
        if !result.success then "eval threw while rendering nftables tables"
        else if passed then "OK"
        else t.actualOnFail;
    };
in {
  tests = lib.mapAttrs runCase testCases;
}

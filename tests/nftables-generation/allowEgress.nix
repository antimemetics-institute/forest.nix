{ lib, utils, runners, ... }:

let
  vmWith = { ipv4 ? "192.168.69.10", ipv6 ? "fd69::10", allowEgress }: {
    inherit ipv4 ipv6 allowEgress;
  };

  entry = daddr: port: { inherit daddr port; protocol = "tcp"; };

  # ── generateAllowEgressRules ──────────────────────────────────────

  testCasesForward = {
    noVms = { input = {}; expected = ""; };
    noEntries = {
      input = { dev = vmWith { allowEgress = []; }; };
      expected = "";
    };
    singleV4 = {
      input = { dev = vmWith { allowEgress = [ (entry "10.10.0.3" 22) ]; }; };
      expected = ''ip saddr 192.168.69.10 ip daddr 10.10.0.3 tcp dport { 22 } counter accept comment "Allow -> 10.10.0.3"'';
    };
    # Family follows the daddr literal: a v6 destination pairs with the VM's
    # v6 address and emits ip6 qualifiers, with no ipVersion field involved.
    singleV6 = {
      input = { dev = vmWith { allowEgress = [ (entry "fd00::3" 22) ]; }; };
      expected = ''ip6 saddr fd69::10 ip6 daddr fd00::3 tcp dport { 22 } counter accept comment "Allow -> fd00::3"'';
    };
    cidrDestination = {
      input = { dev = vmWith { allowEgress = [ (entry "192.168.1.0/24" 631) ]; }; };
      expected = ''ip saddr 192.168.69.10 ip daddr 192.168.1.0/24 tcp dport { 631 } counter accept comment "Allow -> 192.168.1.0/24"'';
    };
    # A public destination is not special-cased. Paired with the caller placing
    # these ahead of the chain-end catch-all, this is what lets a VM with
    # internetAccess = false reach exactly one public API and nothing else.
    publicDestination = {
      input = { dev = vmWith { allowEgress = [ (entry "160.79.104.10" 443) ]; }; };
      expected = ''ip saddr 192.168.69.10 ip daddr 160.79.104.10 tcp dport { 443 } counter accept comment "Allow -> 160.79.104.10"'';
    };
    multiplePortsSameDest = {
      input = {
        dev = vmWith { allowEgress = [ (entry "10.10.0.3" 22) (entry "10.10.0.3" 2222) ]; };
      };
      expected = ''ip saddr 192.168.69.10 ip daddr 10.10.0.3 tcp dport { 22, 2222 } counter accept comment "Allow -> 10.10.0.3"'';
    };
    bothProtocol = {
      input = {
        dev = vmWith {
          allowEgress = [ { daddr = "10.10.0.3"; port = 53; protocol = "both"; } ];
        };
      };
      expected = ''
        ip saddr 192.168.69.10 ip daddr 10.10.0.3 tcp dport { 53 } counter accept comment "Allow -> 10.10.0.3"
        ip saddr 192.168.69.10 ip daddr 10.10.0.3 udp dport { 53 } counter accept comment "Allow -> 10.10.0.3"'';
    };
    mixedFamiliesOneVm = {
      input = {
        dev = vmWith { allowEgress = [ (entry "10.10.0.3" 22) (entry "fd00::3" 22) ]; };
      };
      expected = ''
        ip saddr 192.168.69.10 ip daddr 10.10.0.3 tcp dport { 22 } counter accept comment "Allow -> 10.10.0.3"
        ip6 saddr fd69::10 ip6 daddr fd00::3 tcp dport { 22 } counter accept comment "Allow -> fd00::3"'';
    };
    multipleVms = {
      input = {
        dev = vmWith { allowEgress = [ (entry "10.10.0.3" 22) ]; };
        ci = vmWith {
          ipv4 = "192.168.69.11"; ipv6 = "fd69::11";
          allowEgress = [ (entry "10.10.0.4" 443) ];
        };
        idle = vmWith { ipv4 = "192.168.69.12"; ipv6 = "fd69::12"; allowEgress = []; };
      };
      # VMs are walked in name order; the empty one contributes nothing.
      expected = ''
        ip saddr 192.168.69.11 ip daddr 10.10.0.4 tcp dport { 443 } counter accept comment "Allow -> 10.10.0.4"
        ip saddr 192.168.69.10 ip daddr 10.10.0.3 tcp dport { 22 } counter accept comment "Allow -> 10.10.0.3"'';
    };
  };

  # ── generateAllowEgressNatRules ─────────────────────────────────

  testCasesNat4 = {
    noVms = { input = {}; expected = ""; };
    singleV4 = {
      input = { dev = vmWith { allowEgress = [ (entry "10.10.0.3" 22) ]; }; };
      expected = "            ip saddr 192.168.69.10 ip daddr 10.10.0.3 oifname != \"forest\" masquerade";
    };
    # One masquerade rule per destination — ports don't change the NAT.
    dedupesPorts = {
      input = {
        dev = vmWith { allowEgress = [ (entry "10.10.0.3" 22) (entry "10.10.0.3" 2222) ]; };
      };
      expected = "            ip saddr 192.168.69.10 ip daddr 10.10.0.3 oifname != \"forest\" masquerade";
    };
    # A CIDR daddr passes through to the masquerade rule verbatim; nft accepts
    # a prefix there just as it does in the filter chain.
    cidrDestination = {
      input = { dev = vmWith { allowEgress = [ (entry "192.168.1.0/24" 631) ]; }; };
      expected = "            ip saddr 192.168.69.10 ip daddr 192.168.1.0/24 oifname != \"forest\" masquerade";
    };
    # Public destinations get masqueraded too — without it, a no-internet VM's
    # carveout traffic would leave the host carrying an unroutable source.
    publicDestination = {
      input = { dev = vmWith { allowEgress = [ (entry "160.79.104.10" 443) ]; }; };
      expected = "            ip saddr 192.168.69.10 ip daddr 160.79.104.10 oifname != \"forest\" masquerade";
    };
    # The ip table can't hold ip6 rules; v6 destinations belong to the v6 pass.
    skipsV6Destinations = {
      input = { dev = vmWith { allowEgress = [ (entry "fd00::3" 22) ]; }; };
      expected = "";
    };
  };

  testCasesNat6 = {
    noVms = { input = {}; expected = ""; };
    singleV6 = {
      input = { dev = vmWith { allowEgress = [ (entry "fd00::3" 22) ]; }; };
      expected = "            ip6 saddr fd69::10 ip6 daddr fd00::3 oifname != \"forest\" masquerade";
    };
    skipsV4Destinations = {
      input = { dev = vmWith { allowEgress = [ (entry "10.10.0.3" 22) ]; }; };
      expected = "";
    };
    cidrDestination = {
      input = { dev = vmWith { allowEgress = [ (entry "fd00::/64" 5432) ]; }; };
      expected = "            ip6 saddr fd69::10 ip6 daddr fd00::/64 oifname != \"forest\" masquerade";
    };
  };

  # ── addrInSubnet ──────────────────────────────────────────────────

  # Backs the assertion that sends forest-subnet destinations to dependsOn.
  # vmSubnet is a user-facing option, so the prefix length has to be honoured
  # rather than assumed — a forest on 10.0.0.0/8 must still catch 10.5.3.1.
  testCasesInSubnet = {
    vmIpInV4Subnet = { subnet = "192.168.69.0/24"; addr = "192.168.69.10"; expected = true; };
    routedV4Outside = { subnet = "192.168.69.0/24"; addr = "10.10.0.3"; expected = false; };
    # Neighbouring /24 under the same /16 — the third octet is what separates them.
    adjacentV4Subnet = { subnet = "192.168.69.0/24"; addr = "192.168.1.5"; expected = false; };
    # A mask on `addr` is stripped — these ask about the CIDR's *base*, not
    # about containment. Named accordingly so nobody "fixes" the asymmetry:
    # the /16 below is true for the same reason the /28 is, and it is the /24's
    # superset, not its subset. `subnetsOverlap` is the containment-safe form.
    v4CidrBaseInside = { subnet = "192.168.69.0/24"; addr = "192.168.69.0/28"; expected = true; };
    v4WiderCidrSharesBase = { subnet = "192.168.69.0/24"; addr = "192.168.69.0/16"; expected = true; };
    # Host bits in either literal wash out: both sides are masked to the
    # subnet's prefix, so this is 192.168.0.0/16 vs 192.168.69.x either way.
    v4NonCanonicalSubnet = { subnet = "192.168.12.12/16"; addr = "192.168.69.10"; expected = true; };
    v4NonCanonicalAddr = { subnet = "192.168.0.0/16"; addr = "192.168.12.12/16"; expected = true; };
    # Short prefixes: only the octets the mask covers may be compared.
    slashEightInside = { subnet = "10.0.0.0/8"; addr = "10.5.3.1"; expected = true; };
    slashEightOutside = { subnet = "10.0.0.0/8"; addr = "192.168.1.5"; expected = false; };
    # ...and the label boundary is a boundary, not a substring match.
    slashEightNearMiss = { subnet = "10.0.0.0/8"; addr = "110.5.3.1"; expected = false; };
    slashSixteenInside = { subnet = "172.16.0.0/16"; addr = "172.16.9.4"; expected = true; };
    slashSixteenOutside = { subnet = "172.16.0.0/16"; addr = "172.17.9.4"; expected = false; };

    # Prefixes that end mid-octet: the boundary octet is compared under a
    # mask, so neighbours sharing it are still excluded.
    slashNineInside = { subnet = "10.128.0.0/9"; addr = "10.200.3.1"; expected = true; };
    # 10.5.3.1 shares the first octet but sits in the other half of the /8.
    slashNineExcludesLowerHalf = { subnet = "10.128.0.0/9"; addr = "10.5.3.1"; expected = false; };
    slashNineOutside = { subnet = "10.128.0.0/9"; addr = "11.0.0.1"; expected = false; };
    slashTwelveInside = { subnet = "172.16.0.0/12"; addr = "172.31.0.1"; expected = true; };
    # 172.32.0.1 is one step past the end of 172.16.0.0/12.
    slashTwelveJustPastEnd = { subnet = "172.16.0.0/12"; addr = "172.32.0.1"; expected = false; };
    slashTwelveOutside = { subnet = "172.16.0.0/12"; addr = "10.1.2.3"; expected = false; };
    slashTwentyInside = { subnet = "192.168.16.0/20"; addr = "192.168.31.5"; expected = true; };
    slashTwentyJustPastEnd = { subnet = "192.168.16.0/20"; addr = "192.168.32.5"; expected = false; };
    slashTwentyOutside = { subnet = "192.168.16.0/20"; addr = "192.169.16.5"; expected = false; };
    # A zero-padded octet reads as decimal rather than throwing.
    zeroPaddedOctet = { subnet = "010.0.0.0/8"; addr = "10.5.3.1"; expected = true; };

    vmIpInV6Subnet = { subnet = "fd69::/64"; addr = "fd69::10"; expected = true; };
    routedV6Outside = { subnet = "fd69::/64"; addr = "fd00::3"; expected = false; };
    # Compression is expanded before comparing, so a longer address doesn't
    # false-positive against a shorter prefix and vice versa.
    v6SlashFortyEight = { subnet = "fd69:1:2::/48"; addr = "fd69:1:2:3::10"; expected = true; };
    v6DeeperAddrOutsideSlash64 = { subnet = "fd69::/64"; addr = "fd69:1:2:3::10"; expected = false; };
    # /56 ends mid-hextet: the top byte of the 4th hextet is what decides.
    v6SlashFiftySixInside = { subnet = "fd69:1:2::/56"; addr = "fd69:1:2:00ff::1"; expected = true; };
    v6SlashFiftySixOutside = { subnet = "fd69:1:2::/56"; addr = "fd69:1:2:ff00::1"; expected = false; };
    # Hextets compare numerically, so case and zero-padding don't matter.
    v6MixedCaseAndPadding = { subnet = "FD69:0:0:0::/64"; addr = "fd69::10"; expected = true; };
    # Family mismatch is never containment, either direction.
    v6AddrV4Subnet = { subnet = "192.168.69.0/24"; addr = "fd69::10"; expected = false; };
    v4AddrV6Subnet = { subnet = "fd69::/64"; addr = "192.168.69.10"; expected = false; };
    uncompressedV6Prefix = { subnet = "fd69:0:0:0:0:0:0:0/64"; addr = "fd69:0:0:0::10"; expected = true; };
    barePrefixlessAddr = { subnet = "192.168.69.10"; addr = "192.168.69.10"; expected = true; };
  };

  runInSubnet = name: t:
    let actual = utils.addrInSubnet t.addr t.subnet;
    in {
      inherit name actual;
      inherit (t) expected;
      passed = actual == t.expected;
    };

  # ── subnetsOverlap ────────────────────────────────────────────────

  # What the allowEgress guard actually asks. addrInSubnet alone only catches
  # an entry whose *base* lands in the forest; a CIDR wide enough to contain
  # the forest has its base outside and would otherwise slip through, taking
  # every VM with it since the accept precedes the inter-VM drop.
  testCasesOverlap = {
    # The containment cases addrInSubnet already handled, still caught.
    vmAddrInForest = { a = "192.168.69.10"; b = "192.168.69.0/24"; expected = true; };
    subCidrInForest = { a = "192.168.69.0/28"; b = "192.168.69.0/24"; expected = true; };

    # The direction that was missing: entry ⊃ forest.
    supernetContainsForest = { a = "192.168.0.0/16"; b = "192.168.69.0/24"; expected = true; };
    defaultRouteContainsForest = { a = "0.0.0.0/0"; b = "192.168.69.0/24"; expected = true; };
    # Mid-octet prefix that still reaches the forest's third octet.
    supernet18ContainsForest = { a = "192.168.64.0/18"; b = "192.168.69.0/24"; expected = true; };
    # A forest pinned inside RFC1918 10/8 makes an ordinary LAN entry overlap.
    lanSupernetOverCustomForest = { a = "10.0.0.0/8"; b = "10.0.0.0/24"; expected = true; };
    v6SupernetContainsForest = { a = "fd00::/8"; b = "fd69::/64"; expected = true; };
    v6DefaultRoute = { a = "::/0"; b = "fd69::/64"; expected = true; };

    # Genuinely disjoint entries must still pass — the guard has to stay usable.
    routedHostOutside = { a = "10.10.0.3"; b = "192.168.69.0/24"; expected = false; };
    lanCidrOutside = { a = "192.168.1.0/24"; b = "192.168.69.0/24"; expected = false; };
    # Adjacent /18 under the same /16, one step short of the forest.
    adjacentSupernet18 = { a = "192.168.0.0/18"; b = "192.168.69.0/24"; expected = false; };
    # A 10/8 forest and a 192.168/16 LAN don't collide.
    disjointPrivateRanges = { a = "192.168.1.0/24"; b = "10.0.0.0/24"; expected = false; };
    v6RoutedOutside = { a = "fd00::3"; b = "fd69::/64"; expected = false; };
    v6AdjacentPrefix = { a = "fd68::/16"; b = "fd69::/64"; expected = false; };

    # Cross-family never overlaps, whichever side the v6 literal is on.
    v4EntryV6Forest = { a = "10.10.0.3"; b = "fd69::/64"; expected = false; };
    v6EntryV4Forest = { a = "fd00::3"; b = "192.168.69.0/24"; expected = false; };
    # A v4 default route must not swallow the v6 forest subnet.
    v4DefaultRouteV6Forest = { a = "0.0.0.0/0"; b = "fd69::/64"; expected = false; };

    # Identical networks overlap; symmetric either way round.
    identicalSubnets = { a = "192.168.69.0/24"; b = "192.168.69.0/24"; expected = true; };
    forestInsideEntryReversed = { a = "192.168.69.0/24"; b = "192.168.0.0/16"; expected = true; };

    # Non-canonical literals (host bits set) behave as their network, because
    # both sides get masked. 192.168.12.12/16 is 192.168.0.0/16, so it covers
    # the forest; 192.168.12.12/24 is 192.168.12.0/24, so it does not.
    nonCanonicalSupernetOverlaps = { a = "192.168.12.12/16"; b = "192.168.69.0/24"; expected = true; };
    nonCanonicalNarrowDisjoint = { a = "192.168.12.12/24"; b = "192.168.69.0/24"; expected = false; };
    nonCanonicalBothSides = { a = "192.168.12.12/16"; b = "192.168.69.10/24"; expected = true; };
    v6NonCanonicalSupernet = { a = "fd69::10/16"; b = "fd69:1:2::/48"; expected = true; };

    # Overlap always means nesting: 192.168.68.0/23 covers .68 and .69, so it
    # contains the forest /24 outright; the next /23 along is fully disjoint.
    # There is no third case — a CIDR pair cannot partially overlap.
    containingSupernet23 = { a = "192.168.68.0/23"; b = "192.168.69.0/24"; expected = true; };
    adjacentSupernet23 = { a = "192.168.70.0/23"; b = "192.168.69.0/24"; expected = false; };
  };

  runOverlap = name: t:
    let actual = utils.subnetsOverlap t.a t.b;
    in {
      inherit name actual;
      inherit (t) expected;
      passed = actual == t.expected;
    };

  prefix = p: lib.mapAttrs' (n: v: lib.nameValuePair "${p}/${n}" v);
  run = fn: cases: lib.mapAttrs (runners.runStringTest fn) cases;
in {
  tests =
    prefix "generateAllowEgressRules" (run utils.generateAllowEgressRules testCasesForward)
    // prefix "generateAllowEgressNatRules/ipv4"
         (run (utils.generateAllowEgressNatRules "ipv4" "forest") testCasesNat4)
    // prefix "generateAllowEgressNatRules/ipv6"
         (run (utils.generateAllowEgressNatRules "ipv6" "forest") testCasesNat6)
    // prefix "addrInSubnet" (lib.mapAttrs runInSubnet testCasesInSubnet)
    // prefix "subnetsOverlap" (lib.mapAttrs runOverlap testCasesOverlap);
}

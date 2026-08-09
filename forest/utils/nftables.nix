{ lib }:

rec {
  # ── Generic nftables helpers ─────────────────────────────────────

  # Generate a single nftables allow rule. `protocol` may be "tcp", "udp", or "both"
  # (caller must expand "both" before this if they want it represented as separate rules).
  generateAllowRule = saddr: daddr: port: protocol: ipVersion: comment:
    let
      prefix = if ipVersion == "ipv4" then "ip" else "ip6";
      commentStr = if comment != null then " comment \"${comment}\"" else "";
    in
      "${prefix} saddr ${saddr} ${prefix} daddr ${daddr} ${protocol} dport ${toString port} counter accept${commentStr}";

  # Expand "both" protocol into separate tcp and udp entries.
  expandProtocol = entry:
    if entry.protocol == "both"
    then [
      (entry // { protocol = "tcp"; })
      (entry // { protocol = "udp"; })
    ]
    else [ entry ];

  # Group entries by source, destination, protocol, and IP version. Caller must already
  # have expanded ipVersion (saddr/daddr depend on it).
  groupEntries = entries:
    let
      expanded = lib.concatMap expandProtocol entries;
      groupKey = e: "${e.saddr}:${e.daddr}:${e.protocol}:${e.ipVersion}";
    in
      lib.groupBy groupKey expanded;

  # Render one rule covering a set of entries that share src/dst/proto/version
  # but differ only in port (collapsed into a {a, b, c} dport list).
  generateGroupedRule = entries:
    let
      first = lib.head entries;
      ports = lib.map (e: toString e.port) entries;
      portList = lib.concatStringsSep ", " ports;
      prefix = if first.ipVersion == "ipv4" then "ip" else "ip6";
      comment = if first.comment or null != null then " comment \"${first.comment}\"" else "";
    in
      "${prefix} saddr ${first.saddr} ${prefix} daddr ${first.daddr} ${first.protocol} dport { ${portList} } counter accept${comment}";

  # Generate all rules from a list of entries, grouped by connection parameters.
  # Entries must have ipVersion already as "ipv4" or "ipv6" (not "both").
  generateAllRules = entries:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (_: generateGroupedRule) (groupEntries entries));

  # ── Forest-specific helpers ──────────────────────────────────────

  # Detect IPv6 addresses by looking for a colon. Good enough for nftables literals.
  isIpv6 = ip: lib.strings.hasInfix ":" ip;

  # Split an address into its labels — octets for v4, hextets for v6 with any
  # "::" expanded back to the zero run it stands for. Any mask is dropped, so
  # a CIDR compares as its base address.
  addrLabels = a:
    let
      base = lib.head (lib.splitString "/" a);
      nonEmpty = s: lib.filter (l: l != "") (lib.splitString ":" s);
      halves = lib.splitString "::" base;
      leading = nonEmpty (lib.head halves);
      trailing = if lib.length halves > 1 then nonEmpty (lib.elemAt halves 1) else [];
      zeros = lib.genList (_: "0") (8 - lib.length leading - lib.length trailing);
    in
      if !(isIpv6 base) then lib.splitString "." base
      else if lib.length halves > 1 then leading ++ zeros ++ trailing
      else leading;

  # Is the base of `addr` inside the CIDR `subnet`?
  #
  # A mask on `addr` is stripped, so `addr` is always the single point at its
  # base. That makes
  #
  #   addrInSubnet "192.168.69.0/16" "192.168.69.0/24"  ==  true
  #
  # even though the /16 is not contained in the /24 — it contains it. This
  # answers "is base(addr) in subnet", never "is addr contained in subnet".
  # For two CIDRs you almost always want `subnetsOverlap` below.
  #
  # Both sides are masked to `subnet`'s prefix before comparing, so host bits
  # set in either literal are harmless: 192.168.12.12/16 behaves as
  # 192.168.0.0/16. Labels are parsed to numbers (so 00fd, FD and fd all
  # compare equal) and the prefix is honoured to the bit: the labels it covers
  # whole must match outright, and a prefix ending mid-label compares that
  # label under a mask of its leading bits. A maskless subnet is a single host
  # (/32, /128), so only an exact match counts.
  addrInSubnet = addr: subnet:
    let
      parts = lib.splitString "/" subnet;
      v6 = isIpv6 (lib.head parts);
      labelBits = if v6 then 16 else 8;
      prefixLen =
        if lib.length parts > 1 then lib.toInt (lib.elemAt parts 1)
        else if v6 then 128 else 32;
      pow2 = n: lib.foldl' (acc: _: acc * 2) 1 (lib.range 1 n);
      # toIntBase10, not toInt: the latter throws on a zero-padded octet
      # rather than choosing between octal and decimal, and a cryptic eval
      # error is a poor way for a guardrail to greet a typo'd address.
      toNum = l: if v6 then lib.fromHexString l else lib.toIntBase10 l;
      nums = a: lib.map toNum (addrLabels a);
      whole = prefixLen / labelBits;      # labels the prefix covers entirely
      spare = lib.mod prefixLen labelBits; # bits it takes from the next one
      # Keeps the top `spare` bits of a label, e.g. 4 spare bits of an octet
      # is 0xf0 — what separates 172.16/12 from 172.32/12.
      mask = pow2 labelBits - pow2 (labelBits - spare);
      masked = ns: builtins.bitAnd (lib.elemAt ns whole) mask;
    in
      isIpv6 addr == v6
      && lib.take whole (nums subnet) == lib.take whole (nums addr)
      && (spare == 0 || masked (nums subnet) == masked (nums addr));

  # Do these two CIDRs share any address?
  #
  # Two CIDRs are either disjoint or nested — a prefix is a node in a binary
  # trie, so partial overlap is unrepresentable. So, "they share an address" 
  # is equivalent to "the smaller is nested in the larger", 
  # which holds iff one's base lies in the other.
  subnetsOverlap = a: b: addrInSubnet a b || addrInSubnet b a;

  # Generate VM-to-VM connection rules. `connections` is a list of
  # { target, targetIP4, targetIP6, port, protocol, ipVersion } entries.
  # protocol/ipVersion may each be "both".
  generateConnectionRules = vmIP4: vmIP6: connections:
    let
      expandIpVersion = conn:
        if conn.ipVersion == "both"
        then [
          {
            inherit (conn) port protocol;
            ipVersion = "ipv4";
            saddr = vmIP4;
            daddr = conn.targetIP4;
            comment = "Allow -> ${conn.target}";
          }
          {
            inherit (conn) port protocol;
            ipVersion = "ipv6";
            saddr = vmIP6;
            daddr = conn.targetIP6;
            comment = "Allow -> ${conn.target} IPv6";
          }
        ]
        else [{
          inherit (conn) port protocol ipVersion;
          saddr = if conn.ipVersion == "ipv4" then vmIP4 else vmIP6;
          daddr = if conn.ipVersion == "ipv4" then conn.targetIP4 else conn.targetIP6;
          comment = "Allow -> ${conn.target}";
        }];
      entries = lib.concatMap expandIpVersion connections;
    in
      generateAllRules entries;

  # Per-VM DNS input rules. For each VM, for each of its configured DNS servers,
  # emit an accept rule on the input chain. Servers are detected as IPv4 vs IPv6
  # by colon presence; the source address uses the VM's matching IP family.
  generateDnsInputRules = vms:
    let
      perServer = vm: server:
        let
          prefix = if isIpv6 server then "ip6" else "ip";
          vmIp = if isIpv6 server then vm.ipv6 else vm.ipv4;
        in ''
            ${prefix} saddr ${vmIp} ${prefix} daddr ${server} udp dport 53 accept
            ${prefix} saddr ${vmIp} ${prefix} daddr ${server} tcp dport 53 accept'';
      perVm = vm:
        lib.concatStringsSep "\n" (lib.map (perServer vm) vm.dns.servers);
      nonEmpty = lib.filter (s: s != "") (lib.mapAttrsToList (_: perVm) vms);
    in
      lib.concatStringsSep "\n" nonEmpty;

  # Per-VM DNS restrict rules at the forward chain. For each restricted VM,
  # allow DNS to its configured servers (per IP version) and drop everything
  # else on port 53. Order matters: accepts must precede the catch-all drops.
  generateDnsRestrictRules = vms:
    let
      perVm = vm:
        let
          v4Servers = lib.filter (s: !isIpv6 s) vm.dns.servers;
          v6Servers = lib.filter isIpv6 vm.dns.servers;
          allowsV4 = lib.concatMap (s: [
            "ip saddr ${vm.ipv4} ip daddr ${s} udp dport 53 accept"
            "ip saddr ${vm.ipv4} ip daddr ${s} tcp dport 53 accept"
          ]) v4Servers;
          allowsV6 = lib.concatMap (s: [
            "ip6 saddr ${vm.ipv6} ip6 daddr ${s} udp dport 53 accept"
            "ip6 saddr ${vm.ipv6} ip6 daddr ${s} tcp dport 53 accept"
          ]) v6Servers;
          drops = [
            "ip saddr ${vm.ipv4} udp dport 53 drop"
            "ip saddr ${vm.ipv4} tcp dport 53 drop"
            "ip6 saddr ${vm.ipv6} udp dport 53 drop"
            "ip6 saddr ${vm.ipv6} tcp dport 53 drop"
          ];
        in
          lib.concatStringsSep "\n" (allowsV4 ++ allowsV6 ++ drops);
    in
      lib.concatStringsSep "\n" (lib.mapAttrsToList (_: perVm) vms);

  # Private IP egress is blocked, except for what `allowEgress` sets
  privateRanges4 = [
    "10.0.0.0/8"      # RFC1918 private
    "172.16.0.0/12"   # RFC1918 private
    "192.168.0.0/16"  # RFC1918 private
    "100.64.0.0/10"   # RFC6598 CGNAT (and tailnet)
    "127.0.0.0/8"     # loopback
    "169.254.0.0/16"  # link-local
    "224.0.0.0/4"     # multicast
  ];

  privateRanges6 = [
    "::1/128"    # loopback
    "fe80::/10"  # link-local
    "fc00::/7"   # ULA (unique local) (and tailnet's fd7a:115c:a1e0::/48)
    "ff00::/8"   # multicast
  ];

  generateInternetForwardRules = vms:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (_: vm: ''
            ip saddr ${vm.ipv4} ip daddr { ${lib.concatStringsSep ", " privateRanges4} } drop
            ip6 saddr ${vm.ipv6} ip6 daddr { ${lib.concatStringsSep ", " privateRanges6} } drop
            ip saddr ${vm.ipv4} accept
            ip6 saddr ${vm.ipv6} accept'') vms);

  # IPv4 NAT masquerade rules for VMs with internet access. Scoped by
  # `oifname != bridge` so the kernel's chosen egress interface is whatever
  # gets masqueraded (wifi, wg, tailscale, ...) without forcing the user to
  # name it. The negation excludes traffic looping back to the bridge —
  # though in practice VM-to-VM stays inside the bridge and never reaches
  # postrouting, the filter is cheap insurance.
  generateNat4Rules = bridge: vms:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (_: vm:
      "            ip saddr ${vm.ipv4} oifname != \"${bridge}\" masquerade"
    ) vms);

  # IPv6 equivalent.
  generateNat6Rules = bridge: vms:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (_: vm:
      "            ip6 saddr ${vm.ipv6} oifname != \"${bridge}\" masquerade"
    ) vms);

  # Forward rules for per-VM egress carveouts. `vms` is the attrset of enabled
  # VMs; each carries `.ipv4`, `.ipv6`, and `.allowEgress` (list of
  # { daddr, port, protocol }). These are placed ahead of the drops, so they
  # bypass internetAccess=false, and punch through the private range blocks.
  generateAllowEgressRules = vms:
    let
      perVm = vm:
        generateAllRules (lib.map (e:
          let v6 = isIpv6 e.daddr; in {
            inherit (e) daddr port protocol;
            ipVersion = if v6 then "ipv6" else "ipv4";
            saddr = if v6 then vm.ipv6 else vm.ipv4;
            comment = "Allow -> ${e.daddr}";
          }) vm.allowEgress);
      nonEmpty = lib.filter (s: s != "") (lib.mapAttrsToList (_: perVm) vms);
    in
      lib.concatStringsSep "\n" nonEmpty;

  # Masquerade for allowEgress destinations.
  # Only VMs *without* internetAccess=true need this since VMs with it already
  # get a blanket masquerade from generateNat{4,6}Rules.
  generateAllowEgressNatRules = family: bridge: vms:
    let
      isV6 = family == "ipv6";
      prefix = if isV6 then "ip6" else "ip";
      perVm = vm:
        lib.map (e:
          let saddr = if isV6 then vm.ipv6 else vm.ipv4;
          in "            ${prefix} saddr ${saddr} ${prefix} daddr ${e.daddr} oifname != \"${bridge}\" masquerade"
        ) (lib.filter (e: isIpv6 e.daddr == isV6) vm.allowEgress);
    in
      # Entries differing only in port collapse to the same masquerade rule.
      lib.concatStringsSep "\n" (lib.unique (lib.concatMap perVm (lib.attrValues vms)));

  # Generate prerouting DNAT rules for one IP family ("ipv4" or "ipv6").
  # `vms` is the attrset of enabled VMs; each carries `.ipv4`, `.ipv6`, and
  # `.forwardPorts` (list of { port, hostPort, protocol, interface, bindAddress }).
  #
  # bindAddress is null (caller default = both any-tokens), a string, or a list of
  # strings. Each address is classified by family via `isIpv6`; sentinels
  # "0.0.0.0" and "::" mean "any" and emit no `daddr` match. Family of the
  # whole rule is fixed by `family`; addresses of the wrong family are skipped.
  generatePortForwardRules = family: vms:
    let
      isV6 = family == "ipv6";
      famPrefix = if isV6 then "ip6" else "ip";
      isAnyAddr = addr: addr == "0.0.0.0" || addr == "::";
      coerceBindAddress = pf:
        let b = pf.bindAddress;
        in if b == null then [ "0.0.0.0" "::" ]
           else if lib.isList b then b
           else [ b ];
      expandProto = pf:
        if pf.protocol == "both"
        then [ (pf // { protocol = "tcp"; }) (pf // { protocol = "udp"; }) ]
        else [ pf ];
      perPortForward = vm: pf:
        let
          addrs = lib.filter
            (a: if isV6 then isIpv6 a else !isIpv6 a)
            (coerceBindAddress pf);
          ifacePart = if pf.interface != null then ''iifname "${pf.interface}" '' else "";
          hostPort = if pf.hostPort != null then pf.hostPort else pf.port;
          vmIp = if isV6 then vm.ipv6 else vm.ipv4;
          target = if isV6 then "[${vmIp}]:${toString pf.port}" else "${vmIp}:${toString pf.port}";
          renderOne = addr:
            let daddrPart = if isAnyAddr addr then "" else "${famPrefix} daddr ${addr} ";
            in "            ${ifacePart}${daddrPart}${pf.protocol} dport ${toString hostPort} dnat to ${target}";
        in
          lib.map renderOne addrs;
      perVm = vm:
        lib.concatMap (perPortForward vm) (lib.concatMap expandProto vm.forwardPorts);
    in
      lib.concatStringsSep "\n" (lib.concatMap perVm (lib.attrValues vms));

  # Generate VM-to-VM connection rules across the whole forest. `enabledVms`
  # is the attrset of enabled VMs; each carries `.ipv4`, `.ipv6`, and `.dependsOn`.
  generateAllVmConnectionRules = enabledVms:
    let
      perVmRules = lib.mapAttrsToList (vmName: vm:
        let
          enrichedConnections = lib.map (conn:
            let targetVm = enabledVms.${conn.target};
            in conn // {
              targetIP4 = targetVm.ipv4;
              targetIP6 = targetVm.ipv6;
            }
          ) vm.dependsOn;
        in
          generateConnectionRules vm.ipv4 vm.ipv6 enrichedConnections
      ) enabledVms;
      nonEmptyRules = lib.filter (s: s != "") perVmRules;
    in
      lib.concatStringsSep "\n" nonEmptyRules;
}

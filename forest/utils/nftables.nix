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

  # Per-VM DNS constrain rules at the forward chain. For each constrained VM,
  # allow DNS to its configured servers (per IP version) and drop everything
  # else on port 53. Order matters: accepts must precede the catch-all drops.
  generateDnsConstrainRules = vms:
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

  # Forward rules for VMs allowed to reach the public internet.
  generateInternetForwardRules = vms:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (_: vm: ''
            ip saddr ${vm.ipv4} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4 } drop
            ip6 saddr ${vm.ipv6} ip6 daddr { ::1/128, fe80::/10, fc00::/7, ff00::/8 } drop
            ip saddr ${vm.ipv4} accept
            ip6 saddr ${vm.ipv6} accept'') vms);

  # IPv4 NAT masquerade rules for VMs with internet access.
  generateNat4Rules = extIface: vms:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (_: vm:
      "            ip saddr ${vm.ipv4} oifname \"${extIface}\" masquerade"
    ) vms);

  # IPv6 NAT masquerade rules for VMs with internet access.
  generateNat6Rules = extIface: vms:
    lib.concatStringsSep "\n" (lib.mapAttrsToList (_: vm:
      "            ip6 saddr ${vm.ipv6} oifname \"${extIface}\" masquerade"
    ) vms);

  # Generate prerouting DNAT rules for one IP family ("ipv4" or "ipv6").
  # `vms` is the attrset of enabled VMs; each carries `.ipv4`, `.ipv6`, and
  # `.portForwards` (list of { port, hostPort, protocol, interface, bindAddress }).
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
        lib.concatMap (perPortForward vm) (lib.concatMap expandProto vm.portForwards);
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

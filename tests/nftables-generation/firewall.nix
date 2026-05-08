{ lib, utils, runners }:

let
  vmWith = { ipv4, ipv6, servers }: {
    inherit ipv4 ipv6;
    dns = { inherit servers; };
  };

  # ── Test fixtures ─────────────────────────────────────────────────

  # Gateway-style single-DNS-server config (matches the original input rules).
  gatewayDnsVms = {
    web = vmWith { ipv4 = "192.168.69.10"; ipv6 = "fd69::10"; servers = [ "192.168.69.1" "fd69::1" ]; };
  };
  gatewayDnsVmsMulti = {
    web = vmWith { ipv4 = "192.168.69.10"; ipv6 = "fd69::10"; servers = [ "192.168.69.1" "fd69::1" ]; };
    db  = vmWith { ipv4 = "192.168.69.11"; ipv6 = "fd69::11"; servers = [ "192.168.69.1" "fd69::1" ]; };
  };

  # Multiple DNS servers per VM (e.g. primary + secondary public resolvers).
  multipleServersVm = {
    web = vmWith { ipv4 = "192.168.69.10"; ipv6 = "fd69::10"; servers = [ "1.1.1.1" "1.0.0.1" ]; };
  };

  # Mixed v4/v6 servers — IP family matters for which saddr family we emit.
  mixedServersVm = {
    web = vmWith { ipv4 = "192.168.69.10"; ipv6 = "fd69::10"; servers = [ "1.1.1.1" "2606:4700:4700::1111" ]; };
  };

  # VM with an empty server list — emits no input or constrain rules for that VM.
  emptyServersVm = {
    web = vmWith { ipv4 = "192.168.69.10"; ipv6 = "fd69::10"; servers = [ ]; };
  };

  singleVmInternet = {
    web = { ipv4 = "192.168.69.10"; ipv6 = "fd69::10"; };
  };

  # ── generateDnsInputRules ─────────────────────────────────────────

  testCasesDnsInput = {
    singleVmGateway = {
      input = gatewayDnsVms;
      expected = ''
            ip saddr 192.168.69.10 ip daddr 192.168.69.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 192.168.69.1 tcp dport 53 accept
            ip6 saddr fd69::10 ip6 daddr fd69::1 udp dport 53 accept
            ip6 saddr fd69::10 ip6 daddr fd69::1 tcp dport 53 accept'';
    };
    multipleVmsGateway = {
      input = gatewayDnsVmsMulti;
      expected = ''
            ip saddr 192.168.69.11 ip daddr 192.168.69.1 udp dport 53 accept
            ip saddr 192.168.69.11 ip daddr 192.168.69.1 tcp dport 53 accept
            ip6 saddr fd69::11 ip6 daddr fd69::1 udp dport 53 accept
            ip6 saddr fd69::11 ip6 daddr fd69::1 tcp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 192.168.69.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 192.168.69.1 tcp dport 53 accept
            ip6 saddr fd69::10 ip6 daddr fd69::1 udp dport 53 accept
            ip6 saddr fd69::10 ip6 daddr fd69::1 tcp dport 53 accept'';
    };
    multipleServersOneVm = {
      input = multipleServersVm;
      expected = ''
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 tcp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.0.0.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.0.0.1 tcp dport 53 accept'';
    };
    mixedFamilyServers = {
      input = mixedServersVm;
      expected = ''
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 tcp dport 53 accept
            ip6 saddr fd69::10 ip6 daddr 2606:4700:4700::1111 udp dport 53 accept
            ip6 saddr fd69::10 ip6 daddr 2606:4700:4700::1111 tcp dport 53 accept'';
    };
    emptyServers = { input = emptyServersVm; expected = ""; };
    emptyVms = { input = {}; expected = ""; };
  };

  # ── generateDnsConstrainRules ────────────────────────────────────

  testCasesDnsConstrain = {
    singleV4Server = {
      input = {
        web = vmWith { ipv4 = "192.168.69.10"; ipv6 = "fd69::10"; servers = [ "1.1.1.1" ]; };
      };
      expected = ''
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 tcp dport 53 accept
            ip saddr 192.168.69.10 udp dport 53 drop
            ip saddr 192.168.69.10 tcp dport 53 drop
            ip6 saddr fd69::10 udp dport 53 drop
            ip6 saddr fd69::10 tcp dport 53 drop'';
    };
    mixedFamilyServers = {
      input = mixedServersVm;
      expected = ''
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 tcp dport 53 accept
            ip6 saddr fd69::10 ip6 daddr 2606:4700:4700::1111 udp dport 53 accept
            ip6 saddr fd69::10 ip6 daddr 2606:4700:4700::1111 tcp dport 53 accept
            ip saddr 192.168.69.10 udp dport 53 drop
            ip saddr 192.168.69.10 tcp dport 53 drop
            ip6 saddr fd69::10 udp dport 53 drop
            ip6 saddr fd69::10 tcp dport 53 drop'';
    };
    multipleV4Servers = {
      input = multipleServersVm;
      expected = ''
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.1.1.1 tcp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.0.0.1 udp dport 53 accept
            ip saddr 192.168.69.10 ip daddr 1.0.0.1 tcp dport 53 accept
            ip saddr 192.168.69.10 udp dport 53 drop
            ip saddr 192.168.69.10 tcp dport 53 drop
            ip6 saddr fd69::10 udp dport 53 drop
            ip6 saddr fd69::10 tcp dport 53 drop'';
    };
    emptyServers = {
      # No allow rules, just the catch-all drops — locks the VM out of all DNS.
      input = emptyServersVm;
      expected = ''
            ip saddr 192.168.69.10 udp dport 53 drop
            ip saddr 192.168.69.10 tcp dport 53 drop
            ip6 saddr fd69::10 udp dport 53 drop
            ip6 saddr fd69::10 tcp dport 53 drop'';
    };
    noConstrainedVms = { input = {}; expected = ""; };
  };

  # ── generateInternetForwardRules / NAT (unchanged sigs) ──────────

  testCasesForward = {
    singleVm = {
      input = singleVmInternet;
      expected = ''
            ip saddr 192.168.69.10 ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4 } drop
            ip6 saddr fd69::10 ip6 daddr { ::1/128, fe80::/10, fc00::/7, ff00::/8 } drop
            ip saddr 192.168.69.10 accept
            ip6 saddr fd69::10 accept'';
    };
    empty = { input = {}; expected = ""; };
  };

  testCasesNat4 = {
    singleVm = {
      input = singleVmInternet;
      expected = "            ip saddr 192.168.69.10 oifname \"enp5s0\" masquerade";
    };
    empty = { input = {}; expected = ""; };
  };

  testCasesNat6 = {
    singleVm = {
      input = singleVmInternet;
      expected = "            ip6 saddr fd69::10 oifname \"enp5s0\" masquerade";
    };
    empty = { input = {}; expected = ""; };
  };
in {
  generateDnsInputRules =
    lib.mapAttrs (runners.runStringTest utils.generateDnsInputRules) testCasesDnsInput;
  generateDnsConstrainRules =
    lib.mapAttrs (runners.runStringTest utils.generateDnsConstrainRules) testCasesDnsConstrain;
  generateInternetForwardRules =
    lib.mapAttrs (runners.runStringTest utils.generateInternetForwardRules) testCasesForward;
  generateNat4Rules =
    lib.mapAttrs (runners.runStringTest (utils.generateNat4Rules "enp5s0")) testCasesNat4;
  generateNat6Rules =
    lib.mapAttrs (runners.runStringTest (utils.generateNat6Rules "enp5s0")) testCasesNat6;
}

{ lib, utils, runners, ... }:

let
  testCases = {
    basicTcp = {
      input = {
        saddr = "192.168.1.10"; daddr = "192.168.1.20";
        port = 80; protocol = "tcp"; ipVersion = "ipv4";
        comment = "Allow HTTP";
      };
      expected = ''ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport 80 counter accept comment "Allow HTTP"'';
    };
    udpIpv6 = {
      input = {
        saddr = "fd00::10"; daddr = "fd00::20";
        port = 53; protocol = "udp"; ipVersion = "ipv6";
        comment = "DNS";
      };
      expected = ''ip6 saddr fd00::10 ip6 daddr fd00::20 udp dport 53 counter accept comment "DNS"'';
    };
    noComment = {
      input = {
        saddr = "10.0.0.1"; daddr = "10.0.0.2";
        port = 443; protocol = "tcp"; ipVersion = "ipv4";
        comment = null;
      };
      expected = ''ip saddr 10.0.0.1 ip daddr 10.0.0.2 tcp dport 443 counter accept'';
    };
  };

  runAllowRule = name: test:
    let
      actual = utils.generateAllowRule
        test.input.saddr test.input.daddr test.input.port
        test.input.protocol test.input.ipVersion test.input.comment;
    in {
      inherit name actual;
      inherit (test) expected;
      passed = lib.trim actual == lib.trim test.expected;
    };
in {
  generateAllowRule = lib.mapAttrs runAllowRule testCases;
}

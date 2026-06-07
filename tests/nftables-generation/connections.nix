{ lib, utils, runners, ... }:

let
  testCases = {
    empty = {
      vmIP4 = "192.168.123.10"; vmIP6 = "fd00::10";
      input = []; expected = "";
    };
    singleSpecific = {
      vmIP4 = "192.168.123.10"; vmIP6 = "fd00::10";
      input = [{
        target = "db";
        targetIP4 = "192.168.123.11"; targetIP6 = "fd00::11";
        port = 5432; protocol = "tcp"; ipVersion = "ipv4";
      }];
      expected = ''ip saddr 192.168.123.10 ip daddr 192.168.123.11 tcp dport { 5432 } counter accept comment "Allow -> db"'';
    };
    bothProtocol = {
      vmIP4 = "192.168.123.10"; vmIP6 = "fd00::10";
      input = [{
        target = "redis";
        targetIP4 = "192.168.123.12"; targetIP6 = "fd00::12";
        port = 6379; protocol = "both"; ipVersion = "ipv4";
      }];
      expected = ''
        ip saddr 192.168.123.10 ip daddr 192.168.123.12 tcp dport { 6379 } counter accept comment "Allow -> redis"
        ip saddr 192.168.123.10 ip daddr 192.168.123.12 udp dport { 6379 } counter accept comment "Allow -> redis"'';
    };
    bothIpVersion = {
      vmIP4 = "192.168.123.20"; vmIP6 = "fd00::20";
      input = [{
        target = "cache";
        targetIP4 = "192.168.123.13"; targetIP6 = "fd00::13";
        port = 11211; protocol = "tcp"; ipVersion = "both";
      }];
      expected = ''
        ip saddr 192.168.123.20 ip daddr 192.168.123.13 tcp dport { 11211 } counter accept comment "Allow -> cache"
        ip6 saddr fd00::20 ip6 daddr fd00::13 tcp dport { 11211 } counter accept comment "Allow -> cache IPv6"'';
    };
    bothBoth = {
      vmIP4 = "192.168.123.10"; vmIP6 = "fd00::10";
      input = [{
        target = "dns";
        targetIP4 = "192.168.123.14"; targetIP6 = "fd00::14";
        port = 53; protocol = "both"; ipVersion = "both";
      }];
      expected = ''
        ip saddr 192.168.123.10 ip daddr 192.168.123.14 tcp dport { 53 } counter accept comment "Allow -> dns"
        ip saddr 192.168.123.10 ip daddr 192.168.123.14 udp dport { 53 } counter accept comment "Allow -> dns"
        ip6 saddr fd00::10 ip6 daddr fd00::14 tcp dport { 53 } counter accept comment "Allow -> dns IPv6"
        ip6 saddr fd00::10 ip6 daddr fd00::14 udp dport { 53 } counter accept comment "Allow -> dns IPv6"'';
    };
    multiplePortsSameTarget = {
      vmIP4 = "10.0.0.5"; vmIP6 = "fc00::5";
      input = [
        { target = "web"; targetIP4 = "10.0.0.15"; targetIP6 = "fc00::15"; port = 80;  protocol = "tcp"; ipVersion = "ipv4"; }
        { target = "web"; targetIP4 = "10.0.0.15"; targetIP6 = "fc00::15"; port = 443; protocol = "tcp"; ipVersion = "ipv4"; }
      ];
      expected = ''ip saddr 10.0.0.5 ip daddr 10.0.0.15 tcp dport { 80, 443 } counter accept comment "Allow -> web"'';
    };
    multipleDifferentTargets = {
      vmIP4 = "192.168.123.10"; vmIP6 = "fd00::10";
      input = [
        { target = "db";    targetIP4 = "192.168.123.11"; targetIP6 = "fd00::11"; port = 5432; protocol = "tcp"; ipVersion = "ipv4"; }
        { target = "cache"; targetIP4 = "192.168.123.12"; targetIP6 = "fd00::12"; port = 6379; protocol = "tcp"; ipVersion = "ipv4"; }
      ];
      expected = ''
        ip saddr 192.168.123.10 ip daddr 192.168.123.11 tcp dport { 5432 } counter accept comment "Allow -> db"
        ip saddr 192.168.123.10 ip daddr 192.168.123.12 tcp dport { 6379 } counter accept comment "Allow -> cache"'';
    };
  };

  runConnectionRules = name: test:
    let actual = utils.generateConnectionRules test.vmIP4 test.vmIP6 test.input;
    in {
      inherit name actual;
      inherit (test) expected;
      passed = runners.normalize actual == runners.normalize test.expected;
    };
in {
  tests = lib.mapAttrs runConnectionRules testCases;
}

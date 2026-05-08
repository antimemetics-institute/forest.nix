{ lib, utils, runners }:

let
  testCases = {
    empty = {
      input = [];
      expected = "";
    };
    single = {
      input = [{
        saddr = "192.168.1.10"; daddr = "192.168.1.20";
        port = 80; protocol = "tcp"; ipVersion = "ipv4";
        comment = "HTTP";
      }];
      expected = ''ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 80 } counter accept comment "HTTP"'';
    };
    multiplePortsGrouped = {
      input = [
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 80; protocol = "tcp"; ipVersion = "ipv4"; comment = "Web"; }
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 443; protocol = "tcp"; ipVersion = "ipv4"; comment = "Web"; }
      ];
      expected = ''ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 80, 443 } counter accept comment "Web"'';
    };
    expandBothProtocol = {
      input = [{
        saddr = "192.168.1.10"; daddr = "192.168.1.20";
        port = 53; protocol = "both"; ipVersion = "ipv4";
        comment = "DNS";
      }];
      expected = ''
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 53 } counter accept comment "DNS"
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 udp dport { 53 } counter accept comment "DNS"'';
    };
    differentSaddr = {
      input = [
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 80; protocol = "tcp"; ipVersion = "ipv4"; }
        { saddr = "192.168.1.11"; daddr = "192.168.1.20"; port = 80; protocol = "tcp"; ipVersion = "ipv4"; }
      ];
      expected = ''
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 80 } counter accept
        ip saddr 192.168.1.11 ip daddr 192.168.1.20 tcp dport { 80 } counter accept'';
    };
    differentDaddr = {
      input = [
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 80; protocol = "tcp"; ipVersion = "ipv4"; }
        { saddr = "192.168.1.10"; daddr = "192.168.1.21"; port = 80; protocol = "tcp"; ipVersion = "ipv4"; }
      ];
      expected = ''
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 80 } counter accept
        ip saddr 192.168.1.10 ip daddr 192.168.1.21 tcp dport { 80 } counter accept'';
    };
    differentProtocol = {
      input = [
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 53; protocol = "tcp"; ipVersion = "ipv4"; }
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 53; protocol = "udp"; ipVersion = "ipv4"; }
      ];
      expected = ''
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 53 } counter accept
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 udp dport { 53 } counter accept'';
    };
    differentIpVersion = {
      input = [
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 80; protocol = "tcp"; ipVersion = "ipv4"; }
        { saddr = "fd00::10"; daddr = "fd00::20"; port = 80; protocol = "tcp"; ipVersion = "ipv6"; }
      ];
      expected = ''
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 80 } counter accept
        ip6 saddr fd00::10 ip6 daddr fd00::20 tcp dport { 80 } counter accept'';
    };
    multipleBothProtocol = {
      input = [
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 53; protocol = "both"; ipVersion = "ipv4"; }
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 5353; protocol = "both"; ipVersion = "ipv4"; }
      ];
      expected = ''
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 53, 5353 } counter accept
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 udp dport { 53, 5353 } counter accept'';
    };
    complexMix = {
      input = [
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 80; protocol = "tcp"; ipVersion = "ipv4"; comment = "HTTP"; }
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 443; protocol = "tcp"; ipVersion = "ipv4"; comment = "HTTP"; }
        { saddr = "192.168.1.10"; daddr = "192.168.1.20"; port = 53; protocol = "udp"; ipVersion = "ipv4"; comment = "DNS"; }
        { saddr = "fd00::10"; daddr = "fd00::20"; port = 443; protocol = "tcp"; ipVersion = "ipv6"; comment = "HTTPS"; }
      ];
      expected = ''
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 tcp dport { 80, 443 } counter accept comment "HTTP"
        ip saddr 192.168.1.10 ip daddr 192.168.1.20 udp dport { 53 } counter accept comment "DNS"
        ip6 saddr fd00::10 ip6 daddr fd00::20 tcp dport { 443 } counter accept comment "HTTPS"'';
    };
  };
in {
  generateAllRules = lib.mapAttrs (runners.runStringTest utils.generateAllRules) testCases;
}

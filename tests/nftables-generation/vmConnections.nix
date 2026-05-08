{ lib, utils, runners }:

let
  testCases = {
    noDeps = {
      input = {
        vm1 = { ipv4 = "192.168.123.10"; ipv6 = "fd00::10"; dependsOn = []; };
        vm2 = { ipv4 = "192.168.123.11"; ipv6 = "fd00::11"; dependsOn = []; };
      };
      expected = "";
    };
    singleDep = {
      input = {
        web = {
          ipv4 = "192.168.123.10"; ipv6 = "fd00::10";
          dependsOn = [{ target = "db"; port = 5432; protocol = "tcp"; ipVersion = "ipv4"; }];
        };
        db = { ipv4 = "192.168.123.11"; ipv6 = "fd00::11"; dependsOn = []; };
      };
      expected = ''ip saddr 192.168.123.10 ip daddr 192.168.123.11 tcp dport { 5432 } counter accept comment "Allow -> db"'';
    };
    multipleDeps = {
      input = {
        api = {
          ipv4 = "192.168.123.10"; ipv6 = "fd00::10";
          dependsOn = [
            { target = "db";    port = 5432; protocol = "tcp"; ipVersion = "ipv4"; }
            { target = "cache"; port = 6379; protocol = "tcp"; ipVersion = "ipv4"; }
          ];
        };
        db    = { ipv4 = "192.168.123.11"; ipv6 = "fd00::11"; dependsOn = []; };
        cache = { ipv4 = "192.168.123.12"; ipv6 = "fd00::12"; dependsOn = []; };
      };
      expected = ''
        ip saddr 192.168.123.10 ip daddr 192.168.123.11 tcp dport { 5432 } counter accept comment "Allow -> db"
        ip saddr 192.168.123.10 ip daddr 192.168.123.12 tcp dport { 6379 } counter accept comment "Allow -> cache"'';
    };
    chainDeps = {
      input = {
        web = {
          ipv4 = "192.168.123.10"; ipv6 = "fd00::10";
          dependsOn = [{ target = "api"; port = 8080; protocol = "tcp"; ipVersion = "both"; }];
        };
        api = {
          ipv4 = "192.168.123.11"; ipv6 = "fd00::11";
          dependsOn = [{ target = "db"; port = 5432; protocol = "tcp"; ipVersion = "both"; }];
        };
        db = { ipv4 = "192.168.123.12"; ipv6 = "fd00::12"; dependsOn = []; };
      };
      expected = ''
        ip saddr 192.168.123.11 ip daddr 192.168.123.12 tcp dport { 5432 } counter accept comment "Allow -> db"
        ip6 saddr fd00::11 ip6 daddr fd00::12 tcp dport { 5432 } counter accept comment "Allow -> db IPv6"
        ip saddr 192.168.123.10 ip daddr 192.168.123.11 tcp dport { 8080 } counter accept comment "Allow -> api"
        ip6 saddr fd00::10 ip6 daddr fd00::11 tcp dport { 8080 } counter accept comment "Allow -> api IPv6"'';
    };
    multiplePortsSameTarget = {
      input = {
        web = {
          ipv4 = "192.168.123.10"; ipv6 = "fd00::10";
          dependsOn = [
            { target = "api"; port = 8080; protocol = "tcp"; ipVersion = "ipv4"; }
            { target = "api"; port = 8443; protocol = "tcp"; ipVersion = "ipv4"; }
          ];
        };
        api = { ipv4 = "192.168.123.11"; ipv6 = "fd00::11"; dependsOn = []; };
      };
      expected = ''ip saddr 192.168.123.10 ip daddr 192.168.123.11 tcp dport { 8080, 8443 } counter accept comment "Allow -> api"'';
    };
    bothProtocol = {
      input = {
        app = {
          ipv4 = "192.168.123.10"; ipv6 = "fd00::10";
          dependsOn = [{ target = "dns"; port = 53; protocol = "both"; ipVersion = "ipv4"; }];
        };
        dns = { ipv4 = "192.168.123.11"; ipv6 = "fd00::11"; dependsOn = []; };
      };
      expected = ''
        ip saddr 192.168.123.10 ip daddr 192.168.123.11 tcp dport { 53 } counter accept comment "Allow -> dns"
        ip saddr 192.168.123.10 ip daddr 192.168.123.11 udp dport { 53 } counter accept comment "Allow -> dns"'';
    };
  };
in {
  generateAllVmConnectionRules =
    lib.mapAttrs (runners.runStringTest utils.generateAllVmConnectionRules) testCases;
}

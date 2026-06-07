{ lib, utils, runners, ... }:

let
  # Helper to build a VM fixture; defaults match the option defaults so each
  # test only mentions the fields it cares about.
  pf = args: {
    port = args.port or 22;
    hostPort = args.hostPort or null;
    protocol = args.protocol or "tcp";
    interface = args.interface or null;
    bindAddress = args.bindAddress or null;
  };
  vm = { ipv4, ipv6, forwardPorts ? [] }: { inherit ipv4 ipv6 forwardPorts; };

  dev = { ipv4 = "192.168.69.10"; ipv6 = "fd69::10"; };
  db  = { ipv4 = "192.168.69.11"; ipv6 = "fd69::11"; };

  # ── IPv4 cases ───────────────────────────────────────────────────

  testCasesV4 = {
    empty = { input = {}; expected = ""; };

    noForwardPorts = {
      input = { dev = vm dev; };
      expected = "";
    };

    interfaceOnlyDefaultsBoth = {
      # No bindAddress → defaults to [ "0.0.0.0" "::" ]; only v4 emits in v4 family.
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { interface = "tailscale0"; }) ]; });
      };
      expected = ''            iifname "tailscale0" tcp dport 22 dnat to 192.168.69.10:22'';
    };

    interfaceWithV4Sentinel = {
      # Explicit "0.0.0.0" — same v4 output, but v6 emits nothing (see v6 tests).
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { interface = "tailscale0"; bindAddress = "0.0.0.0"; }) ]; });
      };
      expected = ''            iifname "tailscale0" tcp dport 22 dnat to 192.168.69.10:22'';
    };

    interfaceWithV6SentinelOnly = {
      # bindAddress = "::" → v4 family emits nothing.
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { interface = "tailscale0"; bindAddress = "::"; }) ]; });
      };
      expected = "";
    };

    specificV4BindAddress = {
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { port = 80; hostPort = 8080; protocol = "tcp"; bindAddress = "203.0.113.5"; }) ]; });
      };
      expected = ''            ip daddr 203.0.113.5 tcp dport 8080 dnat to 192.168.69.10:80'';
    };

    interfaceAndSpecificV4 = {
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { port = 22; interface = "wg0"; bindAddress = "10.0.0.1"; }) ]; });
      };
      expected = ''            iifname "wg0" ip daddr 10.0.0.1 tcp dport 22 dnat to 192.168.69.10:22'';
    };

    mixedListBindAddress = {
      # List with one v4 + one v6; v4 family only emits the v4 entry.
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { interface = "tailscale0"; bindAddress = [ "100.64.0.1" "fd7a:115c::1" ]; }) ]; });
      };
      expected = ''            iifname "tailscale0" ip daddr 100.64.0.1 tcp dport 22 dnat to 192.168.69.10:22'';
    };

    protocolBothExpands = {
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { protocol = "both"; interface = "tailscale0"; }) ]; });
      };
      expected =
        "            iifname \"tailscale0\" tcp dport 22 dnat to 192.168.69.10:22\n"
        + "            iifname \"tailscale0\" udp dport 22 dnat to 192.168.69.10:22";
    };

    multipleVms = {
      input = {
        db  = vm (db  // { forwardPorts = [ (pf { port = 5432; protocol = "tcp"; interface = "wg0"; }) ]; });
        dev = vm (dev // { forwardPorts = [ (pf { port = 22; protocol = "tcp"; interface = "tailscale0"; }) ]; });
      };
      expected =
        "            iifname \"wg0\" tcp dport 5432 dnat to 192.168.69.11:5432\n"
        + "            iifname \"tailscale0\" tcp dport 22 dnat to 192.168.69.10:22";
    };
  };

  # ── IPv6 cases ───────────────────────────────────────────────────

  testCasesV6 = {
    empty = { input = {}; expected = ""; };

    interfaceOnlyDefaultsBoth = {
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { interface = "tailscale0"; }) ]; });
      };
      expected = ''            iifname "tailscale0" tcp dport 22 dnat to [fd69::10]:22'';
    };

    interfaceWithV4SentinelOnly = {
      # bindAddress = "0.0.0.0" classifies as v4 → v6 family emits nothing.
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { interface = "tailscale0"; bindAddress = "0.0.0.0"; }) ]; });
      };
      expected = "";
    };

    interfaceWithV6Sentinel = {
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { interface = "tailscale0"; bindAddress = "::"; }) ]; });
      };
      expected = ''            iifname "tailscale0" tcp dport 22 dnat to [fd69::10]:22'';
    };

    specificV6BindAddress = {
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { port = 80; hostPort = 8080; bindAddress = "fd7a:115c::1"; }) ]; });
      };
      expected = ''            ip6 daddr fd7a:115c::1 tcp dport 8080 dnat to [fd69::10]:80'';
    };

    mixedListBindAddress = {
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { interface = "tailscale0"; bindAddress = [ "100.64.0.1" "fd7a:115c::1" ]; }) ]; });
      };
      expected = ''            iifname "tailscale0" ip6 daddr fd7a:115c::1 tcp dport 22 dnat to [fd69::10]:22'';
    };

    protocolBothExpandsV6 = {
      input = {
        dev = vm (dev // { forwardPorts = [ (pf { protocol = "both"; interface = "tailscale0"; }) ]; });
      };
      expected =
        "            iifname \"tailscale0\" tcp dport 22 dnat to [fd69::10]:22\n"
        + "            iifname \"tailscale0\" udp dport 22 dnat to [fd69::10]:22";
    };
  };
  prefix = p: lib.mapAttrs' (n: v: lib.nameValuePair "${p}/${n}" v);
  run = ipVersion: lib.mapAttrs (runners.runStringTest (utils.generatePortForwardRules ipVersion));
in {
  tests =
    prefix "generatePortForwardRulesV4" (run "ipv4" testCasesV4)
    // prefix "generatePortForwardRulesV6" (run "ipv6" testCasesV6);
}

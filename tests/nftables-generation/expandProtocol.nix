{ lib, utils, runners }:

let
  testCases = {
    expandBoth = {
      input = { port = 80; protocol = "both"; saddr = "192.168.1.10"; };
      expected = [
        { port = 80; protocol = "tcp"; saddr = "192.168.1.10"; }
        { port = 80; protocol = "udp"; saddr = "192.168.1.10"; }
      ];
    };
    singleTcp = {
      input = { port = 80; protocol = "tcp"; saddr = "192.168.1.10"; };
      expected = [
        { port = 80; protocol = "tcp"; saddr = "192.168.1.10"; }
      ];
    };
  };

  runExpandProtocol = name: test:
    let actual = utils.expandProtocol test.input;
    in {
      inherit name actual;
      inherit (test) expected;
      passed = actual == test.expected;
    };
in {
  expandProtocol = lib.mapAttrs runExpandProtocol testCases;
}

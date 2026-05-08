# forest.nix

Easy declarative microvm-backed virtual machines for NixOS. A thin opinionated layer over [microvm.nix](https://github.com/microvm-nix/microvm.nix) that wires up networking, NAT, per-VM firewalling, persistent state, SSH host keys, and a small CLI — so a VM definition fits in a handful of lines.

```nix
forest.vms.web = {
  index = 0;
  config = { ... }: {
    services.nginx.enable = true;
  };
};
```

## Status

Pre-1.0. APIs may shift. Please open issues with feedback.

## Quick start

Add forest as a flake input:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    forest.url = "github:raphaelfrancis/forest.nix";
  };

  outputs = { self, nixpkgs, forest, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        forest.nixosModules.default
        ./host.nix
      ];
    };
  };
}
```

Then in `host.nix`:

```nix
{ ... }: {
  # IP forwarding is required for VMs to reach the internet via NAT.
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  forest = {
    externalInterface = "enp5s0";  # your physical/wifi interface

    vms.web = {
      index = 0;
      config = { ... }: {
        services.nginx.enable = true;
        networking.firewall.allowedTCPPorts = [ 80 ];
      };
    };
  };
}
```

Rebuild your host. forest creates the bridge, NAT rules, and starts `microvm@web`. The CLI is available as `forest`.

## The forest CLI

```
forest list                  # all forest VMs and their state
forest status   <vm>         # systemd status
forest up       <vm>         # start
forest down     <vm>         # stop
forest restart  <vm>         # restart
forest logs     <vm>         # journalctl -u microvm@<vm>
forest journal  <vm>         # the VM's own journal
```

Tab-completion is installed for bash.

## Networking model

- Every VM gets a stable IPv4 (`192.168.69.{10+index}`), IPv6 (`fd69::{10+index}`), MAC, and vsock CID derived from its `index`. Indices must be unique. Range: 0–244.
- VMs sit on a bridge (`forest` by default). The host is the gateway at `192.168.69.1` / `fd69::1`.
- The host's nftables policy is **default-deny for inter-VM traffic**: a VM cannot reach another VM unless it declares a `dependsOn` entry. Internet access is gated per-VM by `internetAccess` (default `true`).

### Inter-VM dependencies

```nix
forest.vms.web = {
  index = 0;
  dependsOn = [
    { target = "db";    port = 5432; protocol = "tcp"; ipVersion = "both"; }
    { target = "cache"; port = 6379; protocol = "tcp"; }
  ];
  config = { ... }: { /* ... */ };
};
```

This generates the matching firewall accept rules. Connection tracking handles return traffic.

### DNS

By default each VM is configured with the host's declared `networking.nameservers` (or `1.1.1.1` / `1.0.0.1` if none are set), and DNS to any other destination is **not** blocked.

To force a VM to only resolve via specific servers:

```nix
forest.vms.foo.dns = {
  servers = [ "10.0.0.53" ];
  constrain = true;          # drop DNS to anywhere else at the firewall
};
```

Global defaults live under `forest.dns.{servers,constrain}` and are inherited by every VM unless overridden.

## Per-VM options

| option            | type         | default                         | description                                       |
|-------------------|--------------|---------------------------------|---------------------------------------------------|
| `enable`          | bool         | `true`                          | Whether this VM is part of the forest.            |
| `index`           | int          | _required_                      | Unique stable index (0–244).                      |
| `hypervisor`      | str          | `"cloud-hypervisor"`            | Any microvm-supported hypervisor.                 |
| `memory`          | int (MB)     | `2048`                          | Memory allocation.                                |
| `vcpu`            | int          | `4`                             | Number of vCPUs.                                  |
| `stateVersion`    | str          | `"25.11"`                       | `system.stateVersion` for the VM.                 |
| `config`          | module       | _required_                      | NixOS module for the VM.                          |
| `internetAccess`  | bool         | `true`                          | Allow public internet via host NAT.               |
| `dns.servers`     | list of str  | `forest.dns.servers`            | DNS servers configured in the VM.                 |
| `dns.constrain`   | bool         | `forest.dns.constrain`          | Drop DNS to anything outside `dns.servers`.       |
| `dependsOn`       | list         | `[]`                            | Allowed outbound connections to other VMs.        |
| `ssh.users`       | list         | `[]`                            | Create users with SSH access (opens sshd).        |
| `sops`            | submodule    | disabled                        | Per-VM sops-nix integration.                      |

The readonly fields `tapInterface`, `ipv4`, `ipv6`, `macAddress`, `vsockCid` are derived from `index`.

## Top-level options

| option              | type        | default                         |
|---------------------|-------------|---------------------------------|
| `enable`            | bool        | `true`                          |
| `vms`               | attrs       | `{}`                            |
| `commonConfig`      | module      | `{}`                            |
| `externalInterface` | str         | _required_                      |
| `vmSubnet`          | str         | `"192.168.69.0/24"`             |
| `vmSubnet6`         | str         | `"fd69::/64"`                   |
| `vmGateway`         | str         | `"192.168.69.1"`                |
| `vmGateway6`        | str         | `"fd69::1"`                     |
| `bridgeInterface`   | str         | `"forest"`                      |
| `dns.servers`       | list of str | host's `networking.nameservers` |
| `dns.constrain`     | bool        | `false`                         |

### `commonConfig`

A module merged into every VM. Use this for cross-cutting concerns:

```nix
forest.commonConfig = { pkgs, ... }: {
  imports = [ ./vm-base.nix ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  environment.systemPackages = [ pkgs.htop ];
};
```

## SSH into a VM

The simplest path is to declare users on the VM:

```nix
forest.vms.web.ssh.users = [{
  name = "alice";
  sshKeys = [ "ssh-ed25519 AAAA..." ];
}];
```

This creates the user, opens sshd to the bridge, and disables password auth. From the host you can reach the VM at `web.forest.local` (entries are added to `/etc/hosts` for both host and guests).

The microvm runner also supports vsock SSH (`microvm -s <name>`) which works without networking.

## Persistent state

Each VM has three persistent virtiofs shares:

| guest path           | host path                              | purpose                                 |
|----------------------|----------------------------------------|-----------------------------------------|
| `/home`              | `/var/lib/microvms/<vm>/home`          | user homes                              |
| `/var/log`           | `/var/lib/microvms/<vm>/logs`          | journals + logs                         |
| `/var/lib/host-keys` | `/var/lib/microvms/<vm>/host-keys`     | SSH host keys (stable VM identity)      |

The host's `/nix/store` is shared read-only. `system.stateVersion` is pinned per VM via `stateVersion`.

## Secrets (sops-nix)

```nix
forest.vms.foo = {
  index = 1;
  sops = {
    enable = true;
    defaultSopsFile = ./secrets/foo.yaml;
  };
  config = { ... }: {
    sops.secrets.api_token = {};
    # ...
  };
};
```

The VM's persistent SSH host key is used as the age identity for sops. To enroll a freshly-created VM:

```sh
ssh-keyscan <vm-ip> | ssh-to-age   # add this age public key to .sops.yaml
```

## Tests

Unit tests for the nftables rule generators:

```sh
nix flake check
# or:
nix-instantiate --eval ./tests -A summary
```

## Architecture notes

- One nftables `inet` table (`forest_filter`) holds the input + forward chains. Two NAT tables (`forest_nat`, `forest_nat6`) handle masquerade. Rules are generated per-VM from `forest/utils.nix`.
- `forest.commonConfig` is implemented as a `deferredModule` and prepended to each VM's `imports` list, before the user's `vm.config`.
- The CLI lives in `forest/cli.nix` + `forest/forest.sh` + `forest/completion.bash`. The script is shellcheck-clean (enforced by `pkgs.writeShellApplication`).

## License

MIT.

# forest.nix

Simple nix virtual machines. A thin opinionated layer over [microvm.nix](https://github.com/microvm-nix/microvm.nix) that wires up networking, a writable nix store, sops secrets, and a small CLI.

```nix
{
  forest.vms.dev = {
    cores = 4;
    memorySize = 4096;
    ssh.users.dev.sshKeys = [ ... ];
    forwardPorts = [
      { port = 22; hostPort = 2222; protocol = "tcp"; interface = "tailscale0"; }
    ];
    config = { pkgs, ... }: {

      environment.systemPackages = [
        pkgs.dig
        pkgs.tmux
        pkgs.git
        pkgs.claude-code
      ];

    };
  };
}
```

## Status

We early, APIs may shift.

Things we could add if people want them:
- [ ] cloud-hypervisor graphics
- [ ] MacOS support
- [ ] support for `sudo` alternatives in the CLI
- [ ] idk, let me know

Open an issue if you want a feature.

## Setup

<details>
<summary><b>Flake</b></summary>

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    forest = {
      url = "github:antimemetics-institute/forest.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, forest, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        forest.nixosModules.default
      ];
    };
  };
}
```

</details>

<details>
<summary><b>npins</b></summary>

```sh
npins add github antimemetics-institute forest.nix
```

```nix
# /etc/nixos/configuration.nix
{ ... }:
let
  sources = import ./npins;
in {
  imports = [
    (import sources."forest.nix" {})
  ];
}
```

</details>

<details>
<summary><b>tack</b></summary>

```sh
tack add forest.nix github:antimemetics-institute/forest.nix --fetch
```

```nix
# /etc/nixos/configuration.nix
{ ... }:
let
  inputs = import ./tack;
in {
  imports = [
    (import inputs."forest.nix" {})
  ];
}
```

</details>

<details>
<summary><b>fetcher</b></summary>

```nix
# /etc/nixos/configuration.nix
{ ... }: {
  imports = [
    (import (builtins.fetchTarball {
      url    = "https://github.com/antimemetics-institute/forest.nix/archive/<rev>.tar.gz";
      sha256 = "...";
    }) {})
  ];
}
```

</details>

## CLI

```
forest list                       # all forest VMs and their state
forest status   <vm>              # systemd status
forest up       <vm>              # start
forest down     <vm>              # stop
forest restart  <vm>              # restart
forest logs     <vm> [args...]    # journalctl -u microvm@<vm> (extra args go to journalctl, e.g. -f)
forest journal  <vm> [args...]    # the VM's own journal (extra args go to journalctl, e.g. -b 0)
```

Tab-completion is installed for bash.

## Per-VM options

`forest.vms.<name>` is an attrset of VMs. Each VM exposes:

| option             | type              | default                     | description                                                                                                |
|--------------------|-------------------|-----------------------------|------------------------------------------------------------------------------------------------------------|
| `enable`           | bool              | `true`                      | Whether this VM is part of the forest.                                                                     |
| `index`            | int or null       | `null` (auto)               | Stable slot (0–244) controlling IP/MAC/CID. See [Networking](#networking).                                 |
| `hypervisor`       | str               | `"cloud-hypervisor"`        | Any microvm-supported hypervisor. `"qemu"` is required for [PCI passthrough](#gpu--pci-passthrough).       |
| `memorySize`       | int (MB)          | `2048`                      | Memory allocation.                                                                                         |
| `cores`            | int               | `4`                         | vCPU count.                                                                                                |
| `stateVersion`     | str               | `"25.11"`                   | `system.stateVersion` for the VM.                                                                          |
| `writableStore`    | bool              | `true`                      | Writable nix store overlay; wiped on each start. See [Persistent state](#persistent-state).                |
| `config`           | module            | _required_                  | NixOS module for the VM.                                                                                   |
| `internetAccess`   | bool              | `true`                      | Allow public internet via host NAT.                                                                        |
| `dependsOn`        | list              | `[]`                        | Allowed outbound connections to other VMs. See [Inter-VM dependencies](#inter-vm-dependencies).            |
| `forwardPorts`     | list              | `[]`                        | Inbound DNAT into the VM. See [Inbound port forwards](#inbound-port-forwards).                             |
| `dns.servers`      | list of str       | `[ vmGateway, vmGateway6 ]` | DNS servers the VM resolves through. See [DNS](#dns).                                                      |
| `dns.restrict`     | bool              | `false`                     | Drop DNS to anything outside `dns.servers`.                                                                |
| `ssh.users`        | attrs             | `{}`                        | Create users with SSH access; opens sshd. See [SSH access](#ssh-access).                                   |
| `sops`             | submodule         | disabled                    | Per-VM sops-nix integration. See [Secrets](#secrets-sops-nix).                                             |
| `pciPassthrough`   | list of str       | `[]`                        | PCI device addresses (BDF) to pass through; qemu only. See [GPU / PCI passthrough](#gpu--pci-passthrough). |
| `nixpkgs`          | path              | Host's `nixpkgs`            | The nixpkgs path to use for the MicroVM.                                                                   |
| `pkgs`             | module            | Host's `pkgs`               | The package set to use for the MicroVM. Must be a nixpkgs package set with the microvm overlay.            |
| `specialArgs`      | attrs             | `{}`                        | Extra attributes passed to the VM's configuration and NixOS modules.                                       |
| `extraModules`     | list of submodule | `[]`                        | Additional NixOS modules to be merged into                                                                 |
| `autostart`        | bool              | `true`                      | Whether this VM should be started with the host.                                                           |
| `updatePolicy`     | enum              | `"switch"`                  | How a host rebuild applies config changes: `"switch"` (hot-reload userspace over SSH, restart only on hardware change), `"restart"` (always restart), `"manual"` (install only; restart yourself). |

Readonly fields: `tapInterface`, `ipv4`, `ipv6`, `macAddress`, `vsockCid` (derived from the resolved index), and `fqdn` (= `<name>.forest.local`). Refer to a VM via `config.forest.vms.<name>.ipv4` / `.ipv6` / `.fqdn` instead of hard-coding.

## Top-level options

`forest.<...>`:

| option              | type        | default                         | description                                            |
|---------------------|-------------|---------------------------------|--------------------------------------------------------|
| `enable`            | bool        | `true`                          | Master switch.                                         |
| `vms`               | attrs       | `{}`                            | VM definitions keyed by name. See [Per-VM options](#per-vm-options). |
| `common`            | module      | `{}`                            | Defaults merged into every VM. See [`forest.common`](#forestcommon). |
| `vmSubnet`          | str         | `"192.168.69.0/24"`             | IPv4 subnet for the bridge.                            |
| `vmSubnet6`         | str         | `"fd69::/64"`                   | IPv6 subnet for the bridge.                            |
| `vmGateway`         | str         | `"192.168.69.1"`                | Host IPv4 on the bridge (also the default DNS server). |
| `vmGateway6`        | str         | `"fd69::1"`                     | Host IPv6 on the bridge.                               |
| `bridgeInterface`   | str         | `"forest"`                      | Linux bridge name.                                     |
| `serveDns`          | bool        | _auto_                          | Whether forest configures `services.resolved` with a stub on the bridge. See [DNS](#dns). |

## Networking

What every VM gets without configuration:

- An IPv4 (`192.168.69.{10+index}`), IPv6 (`fd69::{10+index}`), MAC, and vsock CID derived from its `index`. Refer to other VMs via `config.forest.vms.<name>.ipv4` / `.ipv6` instead of hard-coding.
- A name in the `.forest.local` domain (`web.forest.local`, `db.forest.local`), exposed as `config.forest.vms.<name>.fqdn`. `/etc/hosts` is populated on host and guests.
- A slot on the `forest` bridge with the host as gateway at `192.168.69.1` / `fd69::1`.
- DNS that resolves through the host's bridge IPs (see [DNS](#dns)).
- Default-deny inter-VM traffic — a VM cannot reach another unless it declares a [`dependsOn`](#inter-vm-dependencies) entry.
- Internet access via host NAT, gated per-VM by `internetAccess` (default `true`).

`index` is auto-assigned by walking VMs in name order and giving each the lowest free slot. **Once a VM holds persistent state (a database, an issued cert, a deployed service), pin its index explicitly** so its IP doesn't shift when you add or rename other VMs. Set `forest.vms.<name>.index = N` (range 0–244) to pin; auto-assignment skips pinned slots, so pins and unset values mix freely. Pins must be unique.

### Inter-VM dependencies

```nix
forest.vms.web = {
  dependsOn = [
    { target = "db";    port = 5432; protocol = "tcp"; ipVersion = "both"; }
    { target = "cache"; port = 6379; protocol = "tcp"; }
  ];
  config = { ... }: { /* ... */ };
};
```

Generates the matching firewall accept rules; connection tracking handles return traffic. Reach the other VMs by name — `db.forest.local`, or `config.forest.vms.db.fqdn` if you want to avoid hard-coding the domain.

### DNS

Each VM resolves through the **host's bridge IPs**. Forest auto-enables `services.resolved` on the host with `DNSStubListenerExtra` bound to those IPs, so VMs inherit whatever the host's resolver forwards to. Zero config required.

To restrict a VM to only resolve via specific servers (firewall-enforced):

```nix
forest.vms.foo.dns = {
  servers = [ "10.0.0.53" ];
  restrict = true;           # drop DNS to anywhere else at the firewall
};
```

To set a default for **every** VM (e.g. point them all at a DNS VM you run inside the forest), use [`forest.common`](#forestcommon):

```nix
# point every VM at a dedicated dns VM…
forest.common.dns.servers = lib.mkDefault [ config.forest.vms.dns.ipv4 ];

# …except the dns VM itself, which resolves upstream via the host
forest.vms.dns.dns.servers = [ config.forest.vmGateway config.forest.vmGateway6 ];
```

`mkDefault` lives at priority 1000, so a per-VM override at normal priority (100) wins outright — no `mkForce` needed.

If you run your **own resolver on the host** (dnsmasq, unbound, pihole, custom resolved config), set `forest.serveDns = false` to stop forest from touching `services.resolved`. Bind your daemon to the bridge IPs yourself; VMs at the default still hit them.

### Inbound port forwards

`forwardPorts` exposes a port inside the VM by DNATing inbound packets on the host. Forest doesn't enforce a tunnel — bring your own (tailscale, wireguard, a public NIC) and tell forest which interface or address to forward from.

```nix
forest.vms.dev.forwardPorts = [
  # ssh on tailnet only — both v4 + v6, any tailscale address
  { port = 22; protocol = "tcp"; interface = "tailscale0"; }

  # http on a specific public v4 address, host port 8080 → vm port 80
  { port = 80; hostPort = 8080; protocol = "tcp"; bindAddress = "203.0.113.5"; }
];
```

Per entry:

| field         | type                  | required | description                                                                 |
|---------------|-----------------------|----------|-----------------------------------------------------------------------------|
| `port`        | int                   | yes      | Port inside the VM.                                                         |
| `hostPort`    | int                   | no       | Port on the host. Defaults to `port`.                                       |
| `protocol`    | `tcp` / `udp` / `both`| yes      | —                                                                           |
| `interface`   | str                   | no       | Host interface (`iifname`) the forward applies to.                          |
| `bindAddress` | str or list of str    | no       | Host destination address(es). Family inferred per address; `0.0.0.0` / `::` are "any" sentinels. |

At least one of `interface` / `bindAddress` must be set explicitly — leaving both unset fails at eval time, so a forward can't quietly redirect a port on every interface. If you genuinely want all interfaces, write `bindAddress = [ "0.0.0.0" "::" ]`.

When `bindAddress` is unset and `interface` is, it defaults to `[ "0.0.0.0" "::" ]` (any address, both families). The interface filter does the scoping.

For tailscale: enable `services.tailscale.enable = true;` on the host the usual way and reference `interface = "tailscale0"`. Forest's nftables config doesn't conflict with tailscaled's own rules; see the [NixOS wiki page on Tailscale](https://wiki.nixos.org/wiki/Tailscale) for host-level setup.

## SSH access

```nix
forest.vms.web.ssh.users.alice = {
  sshKeys = [ "ssh-ed25519 AAAA..." ];
  shell = pkgs.zsh;            # optional; defaults to pkgs.bashInteractive
};
```

Creates the user, opens sshd to the bridge, and disables password auth. From the host you can reach the VM at `web.forest.local`.

Per user:

| field     | type                 | default               | description                                       |
|-----------|----------------------|-----------------------|---------------------------------------------------|
| `sshKeys` | list of str          | `[]`                  | Authorized SSH public keys for this user.         |
| `shell`   | package              | `pkgs.bashInteractive`| Login shell. Pass any shell package (e.g. `pkgs.zsh`, `pkgs.fish`). Enable the matching program module in the VM's `config` if the shell needs it (e.g. `programs.zsh.enable = true;`). |

### Reaching VMs from elsewhere

VMs live on the internal bridge, so their IPs aren't routable from outside the host. ProxyJump through the host to reach them by name:

```sh
ssh -J user@hostmachine alice@web.forest.local
```

Or persistently in `~/.ssh/config`:

```
Host *.forest.local
  ProxyJump user@hostmachine
```

The destination hostname is resolved on the jump host, which already has `/etc/hosts` populated for every VM. For wider reach (laptops on the tailnet, CI, etc.), set up the host's SSH access however you normally would — tailscale, public NIC, etc. — and ProxyJump through that.

Use `forwardPorts` instead when you want a single VM exposed on a stable host port without requiring SSH access to the host itself.

## Secrets (sops-nix)

```nix
forest.vms.foo = {
  sops = {
    enable = true;
    defaultSopsFile = ./secrets/foo.yaml;
  };
  config = {
    sops.secrets.api_token = {};
    # ...
  };
};
```

The VM's persistent SSH host key is used as the age identity for sops. To enroll a freshly-created VM:

```sh
ssh-keyscan <vm-ip> | ssh-to-age   # add this age public key to .sops.yaml
```

The public key on disk is at `/var/lib/microvms/<vm>/host-keys/ssh_host_ed25519_key.pub`.

## Persistent state

Each VM has three persistent virtiofs shares:

| guest path           | host path                              | purpose                                 |
|----------------------|----------------------------------------|-----------------------------------------|
| `/home`              | `/var/lib/microvms/<vm>/home`          | user homes                              |
| `/var/log`           | `/var/lib/microvms/<vm>/logs`          | journals + logs                         |
| `/var/lib/host-keys` | `/var/lib/microvms/<vm>/host-keys`     | SSH host keys (stable VM identity)      |

The host's `/nix/store` is shared read-only. By default each VM also gets a writable overlay on top of it (`writableStore = true`) so `nix-shell`, `nix build`, etc. work inside the guest — implemented as nix's `local-overlay-store` backend with the upper layer kept in `/var/lib/microvms/<vm>/nix-store-overlay.img`. The overlay image is wiped on every VM start so boots stay clean. Set `writableStore = false` to skip the overlay (read-only host store only).

> **Note on Lix.** The writable overlay needs the `local-overlay-store` experimental feature, which CppNix and Determinate Nix ship but Lix does not. If a VM sets `nix.package = pkgs.lix` and leaves `writableStore = true`, an assertion fails at eval time with instructions to either flip `writableStore = false` or pin a CppNix variant.

`system.stateVersion` is pinned per VM via `stateVersion`.

## `forest.common`

A module merged into every VM, reusing the per-VM option schema. Any VM-level option (`config`, `ssh.users`, `memorySize`, `dns`, ...) can be set here as a shared default or addition.

```nix
forest.common = {
  ssh.users.ops.sshKeys = [ "ssh-ed25519 AAAA..." ];
  memorySize = lib.mkDefault 4096;
  config = { pkgs, ... }: {
    imports = [ ./vm-base.nix ];
    boot.kernelPackages = pkgs.linuxPackages_latest;
    environment.systemPackages = [ pkgs.htop ];
  };
};
```

Definitions follow normal module-system merge rules:

- **attrsets** (e.g. `ssh.users`) merge per-key with per-VM definitions — every VM gets the common entries plus its own. The same key declared in both is a conflict; use `lib.mkForce` to override.
- **the inner `config` module** merges as modules always do.
- **scalars** (e.g. `memorySize`) at normal priority will conflict with a per-VM definition; wrap in `lib.mkDefault` to make them overridable.

## GPU / PCI passthrough

Cloud-hypervisor's PCI passthrough is fragile, so this requires `hypervisor = "qemu"`.

```nix
forest.vms.workstation = {
  hypervisor = "qemu";
  pciPassthrough = [
    "0000:06:00.0"   # GPU
    "0000:06:00.1"   # HDMI audio function on the same card
  ];
  config = { /* ... */ };
};
```

When at least one VM has `pciPassthrough != []`, forest adds `intel_iommu=on amd_iommu=on iommu=pt` to `boot.kernelParams`. The kernel ignores the irrelevant vendor's flag, so this works on Intel and AMD without any CPU-vendor option. The host's `microvm-pci-devices@<vm>` service is also given retry-on-failure config, since PCI unbinding occasionally flakes the first time. An assertion enforces `hypervisor = "qemu"` whenever `pciPassthrough` is non-empty.

### Finding PCI addresses

The address forest wants is BDF format — `domain:bus:device.function`, e.g. `0000:06:00.0`. List every device with vendor:device IDs:

```console
$ lspci -nn
00:00.0 Host bridge [0600]: Intel Corporation ... [8086:1234]
06:00.0 VGA compatible controller [0300]: NVIDIA Corporation ... [10de:2204]
06:00.1 Audio device [0403]: NVIDIA Corporation ... [10de:1aef]
```

Filter to GPUs, or inspect a single device's current driver binding:

```bash
lspci -nn | grep -iE 'vga|3d|display'
lspci -nnk -s 06:00.0
```

If a domain prefix is missing (`06:00.0` vs `0000:06:00.0`), prepend `0000:` — that's the default PCI domain on most systems.

### IOMMU groups: the whole group goes through

VFIO passes through an entire IOMMU group, not a single function. Before adding a device to `pciPassthrough`, list its group and check what else is in it:

```bash
for g in /sys/kernel/iommu_groups/*; do
  group=$(basename "$g")
  for d in "$g"/devices/*; do
    printf '%-3s  ' "$group"
    lspci -nns "$(basename "$d")"
  done
done | sort -V -k1
```

If the GPU shares a group with something you need on the host, the options are: a different physical slot, the kernel's ACS override patch, or moving the entire group to the VM. GPUs almost always come paired with an HDMI/DisplayPort audio function (typically `.1`) — pass both or audio inside the VM won't work.

### Driver binding

You don't need to bind devices to `vfio-pci` manually — `microvm-pci-devices@<vm>` unbinds the current driver and rebinds to vfio-pci before the VM starts, then reverses on shutdown. If a device is held by a driver that won't let go (e.g. an active display managed by `nvidia-drm`), the unbind fails; the retry config helps but the cleanest fix is making sure the host doesn't actively use the device.

## Tests

```sh
nix flake check
# or:
nix-instantiate --eval ./tests -A summary
```

## License

MIT.

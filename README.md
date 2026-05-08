# forest.nix

Easy declarative microvm-backed virtual machines for NixOS. A thin opinionated layer over [microvm.nix](https://github.com/microvm-nix/microvm.nix) that wires up networking, NAT, per-VM firewalling, persistent state, SSH host keys, and a small CLI — so a VM definition fits in a handful of lines.

```nix
forest.vms.web.config = {
  services.nginx.enable = true;
};
```

## What you get

- **Containers-like interface on top of microvm-nix.** Declare a VM the way you'd declare a NixOS container — one attrset of options, one config module — but with hardware isolation and a hypervisor instead of a shared kernel.
- **Networking generated from your declarations.** Bridge, NAT, IPv4/IPv6, default-deny inter-VM firewalling, DNS — all derived from `forest.vms.*`. Open specific ports between VMs with `dependsOn`, cut a VM off from the public internet with `internetAccess = false`, force DNS through a single resolver with `dns.constrain = true`. All configurable, sane defaults.
- **Lightweight sops-nix integration.** Each VM gets a stable SSH host key that doubles as its age identity automatically — no manual `neededForBoot`, `sshKeyPaths`, or per-VM key plumbing for you to debug.
- **Writable nix store inside the VM, without the 20-minute rebuild tax.** Forest wires up cppnix's `local-overlay-store` experimental feature so `/nix/store` is shared read-only from the host and only the VM's deltas live in its own image. Confuses gc (it can't see the lower layer's references) but doesn't break it. Toggle with `writableStore`.

## Status

We early, APIs may shift.

## Quick start

### Flake

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
        ./host.nix
      ];
    };
  };
}
```

### Without flakes

`forest.nix` ships a plain `default.nix` that pins `microvm.nix` and `sops-nix` via [npins](https://github.com/andir/npins) — no flake required at any layer:

```nix
# /etc/nixos/configuration.nix
{ ... }: {
  imports = [
    (import (builtins.fetchTarball {
      url    = "https://github.com/antimemetics-institute/forest.nix/archive/<rev>.tar.gz";
      sha256 = "...";
    }) {})
    ./host.nix
  ];
}
```

To override forest's bundled pins (e.g. share an already-pinned `microvm.nix`):

```nix
(import forest-source { microvmSrc = my-microvm-source; })
```

(Flake users override the same way they override any flake input — `inputs.forest.inputs.microvm.url = "...";` or `.follows = "...";`.)

Then in `host.nix`:

```nix
{ ... }: {
  forest = {
    externalInterface = "enp5s0";  # your physical/wifi interface

    vms.web.config = {
      services.nginx.enable = true;
      networking.firewall.allowedTCPPorts = [ 80 ];
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

## Networking

- Every VM gets an IPv4 (`192.168.69.{10+index}`), IPv6 (`fd69::{10+index}`), MAC, and vsock CID derived from its `index`. Refer to a VM's IP via `forest.vms.{name}.ipv4` / `.ipv6` instead of hard-coding it.
- `index` is auto-assigned by default — VMs are walked in name order and each gets the lowest free slot. **Once a VM holds persistent state (a database, an issued cert, a deployed service), pin its index explicitly** so its IP doesn't shift when you add or rename other VMs. Set `forest.vms.<name>.index = N` (range 0–244) to pin; auto-assignment skips pinned slots, so pins and unset values mix freely. Pins must be unique.
- VMs sit on a bridge (`forest` by default). The host is the gateway at `192.168.69.1` / `fd69::1`.
- The host's nftables policy is **default-deny for inter-VM traffic**: a VM cannot reach another VM unless it declares a `dependsOn` entry. Internet access is gated per-VM by `internetAccess` (default `true`).

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

This generates the matching firewall accept rules. Connection tracking handles return traffic. Refer to the other VMs by their name in the `.forest.local` domain, e.g., `db.forest.local` or `cache.forest.local`.

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

Find the key in `/var/lib/microvms/{vm_name}/host_keys/SOMETHINGSOMETHING` TODO check what it is here

## Store overlay

By default, the VMs use cppnix specific experimental feature to enable a writable store overlay, allowing you to run commands like `nix-shell` inside the VM.

## Per-VM options

| option            | type         | default                         | description                                       |
|-------------------|--------------|---------------------------------|---------------------------------------------------|
| `enable`          | bool         | `true`                          | Whether this VM is part of the forest.            |
| `index`           | int or null  | `null` (auto-assigned)          | Pin to a stable slot (0–244). See [Networking](#networking). |
| `hypervisor`      | str          | `"cloud-hypervisor"`            | Any microvm-supported hypervisor.                 |
| `memory`          | int (MB)     | `2048`                          | Memory allocation.                                |
| `vcpu`            | int          | `4`                             | Number of vCPUs.                                  |
| `stateVersion`    | str          | `"25.11"`                       | `system.stateVersion` for the VM.                 |
| `writableStore`   | bool         | `true`                          | Writable nix store overlay (wiped on each start). |
| `pciPassthrough`  | list of str  | `[]`                            | PCI device addresses to pass through (qemu only). |
| `graphics.enable` | bool         | `false`                         | Use spectrum-patched cloud-hypervisor for graphics. |
| `config`          | module       | _required_                      | NixOS module for the VM.                          |
| `internetAccess`  | bool         | `true`                          | Allow public internet via host NAT.               |
| `dns.servers`     | list of str  | `forest.dns.servers`            | DNS servers configured in the VM.                 |
| `dns.constrain`   | bool         | `forest.dns.constrain`          | Drop DNS to anything outside `dns.servers`.       |
| `dependsOn`       | list         | `[]`                            | Allowed outbound connections to other VMs.        |
| `ssh.users`       | list         | `[]`                            | Create users with SSH access (opens sshd).        |
| `sops`            | submodule    | disabled                        | Per-VM sops-nix integration.                      |

The readonly fields `tapInterface`, `ipv4`, `ipv6`, `macAddress`, `vsockCid` are derived from the VM's resolved index (explicit if set, otherwise auto-assigned).

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

## Graphics (cloud-hypervisor)

To enable graphical output on a VM:

```nix
forest.vms.desktop = {
  graphics.enable = true;
  config = { /* ... */ };
};
```

Forest swaps the VM's cloud-hypervisor binary for the [spectrum-patched](https://spectrum-os.org) graphics build (`pkgs.cloud-hypervisor-graphics`) and sets `microvm.graphics.enable = true` inside the VM. Lazy: when no VM has `graphics.enable = true`, the patched build is never realized — zero closure cost.

The patched cloud-hypervisor is **not** in microvm's binary cache, so first build is from-source (10–30 min). Adding microvm's cachix is still recommended for the regular cloud-hypervisor / qemu / virtiofsd builds:

```nix
nix.settings = {
  substituters = [ "https://microvm.cachix.org" ];
  trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
};
```

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

Unit tests for the nftables rule generators:

```sh
nix flake check
# or:
nix-instantiate --eval ./tests -A summary
```

## Architecture notes

- One nftables `inet` table (`forest_filter`) holds the input + forward chains. Two NAT tables (`forest_nat`, `forest_nat6`) handle masquerade. Rules are generated per-VM from `forest/utils/nftables.nix`.
- `forest.commonConfig` is implemented as a `deferredModule` and prepended to each VM's `imports` list, before the user's `vm.config`.
- The CLI lives in `forest/cli.nix` + `forest/forest.sh` + `forest/completion.bash`. The script is shellcheck-clean (enforced by `pkgs.writeShellApplication`).

## License

MIT.

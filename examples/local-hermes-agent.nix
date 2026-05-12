{ config, pkgs, ... }:

let
  # REPLACEME: add your own login user and authorized SSH keys
  me = {
    name = "me";
    sshKeys = [
      # "ssh-ed25519 AAAA... you@host"
    ];
  };

  # REPLACEME: with your GPU's PCI addresses (find them with `lspci -nn | grep -iE 'vga|audio|3d'`)
  pciDevices = [ "0000:01:00.0" "0000:01:00.1" ];

  # hermes-agent is flake-only; here we use flake-compat to evaluate it
  hermesSrc = fetchTarball {
    url = "https://github.com/nix-community/hermes-agent/archive/refs/heads/main.tar.gz";
  };
  hermesFlake = (import (fetchTarball {
    url = "https://github.com/nix-community/flake-compat/archive/refs/heads/master.tar.gz";
    sha256 = "1vw6pqs690w00lpfy4ffkli5mfwsp4bdncgyibmglxk6l8zw9nh2";
  }) { src = hermesSrc; }).defaultNix;
  hermesModule = hermesFlake.nixosModules.default;

  # Qwen3.5 9B (Q4_K_M) — fits on 16GB VRAM GPU with room for 64K KV cache.
  qwen-gguf = pkgs.fetchurl {
    url = "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf";
    sha256 = "1s5paapkv1gsp565y5rlazn2yjzhnc5l5i22w0w679b0m0klgdq3";
  };
in
{
  # set SSH credential across all forest VMs
  forest.common.ssh.users.${me.name}.sshKeys = me.sshKeys;

  # ---------------------------------------------------------------------------
  # llama — local inference via llama.cpp, no internet, model baked in via Nix
  # ---------------------------------------------------------------------------
  forest.vms.llama = {
    cores = 4;
    memorySize = 3072;
    pciPassthrough = pciDevices;

    # airgapped (llama does not need internet access to do LLM inference)
    # this way no nftables rules granting the VM access to the outer internet are generated
    internetAccess = false;

    # PCI passthrough is qemu-only
    hypervisor = "qemu";

    config = { pkgs, ... }: {
      services.xserver.videoDrivers = [ "nvidia" ];
      hardware.nvidia.open = true;
      hardware.graphics.enable = true;

      systemd.services.llama-server = {
        description = "llama.cpp inference server";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.llama-cpp.override { cudaSupport = true; }}/bin/llama-server -m ${qwen-gguf} -a qwen3.5-9b --host ${config.forest.vms.llama.ipv4} --port 11434 -ngl 99 --jinja -c 262144 -n -1";
          Restart = "on-failure";
        };
      };

      networking.firewall.allowedTCPPorts = [ 11434 ];
    };
  };

  # ---------------------------------------------------------------------------
  # agent — hermes-agent + code-server, talks to llama for inference
  # ---------------------------------------------------------------------------
  forest.vms.agent = {
    index = 1;
    cores = 4;
    memorySize = 4096;

    # make available the LLM inference port from the other LLM
    dependsOn = [
      { target = "llama"; port = 11434; protocol = "tcp"; ipVersion = "ipv4"; }
    ];

    # forward ports 2222 (ssh) and 4444 (code-server) to the tailnet
    forwardPorts = [
      { port = 22; hostPort = 2222; protocol = "tcp"; interface = "tailscale0"; }
      { port = 4444; hostPort = 4444; protocol = "tcp"; interface = "tailscale0"; }
    ];

    config = { ... }: {
      imports = [ hermesModule ];

      # Let the login user use the shared hermes CLI (HERMES_HOME is 2770 hermes:hermes)
      users.users.${me.name}.extraGroups = [ "hermes" ];

      # --- hermes-agent pointed at the ollama VM 
      services.hermes-agent = {
        enable = true;
        addToSystemPackages = true;
        settings = {
          model = {
            default = "qwen3.5-9b";
            provider = "custom";
          };
        };
        environment = {
          CUSTOM_BASE_URL = "http://${config.forest.vms.llama.fqdn}:11434/v1";
          CUSTOM_API_KEY = "unused";
        };
      };

      # --- code-server with telemetry disabled
      services.code-server = {
        enable = true;
        port = 4444;
        host = config.forest.vms.agent.ipv4;
        disableTelemetry = true;
        disableUpdateCheck = true;
      };
    };
  };
}
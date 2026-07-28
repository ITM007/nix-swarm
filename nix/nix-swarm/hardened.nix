{ config, lib, ... }:

let
  cfg = config.services.nix-swarm;
in
{
  config = lib.mkIf (cfg.enable && cfg.hardened) {
    # Harden the host baseline while leaving deployment keys and the shared
    # Erlang cookie to the machine-specific configuration.
    users.mutableUsers = lib.mkForce false;

    services.openssh = {
      enable = lib.mkDefault true;
      allowSFTP = lib.mkForce false;
      settings = {
        AllowAgentForwarding = false;
        AllowTcpForwarding = "no";
        ClientAliveCountMax = 2;
        ClientAliveInterval = 300;
        KbdInteractiveAuthentication = false;
        LoginGraceTime = 20;
        MaxAuthTries = 3;
        MaxSessions = 4;
        PasswordAuthentication = false;
        PermitEmptyPasswords = false;
        PermitRootLogin = "prohibit-password";
        PubkeyAuthentication = true;
        X11Forwarding = false;
      };
    };

    networking.firewall = {
      enable = lib.mkForce true;
      allowPing = false;
      logRefusedConnections = true;
    };

    environment.defaultPackages = lib.mkForce [ ];
    documentation.enable = false;
    documentation.nixos.enable = false;

    # Keep the kernel selected by the pinned NixOS release. These parameters
    # harden allocator behavior and reduce information exposed to userspace.
    boot.kernelParams = [
      "audit=1"
      "debugfs=off"
      "init_on_alloc=1"
      "init_on_free=1"
      "page_alloc.shuffle=1"
      "slab_nomerge"
      "vsyscall=none"
    ];

    boot.kernel.sysctl = {
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
      "kernel.dmesg_restrict" = 1;
      "kernel.kptr_restrict" = 2;
      "kernel.unprivileged_bpf_disabled" = 1;
      "kernel.yama.ptrace_scope" = 2;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.all.log_martians" = 1;
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.default.rp_filter" = 1;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
    };

    security.apparmor.enable = true;
    security.auditd.enable = true;

    services.fstrim.enable = true;
    services.journald.extraConfig = ''
      Storage=persistent
      SystemMaxUse=256M
      RuntimeMaxUse=64M
      MaxRetentionSec=30day
      ForwardToSyslog=no
    '';
    services.timesyncd.enable = true;
    systemd.oomd.enable = true;

    nix = {
      channel.enable = false;
      optimise.automatic = true;
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };
      settings = {
        auto-optimise-store = true;
        allowed-users = [ "root" ];
        builders-use-substitutes = true;
        experimental-features = [ "nix-command" "flakes" ];
        require-sigs = true;
        sandbox = true;
        trusted-users = [ "root" ];
      };
    };
  };
}

{ config, pkgs, lib, ... }:

{
  imports = [
    ./modules/nginx.nix
    ./modules/acme.nix
    ./modules/apps.nix
    ./modules/postgres.nix
    ./modules/pg-backup.nix
  ];

  system.stateVersion = "24.11";
  nixpkgs.config.allowUnfree = true;

  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  networking = {
    hostName = "hetzner-theor-net-web-1";
    useDHCP = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 80 443 ];
    };
  };

  time.timeZone = "UTC";

  i18n.defaultLocale = "en_US.UTF-8";

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  users.users.root = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIELtIN+wG3GGLHruiy+Bl3NNJFcAU7uK4Q3rbVD3ad18"
    ];
  };

  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    curl
    wget
    rclone
    crane
  ];

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
      trusted-users = [ "root" ];
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  services.qemuGuest.enable = true;
}


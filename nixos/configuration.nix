{ config, pkgs, lib, ... }:

{
  imports = [
    ./modules/nginx.nix
    ./modules/acme.nix
    ./modules/apps.nix
  ];

  system.stateVersion = "24.11";
  nixpkgs.config.allowUnfree = true;    

  networking = {
    hostName = "theor-net-web";
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
  ];

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  services.qemuGuest.enable = true;
}


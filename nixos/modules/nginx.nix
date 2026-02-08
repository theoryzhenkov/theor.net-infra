{ config, pkgs, lib, ... }:

{
  services.nginx = {
    enable = true;

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    commonHttpConfig = ''
      map $scheme $hsts_header {
        https   "max-age=31536000; includeSubDomains";
      }
    '';
  };

  users.users.nginx.extraGroups = [ "acme" ];
}


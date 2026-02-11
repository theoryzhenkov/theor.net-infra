{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = "headscale.theor.net";
  listenPort = 8085;
in
{
  services.headscale = {
    enable = true;
    address = "127.0.0.1";
    port = listenPort;

    settings = {
      server_url = "https://${domain}";

      dns = {
        base_domain = "ts.theor.net";
        magic_dns = true;
        nameservers.global = [
          "1.1.1.1"
          "9.9.9.9"
        ];
      };

      prefixes = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
        allocation = "sequential";
      };

      derp = {
        server = {
          enabled = true;
          region_id = 999;
          region_code = "theor";
          region_name = "theor.net";
          stun_listen_addr = "0.0.0.0:3478";
        };
        urls = [ "https://controlplane.tailscale.com/derpmap/default" ];
        auto_update_enabled = true;
        update_frequency = "24h";
      };

      oidc = {
        issuer = "https://auth.theor.net";
        client_id = "headscale";
        client_secret_path = config.sops.secrets.headscale_oidc_client_secret.path;
        scope = [ "openid" "email" "profile" "groups" ];
        pkce = {
          enabled = true;
          method = "S256";
        };
      };

      log = {
        level = "info";
      };
    };
  };

  sops.secrets.headscale_oidc_client_secret = {
    sopsFile = ../secrets/secrets.enc.yaml;
    owner = "headscale";
    group = "authelia";
    mode = "0440";
  };

  # Ensure headscale starts after authelia is up and ACME has issued a real cert
  systemd.services.headscale = {
    after = [ "acme-auth.theor.net.service" "authelia.service" ];
    wants = [ "authelia.service" ];
  };

  # Headscale CLI available system-wide
  environment.systemPackages = [ config.services.headscale.package ];

  services.nginx.virtualHosts."${domain}" = {
    enableACME = true;
    forceSSL = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString listenPort}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_buffering off;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };
}

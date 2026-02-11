{
  config,
  pkgs,
  lib,
  ...
}:

let
  domain = "auth.theor.net";
  listenPort = 9091;
  dataDir = "/var/lib/authelia";

  # Declarative user database
  # To add users: add an entry below and deploy.
  # To generate a password hash locally:
  #   nix run "nixpkgs#authelia" -- crypto hash generate argon2 --password 'YOUR_PASSWORD'
  users = {
    theo = {
      displayname = "Theo";
      password = "$argon2id$v=19$m=65536,t=3,p=4$nLMn85yF5hVKj7yevhbr/w$qJzHpsBBoXfkKuOKZQUNAKIywnTAZeyxU/+GO4z7ATI";
      email = "theo@theor.net";
      groups = [ "admins" ];
    };
  };

  usersFile = pkgs.writeText "authelia-users.yaml" (builtins.toJSON { inherit users; });

  # Static configuration (secrets are injected at runtime via environment variables)
  autheliaConfig = pkgs.writeText "authelia-config.yml" (builtins.toJSON {
    theme = "auto";

    server = {
      address = "tcp://127.0.0.1:${toString listenPort}/";
    };

    log = {
      level = "info";
      format = "text";
    };

    totp = {
      issuer = domain;
      period = 30;
      digits = 6;
    };

    authentication_backend = {
      file = {
        path = "${usersFile}";
        password = {
          algorithm = "argon2";
          argon2 = {
            variant = "argon2id";
            iterations = 3;
            memory = 65536;
            parallelism = 4;
            key_length = 32;
            salt_length = 16;
          };
        };
      };
    };

    access_control = {
      default_policy = "one_factor";
    };

    session = {
      cookies = [
        {
          domain = "theor.net";
          authelia_url = "https://${domain}";
          default_redirection_url = "https://${domain}";
        }
      ];
    };

    regulation = {
      max_retries = 3;
      find_time = "2m";
      ban_time = "5m";
    };

    storage = {
      local = {
        path = "${dataDir}/db.sqlite3";
      };
    };

    notifier = {
      filesystem = {
        filename = "${dataDir}/notification.txt";
      };
    };

    identity_providers = {
      oidc = {
        claims_policies = {
          headscale = {
            id_token = [ "email" "groups" ];
          };
        };

        clients = [
          {
            client_id = "headscale";
            client_name = "Headscale";
            public = false;
            authorization_policy = "one_factor";
            require_pkce = true;
            pkce_challenge_method = "S256";
            redirect_uris = [
              "https://headscale.theor.net/oidc/callback"
            ];
            scopes = [ "openid" "email" "profile" "groups" ];
            response_types = [ "code" ];
            grant_types = [ "authorization_code" ];
            access_token_signed_response_alg = "none";
            userinfo_signed_response_alg = "none";
            token_endpoint_auth_method = "client_secret_basic";
            claims_policy = "headscale";
          }
        ];
      };
    };
  });

  # Startup script: injects SOPS secrets into config and launches authelia
  startScript = pkgs.writeShellScript "authelia-start" ''
    set -euo pipefail

    # Authelia reads AUTHELIA_* env vars as config overrides
    export AUTHELIA_JWT_SECRET="$(cat ${config.sops.secrets.authelia_jwt_secret.path})"
    export AUTHELIA_SESSION_SECRET="$(cat ${config.sops.secrets.authelia_session_secret.path})"
    export AUTHELIA_STORAGE_ENCRYPTION_KEY="$(cat ${config.sops.secrets.authelia_storage_encryption_key.path})"
    export AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET="$(cat ${config.sops.secrets.authelia_oidc_hmac_secret.path})"
    export AUTHELIA_IDENTITY_PROVIDERS_OIDC_JWKS_0_KEY_FILE="${config.sops.secrets.authelia_oidc_private_key.path}"
    export AUTHELIA_IDENTITY_PROVIDERS_OIDC_CLIENTS_0_CLIENT_SECRET="$(cat ${config.sops.secrets.headscale_oidc_client_secret.path})"

    exec ${pkgs.authelia}/bin/authelia \
      --config ${autheliaConfig}
  '';
in
{
  sops.secrets = {
    authelia_jwt_secret = {
      sopsFile = ../secrets/secrets.enc.yaml;
      owner = "authelia";
    };
    authelia_session_secret = {
      sopsFile = ../secrets/secrets.enc.yaml;
      owner = "authelia";
    };
    authelia_storage_encryption_key = {
      sopsFile = ../secrets/secrets.enc.yaml;
      owner = "authelia";
    };
    authelia_oidc_hmac_secret = {
      sopsFile = ../secrets/secrets.enc.yaml;
      owner = "authelia";
    };
    authelia_oidc_private_key = {
      sopsFile = ../secrets/secrets.enc.yaml;
      owner = "authelia";
    };
  };

  users.users.authelia = {
    isSystemUser = true;
    group = "authelia";
    home = dataDir;
    createHome = true;
  };
  users.groups.authelia = {};

  systemd.services.authelia = {
    description = "Authelia authentication server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "authelia";
      Group = "authelia";
      ExecStart = startScript;
      Restart = "always";
      RestartSec = "5s";

      StateDirectory = "authelia";
      WorkingDirectory = dataDir;

      # Hardening
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ dataDir ];
      PrivateTmp = true;
    };
  };

  services.nginx.virtualHosts."${domain}" = {
    enableACME = true;
    forceSSL = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString listenPort}";
      proxyWebsockets = true;
    };
  };
}

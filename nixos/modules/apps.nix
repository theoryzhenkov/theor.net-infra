{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Import generated apps from YAML files
  appsGenerated = import ../apps/apps.lock.nix;

  # App subsets
  dbApps = lib.filterAttrs (_: app: app.database or false) appsGenerated;
  secretsApps = lib.filterAttrs (_: app: app.secrets or false) appsGenerated;

  hasDatabase = app: app.database or false;
  hasSecrets = app: app.secrets or false;

  autoUpdateScript = pkgs.writeShellScript "docker-auto-update" ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: app: ''
      echo "Checking ${name}..."
      RESTART_NEEDED=""
      OLD=$(${pkgs.docker}/bin/docker image inspect --format '{{.Id}}' "${app.image}" 2>/dev/null || echo "none")
      if ${pkgs.docker}/bin/docker pull "${app.image}"; then
        NEW=$(${pkgs.docker}/bin/docker image inspect --format '{{.Id}}' "${app.image}")
        if [ "$OLD" != "$NEW" ]; then
          echo "${name}: image updated"
          RESTART_NEEDED=1
        fi
      else
        echo "${name}: image pull failed, skipping"
      fi
      if [ -n "$RESTART_NEEDED" ]; then
        echo "${name}: restarting..."
        ${pkgs.systemd}/bin/systemctl restart "${name}"
      else
        echo "${name}: up to date"
      fi
    '') appsGenerated)}
  '';

  mkDockerService = name: app:
    let
      wantsDb = hasDatabase app;
      wantsSecrets = hasSecrets app;

      # Encrypted secrets file from the infra repo (copied to Nix store at build time)
      secretsFile = ../apps/${name}/secrets.enc.yaml;

      dbDeps = lib.optionals wantsDb [
        "postgresql.service"
        "pg-set-passwords.service"
      ];

      execStart = pkgs.writeShellScript "start-${name}" (''
        set -euo pipefail
      '' + lib.optionalString (wantsSecrets || wantsDb) ''
        SECRETS_DIR="/var/lib/app-secrets/${name}"
        mkdir -p "$SECRETS_DIR"
        : > "$SECRETS_DIR/docker.env"
      '' + lib.optionalString wantsSecrets ''

        # Decrypt app secrets from infra repo (encrypted file is in the Nix store)
        echo "Decrypting secrets for ${name}..."
        SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
          ${pkgs.sops}/bin/sops --decrypt --input-type yaml --output-type dotenv \
          ${secretsFile} >> "$SECRETS_DIR/docker.env"
      '' + lib.optionalString wantsDb ''

        DB_PASS=$(cat ${config.sops.secrets."db_password_${name}".path})
        echo "DATABASE_URL=postgresql://${name}:$DB_PASS@host.docker.internal:5432/${name}" >> "$SECRETS_DIR/docker.env"
      '' + ''

        exec ${pkgs.docker}/bin/docker run --rm \
          --name ${name} \
          ${lib.optionalString wantsDb "--add-host=host.docker.internal:host-gateway"} \
          ${lib.optionalString (wantsSecrets || wantsDb) ''--env-file "$SECRETS_DIR/docker.env"''} \
          -p 127.0.0.1:${toString app.hostPort}:${toString app.containerPort} \
          ${app.image}
      '');
    in
    {
      name = name;
      value = {
        description = "${name} Docker container";
        after = [ "docker.service" "network-online.target" ] ++ dbDeps;
        requires = [ "docker.service" ] ++ dbDeps;
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = "10s";

          ExecStartPre = [
            "-${pkgs.docker}/bin/docker stop ${name}"
            "-${pkgs.docker}/bin/docker rm ${name}"
          ];

          ExecStart = execStart;

          ExecStop = "${pkgs.docker}/bin/docker stop ${name}";
        };
      };
    };

  mkProxyVhost = name: app: {
    "${app.domain}" = {
      enableACME = true;
      forceSSL = true;
      default = app.default or false;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString app.hostPort}";
        proxyWebsockets = true;
      };
    };
  };

in
{
  # GHCR authentication via sops-nix
  sops.secrets = {
    ghcr_username = {
      sopsFile = ../secrets/secrets.enc.yaml;
    };
    ghcr_token = {
      sopsFile = ../secrets/secrets.enc.yaml;
    };
  } // lib.mapAttrs' (name: _:
    lib.nameValuePair "db_password_${name}" {
      sopsFile = ../secrets/secrets.enc.yaml;
    }
  ) dbApps;

  # Generate /root/.docker/config.json on system activation
  system.activationScripts.docker-ghcr-login = lib.stringAfter [ "setupSecrets" ] ''
    mkdir -p /root/.docker
    GHCR_USER=$(cat ${config.sops.secrets.ghcr_username.path})
    GHCR_TOKEN=$(cat ${config.sops.secrets.ghcr_token.path})
    AUTH=$(echo -n "$GHCR_USER:$GHCR_TOKEN" | ${pkgs.coreutils}/bin/base64 -w0)
    cat > /root/.docker/config.json <<EOF
    {
      "auths": {
        "ghcr.io": {
          "auth": "$AUTH"
        }
      }
    }
    EOF
    chmod 600 /root/.docker/config.json
  '';

  virtualisation.docker.enable = true;

  # Per-app PostgreSQL databases and users
  services.postgresql.ensureDatabases = lib.mapAttrsToList (name: _: name) dbApps;
  services.postgresql.ensureUsers = lib.mapAttrsToList (name: _: {
    name = name;
    ensureDBOwnership = true;
  }) dbApps;

  # Docker services for app containers
  systemd.services =
    lib.listToAttrs (lib.mapAttrsToList mkDockerService appsGenerated)
    // {
      docker-auto-update = {
        description = "Pull latest Docker images and restart updated services";
        after = [ "docker.service" "network-online.target" ];
        requires = [ "docker.service" ];
        wants = [ "network-online.target" ];

        serviceConfig = {
          Type = "oneshot";
          ExecStart = autoUpdateScript;
        };
      };
    }
    // lib.optionalAttrs (dbApps != { }) {
      # Set passwords for app database users from SOPS secrets
      pg-set-passwords = {
        description = "Set PostgreSQL passwords for app databases";
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
          DB_PASS=$(cat ${config.sops.secrets."db_password_${name}".path})
          ${pkgs.util-linux}/bin/runuser -u postgres -- \
            ${config.services.postgresql.package}/bin/psql -c \
            "ALTER USER \"${name}\" PASSWORD '$DB_PASS';"
        '') dbApps);
      };
    };

  # Auto-update timer: checks for new Docker images every 5 minutes
  systemd.timers.docker-auto-update = {
    description = "Periodically check for Docker image updates";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      RandomizedDelaySec = "30s";
    };
  };

  services.nginx.virtualHosts = lib.mkMerge (lib.mapAttrsToList mkProxyVhost appsGenerated);
}

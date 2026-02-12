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
  dbApps = lib.filterAttrs (_: app: hasDatabase app) appsGenerated;
  secretsApps = lib.filterAttrs (_: app: hasSecrets app) appsGenerated;
  tailscaleApps = lib.filterAttrs (_: app: isTailscale app) appsGenerated;

  hasDatabase = app: (app.depends.database or null) == "postgresql";
  hasSecrets = app: app.secrets or false;
  isTailscale = app: (app.network or null) == "tailscale";

  # The server's Tailscale IP (assigned by Headscale via sequential allocation).
  # Used to register DNS overrides so tailnet peers route to tailscale-only apps
  # through the tunnel instead of the public internet.
  serverTailscaleIp = "100.64.0.2";

  # Derive a deterministic DB password from the server's age key + app name.
  # Both pg-set-passwords and the Docker start script use the same derivation,
  # so they always agree without any external secret provisioning.
  deriveDbPassword = name: ''
    echo -n "db-password:${name}" | ${pkgs.openssl}/bin/openssl dgst -sha256 -hmac "$(cat /var/lib/sops-nix/key.txt)" -r | cut -d' ' -f1
  '';

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

        DB_PASS=$(${deriveDbPassword name})
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
      } // lib.optionalAttrs (isTailscale app) {
        extraConfig = ''
          allow 100.64.0.0/10;
          deny all;
        '';
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
  };

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
      # Set passwords for app database users (derived deterministically from the server's age key)
      pg-set-passwords = {
        description = "Set PostgreSQL passwords for app databases";
        after = [ "postgresql.service" "postgresql-setup.service" ];
        requires = [ "postgresql.service" "postgresql-setup.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: ''
          DB_PASS=$(${deriveDbPassword name})
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

  # Register Headscale DNS overrides so tailnet peers resolve tailscale-only
  # domains to the server's Tailscale IP. This makes traffic route through the
  # tunnel, so nginx sees a Tailscale source IP and the allow rule passes.
  # Public DNS still points to the server's public IP (for ACME HTTP-01).
  services.headscale.settings.dns.extra_records =
    lib.mapAttrsToList (_: app: {
      name = app.domain;
      type = "A";
      value = serverTailscaleIp;
    }) tailscaleApps;

  # Route *.theor.net DNS queries through the Tailscale DNS proxy on clients.
  # Without this, macOS only routes MagicDNS queries (*.ts.theor.net) through
  # Tailscale, so extra_records for other domains are never consulted.
  # The proxy checks extra_records first (returning the Tailscale IP), then
  # forwards non-overridden names to these upstream resolvers as normal.
  services.headscale.settings.dns.nameservers.split = lib.mkIf (tailscaleApps != { }) {
    "theor.net" = [ "1.1.1.1" "9.9.9.9" ];
  };
}

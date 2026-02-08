{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Import generated apps from YAML files
  appsGenerated = import ../apps/apps.lock.nix;

  # Check if image is from registry
  isRegistryImage = image: ! lib.hasPrefix "local/" image;

  # Registry apps for auto-update
  registryApps = lib.filterAttrs (_: app: isRegistryImage app.image) appsGenerated;

  autoUpdateScript = pkgs.writeShellScript "docker-auto-update" ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: app: ''
      echo "Checking ${name}..."
      OLD=$(${pkgs.docker}/bin/docker image inspect --format '{{.Id}}' "${app.image}" 2>/dev/null || echo "none")
      if ${pkgs.docker}/bin/docker pull "${app.image}"; then
        NEW=$(${pkgs.docker}/bin/docker image inspect --format '{{.Id}}' "${app.image}")
        if [ "$OLD" != "$NEW" ]; then
          echo "${name}: image updated, restarting..."
          ${pkgs.systemd}/bin/systemctl restart "${name}"
        else
          echo "${name}: up to date"
        fi
      else
        echo "${name}: pull failed, skipping"
      fi
    '') registryApps)}
  '';

  mkDockerService = name: app: {
    name = name;
    value = {
      description = "${name} Docker container";
      after = [
        "docker.service"
        "network-online.target"
      ];
      requires = [ "docker.service" ];
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

        ExecStart = ''
          ${pkgs.docker}/bin/docker run --rm \
            --name ${name} \
            -p 127.0.0.1:${toString app.hostPort}:${toString app.containerPort} \
            ${app.image}
        '';

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
  sops.secrets.ghcr_username = {
    sopsFile = ../secrets/secrets.yaml;
  };
  sops.secrets.ghcr_token = {
    sopsFile = ../secrets/secrets.yaml;
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

  # Docker services for app containers
  systemd.services = lib.listToAttrs (lib.mapAttrsToList mkDockerService appsGenerated) // {
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
  };

  # Auto-update timer: checks for new registry images every 5 minutes
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

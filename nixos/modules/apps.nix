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

        ExecStartPre = lib.mkMerge [
          [
            "-${pkgs.docker}/bin/docker stop ${name}"
            "-${pkgs.docker}/bin/docker rm ${name}"
          ]
          # Only pull registry images, not local ones
          (lib.optional (isRegistryImage app.image) 
            "${pkgs.docker}/bin/docker pull ${app.image}")
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
  # Update containers by running: systemctl restart <app-name>
  # Or deploy with: nixos-rebuild switch (pulls new images on service start)
  systemd.services = lib.listToAttrs (lib.mapAttrsToList mkDockerService appsGenerated);

  services.nginx.virtualHosts = lib.mkMerge (lib.mapAttrsToList mkProxyVhost appsGenerated);
}

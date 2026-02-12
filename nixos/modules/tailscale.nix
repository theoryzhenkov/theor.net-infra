{
  config,
  pkgs,
  lib,
  ...
}:

let
  headscaleUrl = "https://headscale.theor.net";
  authKeyPath = "/var/lib/headscale/server-authkey";

  # Headscale users to ensure exist (idempotent)
  headscaleUsers = [ "theo" ];
in
{
  services.tailscale = {
    enable = true;
    authKeyFile = authKeyPath;
    extraUpFlags = [
      "--login-server" headscaleUrl
    ];
  };

  # Bootstrap headscale state and generate a pre-auth key for this server.
  # Fully declarative: on a fresh server, headscale starts with an empty DB,
  # this service creates the user and a reusable auth key, then tailscale
  # uses that key to join the mesh automatically.
  systemd.services.headscale-setup = {
    description = "Bootstrap Headscale users and server auth key";
    after = [ "headscale.service" ];
    requires = [ "headscale.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [ config.services.headscale.package pkgs.jq ];

    script = ''
      # Wait for headscale API to be ready
      for i in $(seq 1 30); do
        if headscale users list > /dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      # Ensure users exist (idempotent — errors on existing users are ignored)
      ${lib.concatMapStringsSep "\n" (user: ''
        headscale users create ${user} 2>/dev/null || true
      '') headscaleUsers}

      # Generate a pre-auth key for the server to join the mesh
      KEY=$(headscale preauthkeys create --user ${builtins.head headscaleUsers} --reusable --expiration 87600h --output json | jq -r '.key')
      echo "$KEY" > ${authKeyPath}
      chmod 600 ${authKeyPath}
    '';
  };

  # Tailscale must wait for the auth key to exist before trying to connect
  systemd.services.tailscaled = {
    after = [ "headscale-setup.service" ];
    wants = [ "headscale-setup.service" ];
  };

  # Trust the Tailscale interface — allow all traffic from mesh peers
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}

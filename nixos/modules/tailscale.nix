{
  config,
  pkgs,
  lib,
  ...
}:

let
  headscaleUrl = "https://headscale.theor.net";

  # Headscale users to ensure exist (idempotent)
  headscaleUsers = [ "admin" ];
in
{
  services.tailscale.enable = true;
  # No authKeyFile — we handle auth ourselves in headscale-setup to avoid
  # the tailscaled-autoconnect service and its tight timeout.

  # Bootstrap headscale state and connect this server to the mesh.
  # Fully declarative: on a fresh server, headscale starts with an empty DB,
  # this service creates the user, generates a pre-auth key, and runs
  # tailscale up to join the mesh automatically.
  systemd.services.headscale-setup = {
    description = "Bootstrap Headscale and connect server to mesh";
    after = [ "headscale.service" "tailscaled.service" ];
    requires = [ "headscale.service" "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [
      config.services.headscale.package
      config.services.tailscale.package
      pkgs.jq
    ];

    script = let
      primaryUser = builtins.head headscaleUsers;
    in ''
      # Wait for headscale API to be ready
      for i in $(seq 1 30); do
        if headscale users list > /dev/null 2>&1; then
          break
        fi
        sleep 1
      done

      # Ensure users exist (idempotent)
      ${lib.concatMapStringsSep "\n" (user: ''
        headscale users create ${user} 2>/dev/null || true
      '') headscaleUsers}

      # Skip if already connected to the mesh
      STATUS=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty')
      if [ "$STATUS" = "Running" ]; then
        echo "Already connected to Tailscale mesh"
        exit 0
      fi

      # Look up the numeric user ID (headscale CLI requires --user as uint)
      USER_ID=$(headscale users list --output json | jq -r '.[] | select(.name == "${primaryUser}") | .id')
      if [ -z "$USER_ID" ]; then
        echo "Failed to find user ID for ${primaryUser}" >&2
        exit 1
      fi

      # Generate a pre-auth key using the numeric user ID
      KEY=$(headscale preauthkeys create --user "$USER_ID" --reusable --expiration 87600h --output json | jq -r '.key')

      if [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
        echo "Failed to create pre-auth key" >&2
        exit 1
      fi

      echo "Joining Tailscale mesh via ${headscaleUrl}..."
      tailscale up --login-server=${headscaleUrl} --authkey="$KEY"
    '';
  };

  # Trust the Tailscale interface — allow all traffic from mesh peers
  networking.firewall.trustedInterfaces = [ "tailscale0" ];
}

{ config, pkgs, lib, ... }:

let
  # Hetzner Cloud Volume ID — update after first `terraform apply`
  # Find with: terraform output data_volume_id
  volumeId = "CHANGE_ME";
in
{
  # Mount the Hetzner Cloud Volume for persistent data
  fileSystems."/mnt/data" = {
    device = "/dev/disk/by-id/scsi-0HC_Volume_${volumeId}";
    fsType = "ext4";
    options = [ "defaults" "nofail" ];
  };

  services.postgresql = {
    enable = true;
    dataDir = "/mnt/data/postgresql/17";

    settings = {
      listen_addresses = "127.0.0.1,172.17.0.1"; # localhost + docker bridge
      max_connections = 100;
    };

    authentication = lib.mkForce ''
      # Local Unix socket — peer auth (for admin/backup scripts)
      local all all              peer
      # TCP from localhost — password auth (for Docker containers via host.docker.internal)
      host  all all 127.0.0.1/32  scram-sha-256
      # TCP from Docker bridge network
      host  all all 172.17.0.0/16 scram-sha-256
    '';
  };

  # Ensure PostgreSQL starts after the volume is mounted
  systemd.services.postgresql = {
    after = [ "mnt-data.mount" ];
    requires = [ "mnt-data.mount" ];
  };
}

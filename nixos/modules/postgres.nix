{ config, pkgs, lib, ... }:

let
  # Hetzner Cloud Volume ID — update after first `terraform apply`
  # Find with: terraform output data_volume_id
  volumeId = "104621702";
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
    package = pkgs.postgresql_16;
    dataDir = "/mnt/data/postgresql/16";

    settings = {
      listen_addresses = lib.mkForce "127.0.0.1,172.17.0.1"; # localhost + docker bridge
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

  # Ensure PostgreSQL starts after the volume is mounted,
  # and create the data directory if it doesn't exist yet
  systemd.services.postgresql = {
    after = [ "mnt-data.mount" ];
    requires = [ "mnt-data.mount" ];
    preStart = lib.mkBefore ''
      install -d -m 0700 -o postgres -g postgres /mnt/data/postgresql
    '';
  };
}

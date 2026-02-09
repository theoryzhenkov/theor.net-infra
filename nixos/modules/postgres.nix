{ config, pkgs, lib, ... }:

{
  # Mount the Hetzner Cloud Volume for persistent data (labeled by Terraform)
  fileSystems."/mnt/data" = {
    device = "/dev/disk/by-label/theor-net-data-1";
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

  # Create the data directory on the volume before PostgreSQL starts.
  # Must be a separate service because PostgreSQL's systemd namespace setup
  # (ReadWritePaths) fails if the target directory doesn't exist yet.
  systemd.services.postgresql-datadir-init = {
    description = "Create PostgreSQL data directory on volume";
    after = [ "mnt-data.mount" ];
    requires = [ "mnt-data.mount" ];
    before = [ "postgresql.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/install -d -m 0700 -o postgres -g postgres /mnt/data/postgresql/16";
    };
  };

  systemd.services.postgresql = {
    after = [ "mnt-data.mount" "postgresql-datadir-init.service" ];
    requires = [ "mnt-data.mount" "postgresql-datadir-init.service" ];
  };
}

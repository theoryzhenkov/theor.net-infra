{ config, pkgs, lib, ... }:

let
  backupDir = "/mnt/data/backups/postgresql";
  localRetentionDays = 7;

  backupScript = pkgs.writeShellScript "pg-backup" ''
    set -euo pipefail

    TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    BACKUP_FILE="${backupDir}/pg-dumpall-$TIMESTAMP.sql.gz"

    mkdir -p ${backupDir}

    echo "Starting PostgreSQL backup: $BACKUP_FILE"
    ${pkgs.util-linux}/bin/runuser -u postgres -- \
      ${config.services.postgresql.package}/bin/pg_dumpall | \
      ${pkgs.gzip}/bin/gzip > "$BACKUP_FILE"

    echo "Backup complete: $(du -h "$BACKUP_FILE" | cut -f1)"

    # Upload to Backblaze B2 via rclone
    B2_KEY_ID=$(cat ${config.sops.secrets.b2_key_id.path})
    B2_APP_KEY=$(cat ${config.sops.secrets.b2_app_key.path})
    B2_BUCKET=$(cat ${config.sops.secrets.b2_bucket.path})

    export RCLONE_CONFIG_B2_TYPE=b2
    export RCLONE_CONFIG_B2_ACCOUNT="$B2_KEY_ID"
    export RCLONE_CONFIG_B2_KEY="$B2_APP_KEY"

    echo "Uploading to B2: $B2_BUCKET"
    ${pkgs.rclone}/bin/rclone copy "$BACKUP_FILE" "b2:$B2_BUCKET/"

    echo "Upload complete"

    # Clean up old local backups
    echo "Removing local backups older than ${toString localRetentionDays} days..."
    ${pkgs.findutils}/bin/find ${backupDir} -name "pg-dumpall-*.sql.gz" \
      -mtime +${toString localRetentionDays} -delete

    echo "Backup finished successfully"
  '';

in
{
  sops.secrets.b2_key_id = {
    sopsFile = ../secrets/secrets.yaml;
  };
  sops.secrets.b2_app_key = {
    sopsFile = ../secrets/secrets.yaml;
  };
  sops.secrets.b2_bucket = {
    sopsFile = ../secrets/secrets.yaml;
  };

  systemd.services.pg-backup = {
    description = "PostgreSQL backup to Backblaze B2";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = backupScript;
    };
  };

  systemd.timers.pg-backup = {
    description = "Daily PostgreSQL backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00"; # Daily at 03:00 UTC
      Persistent = true; # Catch up if server was off
      RandomizedDelaySec = "5min";
    };
  };
}

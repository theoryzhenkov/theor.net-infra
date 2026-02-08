#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Get server IP from terraform
SERVER_IP=$(terraform -chdir="$PROJECT_ROOT/terraform" output -raw server_ip)
if [[ -z "$SERVER_IP" ]]; then
  echo "ERROR: Could not retrieve server IP. Have you run 'terraform apply'?" >&2
  exit 1
fi
echo "Server IP: $SERVER_IP"

# Decrypt the age private key from terraform secrets
AGE_KEY=$(SOPS_AGE_KEY_FILE="$PROJECT_ROOT/.age-key.txt" sops -d --extract '["sops_age_private_key"]' "$PROJECT_ROOT/terraform/secrets.enc.yaml")

# Create temp directory with sops-nix key structure
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/var/lib/sops-nix"
echo "$AGE_KEY" > "$TMPDIR/var/lib/sops-nix/key.txt"
chmod 600 "$TMPDIR/var/lib/sops-nix/key.txt"

echo "Provisioning NixOS on $SERVER_IP..."
nix run github:nix-community/nixos-anywhere -- \
  --extra-files "$TMPDIR" \
  --flake "$PROJECT_ROOT/nixos#hetzner-theor-net-web-1" \
  --build-on remote \
  "root@$SERVER_IP"

echo "Provisioning complete!"

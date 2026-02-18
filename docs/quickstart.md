# Quickstart

Bootstrap the infrastructure from scratch.

## Prerequisites

- [Nix](https://nixos.org/download) with flakes enabled
- [direnv](https://direnv.net/) (recommended) or `nix develop`
- A Hetzner Cloud account
- A Porkbun account with the `theor.net` domain
- A Backblaze B2 account

## 1. Clone and Enter Dev Shell

```bash
git clone git@github.com:theoryzhenkov/theor.net-infra.git
cd theor.net-infra

# Option A: direnv (auto-activates on cd)
direnv allow

# Option B: manual
nix develop
```

The dev shell provides: `terraform`, `sops`, `age`, `just`, `deploy-rs`, and other tools.

## 2. Generate Age Key

```bash
age-keygen -o .age-key.txt
```

This key encrypts/decrypts all SOPS secrets locally. It is gitignored.

Note the public key from the output — you'll need it for the `.sops.yaml` files.

### Update .sops.yaml files

Replace the `&local` / `&project` key references with your new public key:

- `terraform/.sops.yaml` — update `&project`
- `nixos/.sops.yaml` — update `&local`

## 3. Set Up Terraform Secrets

```bash
cd terraform
sops secrets/secrets.enc.yaml
```

Add the following keys:

```yaml
hcloud_token: "your-hetzner-api-token"
porkbun_api_key: "your-porkbun-api-key"
porkbun_secret_api_key: "your-porkbun-secret-key"
b2_key_id: "your-backblaze-key-id"
b2_app_key: "your-backblaze-app-key"
sops_age_private_key: |
  # paste the full contents of .age-key.txt here
  # (used to provision the server's age key)
```

## 4. Terraform Init and Apply

```bash
just terraform init
just terraform plan    # review changes
just terraform apply   # create all resources
```

This creates the Hetzner server, static IP, firewall, volume, DNS records, and B2 bucket.

## 5. Set Up NixOS Secrets

First, get the server's age public key. After Terraform creates the server, SSH in and generate one:

```bash
ssh root@$(just terraform output -raw server_ip)
# On the server:
age-keygen -o /var/lib/sops-nix/key.txt
age-keygen -y /var/lib/sops-nix/key.txt  # prints public key
```

Update `nixos/.sops.yaml` with the server's public key (`&server`).

Then create the NixOS secrets:

```bash
cd nixos
sops secrets/secrets.enc.yaml
```

Add the required secrets:

```yaml
# GHCR authentication (for pulling private Docker images)
ghcr_username: "your-github-username"
ghcr_token: "ghp_your-github-token"

# Backblaze B2 (for PostgreSQL backups)
b2_key_id: "your-backblaze-key-id"
b2_app_key: "your-backblaze-app-key"
b2_bucket: "theor-net-pg-backups"

# Authelia secrets
authelia_jwt_secret: "generate-a-random-string"
authelia_session_secret: "generate-a-random-string"
authelia_storage_encryption_key: "generate-a-random-string"
authelia_oidc_hmac_secret: "generate-a-random-string"
authelia_oidc_private_key: |
  -----BEGIN RSA PRIVATE KEY-----
  ...generate with: openssl genrsa 4096...
  -----END RSA PRIVATE KEY-----

# Shared between Authelia and Headscale
headscale_oidc_client_secret: "generate-a-random-string"
```

!!! tip
Generate random secrets with: `openssl rand -hex 32`

## 6. Initial Provisioning

```bash
just nixos setup
```

This runs `nixos-anywhere` which:

1. Boots the server into a kexec installer
2. Partitions disks according to `disk-config.nix`
3. Copies the age key to `/var/lib/sops-nix/key.txt`
4. Installs the full NixOS configuration
5. Reboots into the final system

## 7. Subsequent Deploys

After changing any NixOS configuration:

```bash
just nixos deploy
```

This uses `deploy-rs` to build and activate the new configuration on the remote server.

## 8. Add Your First App

```bash
just nixos app create my-app
# Edit nixos/apps/my-app/app.yaml with your image and domain
just nixos app generate
just nixos deploy
```

See the [App Management](apps.md) guide for details on databases, secrets, and Tailscale-only apps.

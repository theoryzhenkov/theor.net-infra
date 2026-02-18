# Architecture

## High-Level Overview

```
┌─────────────────────────────────────────────────────────┐
│                    theor.net-infra repo                  │
│                                                         │
│  ┌──────────────┐    ┌──────────────────────────────┐   │
│  │  Terraform    │    │  NixOS                        │   │
│  │              │    │                              │   │
│  │  Hetzner     │    │  nginx ─── ACME (TLS)        │   │
│  │  • Server    │    │  PostgreSQL on volume         │   │
│  │  • IP        │    │  Authelia (SSO/OIDC)          │   │
│  │  • Firewall  │    │  Headscale + Tailscale        │   │
│  │  • Volume    │    │  Docker app containers        │   │
│  │              │    │                              │   │
│  │  Porkbun DNS │    │  deploy-rs (remote deploy)    │   │
│  │  Backblaze B2│    │  sops-nix (secrets)           │   │
│  └──────────────┘    └──────────────────────────────┘   │
│                                                         │
│                    ▼ deploys to ▼                        │
│                                                         │
│           Hetzner Cloud  ·  nbg1  ·  cx33               │
│           hetzner-theor-net-web-1                        │
└─────────────────────────────────────────────────────────┘
```

## Terraform Layer

Terraform manages all cloud resources. State is stored locally (no remote backend).

### Resources

| Resource                     | Type      | Purpose                                                  |
| ---------------------------- | --------- | -------------------------------------------------------- |
| `hcloud_server.web`          | Server    | cx33 in nbg1, Ubuntu 24.04 base image                    |
| `hcloud_primary_ip.web_ipv4` | Static IP | Persistent IPv4 (survives server rebuilds)               |
| `hcloud_firewall.web`        | Firewall  | Allows SSH (22), HTTP (80), HTTPS (443), STUN (3478/udp) |
| `hcloud_ssh_key.deploy`      | SSH Key   | ed25519 deploy key                                       |
| `hcloud_volume.data`         | Volume    | 10 GB ext4, labeled `theor-net-data-1` (PostgreSQL data) |
| `b2_bucket.pg_backups`       | B2 Bucket | `theor-net-pg-backups`, 30-day lifecycle                 |
| `porkbun_dns_record.*`       | DNS       | A/AAAA records for theor.net, subdomains, and wildcards  |

### Providers

| Provider  | Auth Source                                    |
| --------- | ---------------------------------------------- |
| `hcloud`  | `hcloud_token` from `secrets/secrets.enc.yaml` |
| `porkbun` | `porkbun_api_key` + `porkbun_secret_api_key`   |
| `b2`      | `b2_key_id` + `b2_app_key`                     |

### Secrets

Terraform secrets are in `terraform/secrets/secrets.enc.yaml`, encrypted with a single project age key (defined in `terraform/.sops.yaml`). Only the local operator needs to decrypt these — the server never touches Terraform secrets.

## NixOS Layer

The NixOS configuration is a flake at `nixos/flake.nix`.

### Flake Inputs

| Input       | Purpose                                                 |
| ----------- | ------------------------------------------------------- |
| `nixpkgs`   | nixos-unstable channel                                  |
| `disko`     | Declarative disk partitioning                           |
| `sops-nix`  | Secrets management (age-encrypted, decrypted on server) |
| `deploy-rs` | Remote NixOS deployment tool                            |

### Modules

| Module          | Purpose                                                                  |
| --------------- | ------------------------------------------------------------------------ |
| `nginx.nix`     | Reverse proxy with gzip, TLS, proxy headers, HSTS                        |
| `acme.nix`      | Let's Encrypt via HTTP-01 challenge                                      |
| `apps.nix`      | Generates systemd services + nginx vhosts from `app.yaml` files          |
| `postgres.nix`  | PostgreSQL 16 on persistent Hetzner volume (`/mnt/data`)                 |
| `pg-backup.nix` | Daily `pg_dumpall` → gzip → Backblaze B2 (7-day local retention)         |
| `authelia.nix`  | SSO server with OIDC provider, file-based user DB, Argon2 passwords      |
| `headscale.nix` | Self-hosted Tailscale control plane with DERP relay, OIDC via Authelia   |
| `tailscale.nix` | Joins the server to the Headscale mesh, bootstraps users + pre-auth keys |

### Deploy Workflow

```bash
# Initial provisioning (nixos-anywhere)
just nixos setup

# Subsequent configuration updates
just nixos deploy
```

`deploy-rs` builds the NixOS closure on the remote server and activates it. The `--skip-checks` flag is used since checks require local x86_64-linux evaluation.

## App Deployment Model

Apps are Docker containers defined by `app.yaml` files in `nixos/apps/<name>/`.

### App Lifecycle

1. Create app config: `just nixos app create <name>`
2. Edit `app.yaml` (image, domain, ports, dependencies)
3. Generate NixOS config: `just nixos app generate` (produces `apps.lock.nix`)
4. Deploy: `just nixos deploy` (applies NixOS config with new systemd services)
5. Auto-update: a systemd timer checks for new Docker images every 5 minutes

### app.yaml Schema

```yaml
app: my-app # required: app name
image: ghcr.io/org/repo/name:latest # required: Docker image
containerPort: 3000 # required: port inside container
hostPort: 8102 # required: port on host (127.0.0.1)
domain: my-app.theor.net # required: nginx vhost domain
depends: # optional
  database: postgresql #   provisions DB + user + env var
network: tailscale # optional: restrict to Tailscale IPs
```

### What Gets Generated

For each app, `apps.nix` produces:

- **systemd service**: pulls image, decrypts secrets, injects `DATABASE_URL`, runs `docker run`
- **nginx vhost**: reverse proxy with ACME TLS, WebSocket support, optional Tailscale IP restriction
- **PostgreSQL database + user** (if `depends.database: postgresql`)
- **Headscale DNS override** (if `network: tailscale`) — routes domain through Tailscale tunnel

### Auto-Update

The `docker-auto-update` systemd timer runs every 5 minutes:

1. Pulls latest image for each app
2. Compares image IDs (old vs new)
3. Restarts only apps whose images changed

## Secrets Management

Secrets use [SOPS](https://github.com/getsops/sops) with [age](https://github.com/FiloSottile/age) encryption.

### Two Encryption Scopes

| Scope         | File                                                               | Keys                             | Purpose                                                |
| ------------- | ------------------------------------------------------------------ | -------------------------------- | ------------------------------------------------------ |
| **Terraform** | `terraform/secrets/secrets.enc.yaml`                               | Project age key only             | Cloud provider API tokens (hcloud, porkbun, b2)        |
| **NixOS**     | `nixos/secrets/secrets.enc.yaml` + `nixos/apps/*/secrets.enc.yaml` | Server age key + project age key | Runtime secrets (GHCR auth, Authelia, B2 backup, OIDC) |

The Terraform scope only needs the local operator's key. The NixOS scope requires both the local key (for editing) and the server's key (for runtime decryption via `sops-nix`).

### Key Management

- **Project age key**: stored in `.age-key.txt` (gitignored), referenced by `SOPS_AGE_KEY_FILE` in `.envrc`
- **Server age key**: provisioned during `nixos-anywhere` setup to `/var/lib/sops-nix/key.txt`

### Deterministic Database Passwords

App database passwords are not stored as secrets. Instead, they are derived at runtime:

```
HMAC-SHA256(server_age_key, "db-password:<app-name>")
```

Both the `pg-set-passwords` service and each app's start script use the same derivation, so passwords always match without external coordination.

## Networking

### Public Access

```
Internet → Hetzner Firewall (22/80/443/3478)
         → nginx (TLS termination via ACME)
         → 127.0.0.1:<hostPort> (Docker container)
```

All public apps get automatic HTTPS via Let's Encrypt HTTP-01 challenges. nginx handles reverse proxying with WebSocket support, gzip compression, and HSTS headers.

### Tailscale Mesh

```
Headscale (control plane, headscale.theor.net)
  ├── DERP relay (built-in, port 3478/udp STUN)
  ├── OIDC auth via Authelia (auth.theor.net)
  └── DNS: *.ts.theor.net (MagicDNS)

Server joins mesh automatically via headscale-setup service
  → creates user, generates pre-auth key, runs tailscale up
```

**Tailscale-only apps**: nginx still serves them on the public IP (for ACME), but restricts access to Tailscale IPs (`100.64.0.0/10`). Headscale's DNS `extra_records` override the domain to resolve to the server's Tailscale IP (`100.64.0.2`) for mesh peers, and a `split` DNS rule routes `*.theor.net` queries through the Tailscale DNS proxy.

### Authentication

[Authelia](https://www.authelia.com/) runs as an SSO server at `auth.theor.net`:

- File-based user database with Argon2 password hashing
- OIDC provider for Headscale (PKCE with S256)
- One-factor default policy
- Session cookies scoped to `theor.net`

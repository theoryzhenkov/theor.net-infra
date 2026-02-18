# theor.net Infrastructure

Single-server infrastructure for **theor.net** — Terraform provisioning, NixOS configuration, and declarative app deployment on Hetzner Cloud.

## Layers

| Layer         | Purpose                                                                           | Directory     |
| ------------- | --------------------------------------------------------------------------------- | ------------- |
| **Terraform** | Provisions Hetzner server, IP, firewall, volume, DNS records, Backblaze B2 bucket | `terraform/`  |
| **NixOS**     | Configures the server: nginx, PostgreSQL, ACME, Headscale, Authelia, Tailscale    | `nixos/`      |
| **Apps**      | Docker containers defined via `app.yaml`, auto-updated every 5 minutes            | `nixos/apps/` |

## Quick Links

- [Architecture Overview](architecture.md) — how the layers fit together
- [Quickstart Guide](quickstart.md) — bootstrap from scratch
- [App Management](apps.md) — add, deploy, and manage apps

## Repository Structure

```
.
├── flake.nix                  # Root flake (composes nixos + terraform dev shells)
├── justfile                   # Top-level task runner
├── scripts/
│   └── provision.sh           # nixos-anywhere initial provisioning
├── terraform/
│   ├── flake.nix              # Terraform dev shell (terraform, sops, age)
│   ├── main.tf                # All Terraform resources
│   ├── variables.tf           # Server name, type, location
│   ├── outputs.tf             # Server IP, ID, status, volume ID
│   ├── secrets/
│   │   └── secrets.enc.yaml   # Encrypted: hcloud, porkbun, b2 credentials
│   └── .sops.yaml             # Encryption rules (project age key only)
└── nixos/
    ├── flake.nix              # NixOS flake (nixpkgs, disko, sops-nix, deploy-rs)
    ├── configuration.nix      # Server config: imports all modules
    ├── disk-config.nix        # Disko disk layout
    ├── hardware-configuration.nix
    ├── modules/
    │   ├── nginx.nix          # Reverse proxy with recommended settings
    │   ├── acme.nix           # Let's Encrypt certificate automation
    │   ├── apps.nix           # Docker container orchestration from app.yaml
    │   ├── postgres.nix       # PostgreSQL on persistent volume
    │   ├── pg-backup.nix      # Daily backups to Backblaze B2
    │   ├── authelia.nix       # SSO/OIDC authentication server
    │   ├── headscale.nix      # Self-hosted Tailscale control plane
    │   └── tailscale.nix      # Mesh networking + server auto-join
    ├── apps/
    │   ├── apps.lock.nix      # Auto-generated from app.yaml files
    │   └── <app-name>/
    │       ├── app.yaml       # App definition
    │       └── secrets.enc.yaml  # Optional encrypted secrets
    ├── secrets/
    │   └── secrets.enc.yaml   # Encrypted: GHCR, Authelia, B2, OIDC secrets
    ├── scripts/
    │   └── app.sh             # App management CLI
    └── .sops.yaml             # Encryption rules (server + local age keys)
```

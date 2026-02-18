# App Management

Apps are Docker containers managed through `app.yaml` declarations. The CLI is available via `just nixos app <command>`.

## CLI Commands

| Command                         | Description                                          |
| ------------------------------- | ---------------------------------------------------- |
| `just nixos app create <name>`  | Scaffold a new app directory with `app.yaml`         |
| `just nixos app generate`       | Regenerate `apps.lock.nix` from all `app.yaml` files |
| `just nixos app deploy <name>`  | Pull latest image and restart on the server          |
| `just nixos app remove <name>`  | Stop service and optionally delete config            |
| `just nixos app list`           | List all apps with their config                      |
| `just nixos app status [name]`  | Show systemd service status (one or all)             |
| `just nixos app logs <name>`    | Tail journald logs for an app                        |
| `just nixos app secrets <name>` | Edit SOPS-encrypted secrets for an app               |

## Adding an App

### Basic App

```bash
just nixos app create my-app
```

Edit `nixos/apps/my-app/app.yaml`:

```yaml
app: my-app
image: ghcr.io/theoryzhenkov/my-app/my-app:latest
containerPort: 3000
hostPort: 8103
domain: my-app.theor.net
```

Then generate and deploy:

```bash
just nixos app generate
just nixos deploy
```

!!! note
You also need a DNS record pointing `my-app.theor.net` to the server's IP. Add a `porkbun_dns_record` resource in `terraform/main.tf` and run `just terraform apply`.

### App with PostgreSQL

Add a database dependency to `app.yaml`:

```yaml
app: my-app
image: ghcr.io/theoryzhenkov/my-app/my-app:latest
containerPort: 3000
hostPort: 8103
domain: my-app.theor.net
depends:
  database: postgresql
```

This automatically:

- Creates a PostgreSQL database named `my-app`
- Creates a PostgreSQL user named `my-app`
- Derives a deterministic password from the server's age key
- Injects `DATABASE_URL=postgresql://my-app:<password>@host.docker.internal:5432/my-app` as an environment variable

No manual password management required.

### App with Secrets

Create encrypted secrets:

```bash
just nixos app secrets my-app
```

This opens `$EDITOR` with a SOPS-encrypted YAML file. Add flat key-value pairs:

```yaml
API_KEY: "sk-..."
WEBHOOK_SECRET: "whsec_..."
```

After saving, regenerate and deploy:

```bash
just nixos app generate
just nixos deploy
```

Secrets are decrypted at container start and passed as environment variables via `--env-file`.

### Tailscale-Only App

Restrict access to Tailscale mesh peers:

```yaml
app: private-app
image: ghcr.io/theoryzhenkov/private-app/private-app:latest
containerPort: 80
hostPort: 8200
domain: private.theor.net
network: tailscale
```

This:

- Configures nginx to only allow connections from `100.64.0.0/10` (Tailscale IPs)
- Registers a Headscale DNS override so mesh peers resolve the domain to the server's Tailscale IP
- Adds a split DNS rule so `*.theor.net` queries route through the Tailscale DNS proxy

!!! warning
You still need a public DNS record for the domain (for ACME certificate issuance). Non-Tailscale clients will get a `403 Forbidden` response.

## Auto-Update

A systemd timer (`docker-auto-update`) runs every 5 minutes:

1. Pulls the latest image for each app
2. Compares the image ID before and after
3. Restarts only apps whose images actually changed

Check update logs:

```bash
ssh hetzner-theor.net-web-1 'journalctl -u docker-auto-update --no-pager -n 50'
```

!!! info
Image updates restart containers automatically. Configuration changes (secrets, ports, dependencies) require `just nixos deploy`.

## Workflow Summary

```
┌─────────────────────────────┐
│  1. just nixos app create   │  Scaffold app.yaml
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  2. Edit app.yaml           │  Set image, domain, ports, deps
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  3. just nixos app generate │  Update apps.lock.nix
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  4. just nixos deploy       │  Apply NixOS config to server
└──────────────┬──────────────┘
               ▼
┌─────────────────────────────┐
│  5. Auto-update (5 min)     │  Pulls new images, restarts
└─────────────────────────────┘
```

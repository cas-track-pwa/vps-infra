# vps-infra

Provisioning and configuration for self-hosting **Time Tracker** and **ITFlow** on
a single Debian 13 VPS that is reachable only over Tailscale.

This repo holds no application code and no secrets. It automates and centralizes
the config from [`time-tracker/docs/debian-13-vps.md`](https://github.com/cas-track-pwa/time-tracker/blob/master/docs/debian-13-vps.md)
(that guide remains the long-form reference).

## What runs

| Component | How | Where |
|---|---|---|
| Time Tracker PWA | static files | `/srv/tracker` |
| Time Tracker bridge | PHP-FPM | `/srv/tracker/itflow_create_invoice.php` |
| Sync API | Node + SQLite | `/opt/time-tracker/server` (systemd `tt-sync`) |
| ITFlow | Apache + PHP + MariaDB | `/var/www/itflow` (loopback only) |
| Front door / TLS | Caddy + `caddy-tailscale` (DNS-01) | `tracker.<tailnet>`, `itflow.<tailnet>` |

No public ports are opened; TLS is issued via Tailscale's DNS-01 handling.

## Layout

```
.env.example              # every variable, no secrets (copy to .env)
caddy/Caddyfile           # front door -> /srv/tracker, sync :8787, itflow :8080
systemd/tt-sync.service   # sync API unit
tracker/config.php.example
itflow/install-endpoint.sh
scripts/provision.sh      # base + tailscale + node + sync + caddy + tracker
scripts/backup.sh         # sqlite + mariadb + uploads -> restic/rclone
scripts/healthcheck.sh
Makefile                  # make sync | tracker | caddy | backup | healthcheck
docs/deployment.md        # step-by-step, matches the time-tracker guide
.github/workflows/deploy.yml
```

## Quick start

On the fresh VPS, as your sudo user:

```bash
sudo apt update && sudo apt install -y git
git clone <this-repo> ~/vps-infra
cd ~/vps-infra
cp .env.example .env && nano .env      # set tailnet, hosts, secrets, repo URL
sudo ./scripts/provision.sh
```

`provision.sh` covers base hardening, Tailscale, Node + the sync service, Caddy,
and the tracker/bridge files. ITFlow's own installer is interactive, so the script
prints the ITFlow steps at the end rather than driving them.

## Relationship to the app repos

- `time-tracker` (pinned tag/branch) supplies `public/` and `integrations/bridge/`,
  and the sync service at `server/`.
- `itflow` fork supplies `api/v1/invoices/create.php` on the `invoice-create-api`
  branch.

Update flow: pull the app repos to new tags/branches, then re-run the relevant
`provision.sh` step (or the `Makefile` target) to redeploy.

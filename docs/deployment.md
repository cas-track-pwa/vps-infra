# Deployment runbook

Condensed companion to [`time-tracker/docs/debian-13-vps.md`](https://github.com/cas-track-pwa/time-tracker/blob/master/docs/debian-13-vps.md),
which has the long-form explanation. This is the operational short version.

> Bringing this up for real business use? Also read
> [`architecture-review.md`](architecture-review.md) — Stripe webhook
> reachability, outbound email, backups/restore, 2FA, RustDesk and monitoring are
> **not** covered by `provision.sh`.

## Prerequisites

- Fresh Debian 13 VPS, a sudo user, SSH key access.
- A Tailscale account. In the admin console enable **MagicDNS** and
  **DNS → HTTPS Certificates**. No public ports are needed.
- An ITFlow API key (Admin → API), tied to a user with the **Sales** module at
  create level and access to the target client.

## 1. Configure

```bash
git clone <this-repo> ~/vps-infra && cd ~/vps-infra
cp .env.example .env
nano .env            # TAILNET_NAME, secrets, repo URLs/refs
```

## 2. Provision

```bash
sudo ./scripts/provision.sh
```

This runs, in order: base packages + ufw (SSH only) → `ttsync` user → Tailscale →
Node 22 → sync service (clone, `npm ci`, `.env`, `init-db`, systemd) → tracker
PWA + bridge (with `API_BASE` rewritten to same-origin) → Caddy with the
`caddy-tailscale` module → the ITFlow endpoint if the webroot exists.

Re-run individual pieces after changes:

```bash
sudo ./scripts/provision.sh sync
sudo ./scripts/provision.sh tracker
sudo ./scripts/provision.sh caddy
```

Or via the Makefile: `make sync`, `make tracker`, `make caddy`, `make backup`.

## 3. ITFlow

If ITFlow is not installed yet, do that first (its installer is interactive):

- Apache + PHP 8.4 + MariaDB, Apache bound to loopback (`Listen 127.0.0.1:8080`).
- Import `migrations/001_initial.sql`, then run the in-app DB updates.

Then deploy the fork's endpoint and set the API key:

```bash
sudo -E ./itflow/install-endpoint.sh
```

## 4. Bridge secret

`provision.sh` writes `/srv/tracker/config.php` (mode 640, `www-data`) from
`tracker/config.php.example` with `ITFLOW_API_KEY` and `BRIDGE_TOKEN`. In the app,
open **User → ITFlow Settings** and set:

- Bridge URL: `https://tracker.<tailnet>/itflow_create_invoice.php`
- Bridge Token: the `BRIDGE_TOKEN` from `.env`

## 5. Verify

```bash
TRACKER_URL=https://tracker.<tailnet> ./scripts/healthcheck.sh
```

In the browser: log in, add an entry (sync should go idle), generate a report,
**Push to ITFlow**, and confirm a Draft invoice appears.

## 6. Backups (B2)

`scripts/backup.sh` snapshots SQLite via `.backup`, dumps MariaDB, tars ITFlow
uploads, and pushes to B2 if `RESTIC_REPOSITORY` or `RCLONE_DEST` is set. Install
`restic`/`rclone`, export the credentials (systemd `EnvironmentFile` or a root-only
file), and run it on a timer. Test a restore once.

> Also back up ITFlow's **vault encryption key** separately from the database; a
> DB restore without it is useless. See [`architecture-review.md`](architecture-review.md#3-backups--disaster-recovery).

## 7. Post-bring-up (not automated)

These are required for real use but are deliberately left manual:

- **Outbound email:** configure an SMTP relay in ITFlow and publish
  SPF/DKIM/DMARC, or invoice/reminder email will be blocked.
- **Stripe:** pick a webhook reachability path (Tunnel/Funnel/relay/manual) —
  a tailnet-only host cannot receive Stripe webhooks.
- **RustDesk:** self-host the relay behind the tailnet.
- **Monitoring:** schedule `healthcheck.sh` and alert on failure, disk, certs.
- **2FA / tailnet ACLs** on every control-plane account.

Full detail and an action checklist: [`architecture-review.md`](architecture-review.md).

## Updating

- App code: bump `TIME_TRACKER_REF` / `ITFLOW_REF` in `.env`, then
  `sudo ./scripts/provision.sh sync tracker` and `sudo -E ./itflow/install-endpoint.sh`.
- Bridge/infra config: edit `tracker/config.php.example`, `caddy/Caddyfile`, or
  `.env`, then re-run the matching step.
- Bump `CACHE_NAME` in the PWA's `public/sw.js` whenever `public/` changes, so
  clients pick up new assets.

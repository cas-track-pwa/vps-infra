# Architecture review — gaps & hardening

Review of the planned stack (Time Tracker PWA + self-hosted sync, ITFlow with
Stripe, Novo banking, self-hosted RustDesk, all on one Tailscale-only OVHcloud
Debian 13 VPS). This is a working checklist of what the current provisioning does
**not** yet cover. It complements [`deployment.md`](deployment.md); nothing here
is required for a first bring-up, but each item should be a conscious decision.

Priority order is highest-risk first.

## 1. Stripe webhooks vs. Tailscale-only reachability

**The core conflict.** The stack deliberately exposes no public ports and serves
TLS only on the tailnet. Stripe cannot POST payment webhooks to a
`*.ts.net` host, and clients cannot reach an ITFlow portal that is only on the
tailnet. Decide this before wiring Stripe.

Options:

- **Tunnel only the webhook path.** Cloudflare Tunnel (or `tailscale funnel`)
  publishes one public hostname, and Caddy routes exactly the Stripe endpoint to
  ITFlow. Everything else stays tailnet-only.
- **Public relay.** A tiny public endpoint validates Stripe's signature and
  writes into ITFlow (or into a queue the tailnet pulls).
- **No webhook.** Mark invoices paid manually from the Stripe dashboard.

Client-facing reachability is a separate call: if you want clients to use
ITFlow's client portal or view invoice PDFs online, that path must be public or
handled by Stripe-hosted pages. Email + Stripe Checkout links are the low-surface
default.

Cloudflare Tunnel sketch (public hostname, single path):

```yaml
# cloudflared config.yml (on the VPS, outbound-only tunnel)
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/<tunnel-id>.json
ingress:
  - hostname: pay.example.com
    path: /itflow_webhook.php        # only the Stripe receiver
    service: http://127.0.0.1:8080
  - service: http_status:404
```

Add a matching Caddy `pay.example.com` block that proxies only that path, and
keep `itflow.<tailnet>` unchanged. Verify Stripe's webhook signature in the
receiver; never trust an unauthenticated POST.

## 2. Outbound email deliverability

ITFlow sends invoices, reminders and password resets. A VPS IP sending SMTP
directly will be blocked or spam-foldered. Use an authenticated SMTP relay
(Resend, Postmark, Mailgun, Amazon SES) and configure it as ITFlow's mail
transport.

- Publish **SPF, DKIM and DMARC** for the sending domain (DMARC at least
  `p=none` with reporting, then tighten).
- Send from a real subdomain (e.g. `billing.example.com`) so reputation is
  isolated.
- Add the relay's credentials to the VPS secret store, not to a tracked file.

## 3. Backups & disaster recovery

`scripts/backup.sh` exists but nothing installs `restic`/`rclone`, schedules it,
or proves a restore. For a box holding the **ITFlow credential vault**, this is
the highest-value remaining work.

- Install `restic`/`rclone`, set `RESTIC_REPOSITORY` + `RESTIC_PASSWORD` (or
  `RCLONE_DEST`) via a root-only env file.
- Add a systemd timer for `backup.sh` (daily) and a `restic check` timer.
- **Back up ITFlow's vault encryption key separately from the database.** A DB
  restore without the key is useless; document key-loss recovery.
- Include ITFlow's `config.php` and MariaDB in the backup set (uploads and DB are
  already covered).
- **Rehearse a restore once** onto a scratch host and record the steps here.

## 4. Secrets & identity above the VPS

A takeover of any control-plane account bypasses every host control.

- **2FA** on OVHcloud, Tailscale, Stripe, Novo, GitHub, and the DNS/registrar.
- **Tailnet ACLs** with device tags so only intended devices reach `itflow` /
  the bridge; consider **Tailscale SSH** and disabling key expiry only for the
  server node.
- ITFlow vault key: store offline, separate from the DB, and document recovery.
- Keep `config.php` out of the webroot where possible; it is currently mode 640
  `www-data` inside `/srv/tracker`.
- Set `ITFLOW_VERIFY_TLS => true` once ITFlow is behind Caddy with a valid
  certificate (`tracker/config.php.example` ships `false` for self-signed hosts).

## 5. Remote access (RustDesk)

- Self-host the relay (`hbbs`/`hbbr`) on the VPS and reach it over the tailnet;
  public RustDesk relays route connection metadata through third parties.
- Enforce unattended-access passwords, MFA, and per-client session logging.
- Obtain **written client consent** for remote sessions, and keep an access log.
- Consider scoping RustDesk strictly to a management tailnet/tag.

## 6. Monitoring & alerting

`scripts/healthcheck.sh` checks services but nothing runs or alerts on it.

- systemd timer running `healthcheck.sh`, notifying via ntfy/email on failure.
- Watch disk space (SQLite + MariaDB + uploads + backups share one disk).
- Alert on certificate renewal failures (check `journalctl -u caddy` / cert
  expiry).
- Provider billing/failure alerts (OVH, Cloudflare, Stripe, B2).

## 7. Money flow

- **Novo has no check-deposit API** — mobile check deposit is manual, so
  deposit → invoice reconciliation is manual. Plan a weekly reconciliation.
- Confirm whether ITFlow's Stripe integration auto-marks invoices paid from
  webhooks, or whether you reconcile by hand.
- Sales tax / VAT, legally sequential invoice numbering, and accounting export
  are not covered by any current script.
- Mileage is tracked (good for taxes); expense/receipt capture is not.

## 8. Smaller hardening

- Add a strict **CSP** to the PWA: `BRIDGE_TOKEN` lives in `localStorage` and is
  XSS-reachable.
- Rate-limit `/api/auth/login` on the sync service (allowlisted but unthrottled).
- Bump `CACHE_NAME` in `public/sw.js` whenever `public/` changes (the runbook
  notes this; easy to forget).
- Conflict resolution is last-write-wins on `updatedAt`; fine solo, revisit if
  staff are added.

## Action checklist

- [ ] Decide Stripe webhook path (Tunnel / Funnel / relay / manual) and whether
      any client-facing surface must be public.
- [ ] Configure an SMTP relay; publish SPF/DKIM/DMARC.
- [ ] Install restic/rclone, schedule `backup.sh`, back up the ITFlow vault key,
      and test a restore.
- [ ] Enable 2FA on all control-plane accounts; define tailnet ACLs/tags.
- [ ] Stand up self-hosted RustDesk behind the tailnet; document consent/logging.
- [ ] Schedule `healthcheck.sh` + disk/cert/billing alerts.
- [ ] Define check-deposit and Stripe reconciliation, sales tax, and invoice
      numbering.
- [ ] Add CSP and login rate limiting.

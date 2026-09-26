# Oracle VPS (reverb256-public-01) — public tier

Every unit here exists for a named reason. If a unit has no purpose written below, it should not be running.

## What runs here

| Unit | Purpose |
|---|---|
| `haven.service` | The Haven chat server, podman, image tag from `/etc/haven/image.env`. Serves `haven.reverb256.dev`. |
| `haven-updater.timer` / `.service` | Bumps the Haven image tag to upstream's newest published release and restarts. The host that serves users owns its own updates. |
| `cloudflared.service` | Tunnel `haven-vps`: public ingress -> `127.0.0.1:3001`. Used instead of an origin certificate because headscale already owns :443. |
| `headscale.service` | Tailnet control plane (DERP region 999, STUN :3478). Nodes: `oracle-vps` (100.64.0.1), `reverb256-edge-02` (100.64.0.3). |
| `tailscaled.service` | The VPS itself as tailnet node `oracle-vps` (100.64.0.1 — re-registered 2026-09-25 after the node record was lost; the old `100.64.0.2` is retired) — private path for admin and future services. |
| `oracle-keepalive.timer` | Deliberate idle workload. An Always Free instance idle 7 days (95th-pct CPU/network <20%) is reclaimed; an idle chat server would be. |
| `deadman-pager` (+ check timer) | Public signed-heartbeat receiver (:8899) — pages the owner when nexus's stack-sentinel heartbeat goes quiet. Source: `solana-ai-trader` `deploy/deadman/`. |
| `edge-probe.timer` | Probes the 5 public endpoints (maplespike, quill-web, quill-api, haven, headscale) → pager sinks. |
| `haven-backup.timer` (5 min) | Haven snapshot → **peer micro** (`/var/backups/haven`, 288 kept) + R2 third copy. Consumed by edge-02's `haven-standby-sync`. |
| `oracle-idle-watch` (on sentry) | Owns spend + instance lifecycle alerting. The only alerting owner for this box. |

## Deliberately NOT here

- **No metrics stack.** `node-exporter` was considered and is unnecessary: the LAN Prometheus cannot reach this host (different tailnets), and sentry's `oracle-idle-watch` already owns the failure modes. One owner per failure mode.
- **No second Caddy/nginx.** Built during the Haven move, then removed once the tunnel proved simpler — it was dead weight and its 8443 rule is closed.
- **No A1 capacity chasing.** An unattended retry loop ran here once; it was stopped because the tier runs comfortably on the micro (Haven 63 MB). Re-run `~/.oci/launch-a1-gated.sh` deliberately if a real capacity need appears.

## Install

    sudo install -m 644 haven.service haven-updater.service haven-updater.timer cloudflared.service /etc/systemd/system/
    sudo install -m 755 haven-snapshot haven-backup-stream haven-updater /usr/local/bin/
    sudo install -m 644 image.env /etc/haven/image.env
    sudo install -m 600 haven.env /etc/haven/haven.env     # from the template, values not in git
    sudo systemctl daemon-reload && sudo systemctl enable --now haven cloudflared haven-updater.timer tailscaled

## Registry gotchas this setup encodes

1. Upstream git tags carry a leading `v` (`v4.11.0`); the GHCR image tag does not (`4.11.0`).
2. GHCR answers **404, not 401**, for an OCI index manifest unless the request carries an `Accept` header naming a manifest type.

## Rollback

The k8s deployment in namespace `haven` still runs the same image and is reachable at `haven.lan`. To roll the public route back: first re-enable the k8s connector (`cloudflared.enabled: true` in `haven-k8s` chart values-lan.yaml — it was disabled on 2026-09-22 once the VPS took over the route), wait for the pod, then repoint the `haven.reverb256.dev` CNAME to the old tunnel `95a8d599-a069-414a-ab5f-4be063cb0f53.cfargotunnel.com`. For a LAN-only rollback no tunnel is needed: the k8s deployment still answers at `haven.lan`.

## Secrets: two env files, two jobs (do not confuse them)

| File | Contents | Owner | Source |
|---|---|---|---|
| `/etc/haven/haven.env` | non-secret runtime settings (PORT, HOST, FORCE_HTTP, PUBLIC_URL) | repo | `haven.env` via `apply.sh` |
| `/var/lib/haven/.env` | the secrets (JWT_SECRET, VAPID_*) | sops | `render-app-secrets.sh` |
| `/etc/cloudflared/tunnel.env` | the tunnel token | sops | `render-secrets.sh` |

Overwriting the systemd EnvironmentFile with the app's secret env drops FORCE_HTTP and PUBLIC_URL and
takes Haven offline while the unit still reports `active` — that happened on 2026-09-22, caught by
`curl 127.0.0.1:3001` returning 000, fixed by restoring the six non-secret keys. `systemctl is-active`
is not evidence a container is serving.

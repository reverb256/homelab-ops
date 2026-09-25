# lan-pages

The unified home of the homelab's local `.lan` static pages. One place to
edit; deployment stays declarative through the media-k8s GitOps repo.

## What is here

| Page | Served at | How it is served |
|------|-----------|------------------|
| `pages/index.html` | `https://media.lan/` | nginx-rp default vhost, straight from the `media-rp-config` ConfigMap |
| `pages/mining.html` | `https://mining.lan/` | nginx-rp vhost; page fetches live data from `/vm/` (proxied VictoriaMetrics) |
| `pages/trading.html` | `https://trading.lan/` | NOT in the ConfigMap — trading.lan proxies to the trading dashboard on `nexus:9798`; this file is the reference copy of that page |

Apps behind the edge (Jellyfin, *arr, Grafana, …) are proxied services, not
pages, and have no files here.

## How deployment works

The pages reach the edge through one ConfigMap:

```
media-k8s/cluster/addons/media-reverse-proxy/configmap-media-rp-config.yaml
  data.nginx.conf     # vhosts (incl. the mining.lan block + /vm/ proxy)
  data.index.html     # <- pages/index.html
  data.mining.html    # <- pages/mining.html
```

ArgoCD app `media-reverse-proxy` syncs that ConfigMap to the `nginx-rp`
deployment (hostNetwork on nexus + sentry, behind VIP `10.1.1.100:443`; TLS
leaf from the homelab CA, SANs issued via `ops-log/cluster/media-reverse-proxy/issue-lan-cert.sh`).

## Editing a page

```bash
$EDITOR pages/mining.html
./sync.py            # rewrites the ConfigMap page blocks
./sync.py --check    # CI-style check: exit 1 when out of sync
cd ~/Work/Projects/media-k8s
git add -u && git commit -m "lan-pages: <change>" && git push   # Argo syncs
```

The page mounts are `subPath`-style on running pods, so a ConfigMap change
alone does not reach a live nginx until the pods roll — expected and fine for
static pages; roll `kubectl -n media-reverse-proxy rollout restart deploy/nginx-rp`
when you want it live immediately (validated pattern: copy the new conf into a
pod and `nginx -t` first when the *nginx.conf* changed).

## Rules

- Do not hand-edit page keys in the media-k8s ConfigMap; edit here + `sync.py`.
- Keep pages self-contained (inline CSS/JS, no CDNs) — the edge has no asset
  pipeline and the boxes may be offline from the public internet.
- DNS is not managed here: `.lan` records live in
  `/etc/unbound/local-dns.conf` on nexus + sentry (VIP `10.1.1.100:53`).

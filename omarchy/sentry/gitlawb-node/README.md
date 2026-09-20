# sentry — gitlawb node (source of truth)

Private, isolated gitlawb node (v0.7.1) running as rootful podman Quadlets.
Host: sentry (`10.1.1.140:7545`). Node DID: `did:key:z6MkoR2p1JqNYDctCioeEa9gX5ZMxrySS71QWPEGYsEUwuhm`.

**Status: applied + verified 2026-09-20** (health 200, migrations applied, boot-persistent).

## Layout

| Path | Installs to | Purpose |
|------|-------------|---------|
| `gitlawb.network` | `/etc/containers/systemd/` | bridge network `gitlawb-net` |
| `gitlawb-pg.container` | `/etc/containers/systemd/` | Postgres 16, data at `/srv/gitlawb/pg` |
| `gitlawb-node.container` | `/etc/containers/systemd/` | the node, repos at `/srv/gitlawb/data`, port published on the LAN IP |

Secrets: `/srv/gitlawb/gitlawb.env` (0600, generated at first deploy — POSTGRES_PASSWORD + DATABASE_URL; never committed).
Backup: sibling bundle `../gitlawb-backup/` ships pg + data to `nexus:~/backups/gitlawb/` daily 04:30.

## Apply

```sh
./apply.sh            # idempotent; installs units, reloads systemd, restarts both containers, checks health
./apply.sh --check    # show what would change
```

Never hand-edit the live files on sentry: edit here, commit, re-apply.

## Design notes

- **Image pinned by digest** (v0.7.1 = `sha256:29193f3a…8390`): upstream publishes only `:latest` — pinning by digest keeps runtime reproducible; upgrades are explicit.
- **Isolated:** P2P off (`GITLAWB_P2P_PORT=0`), seeds disabled, no federation. Upstream warns private-read enforcement is not wired — treat public nodes as public; this node stays LAN/tailnet-only.
- **Data ownership:** `/srv/gitlawb/data` must be `chown 1000:1000` (image runs as uid 1000) or the node crashloops on key generation.
- **ufw prerequisites on sentry** (br_netfilter + ufw conflict): `allow-podman-dns` rules for 10.89.0.0/24→10.89.0.1:53 (udp+tcp), `ufw route allow in on podman1 out on podman1`, and route allows `enp7s0→podman1` + `tailscale0→podman1` for the published port. Symptoms without them: dns-fail / 5432 timeouts / curl 000. See the `gitlawb-ops` skill §0 gotcha 2.
- **Known upstream quirk:** repo enumeration omits private repos (reported upstream 2026-09-20); `gl repo info <name>` still resolves them.

## Upgrade procedure

```sh
ssh sentry 'sudo podman pull ghcr.io/gitlawb/node:latest'
ssh sentry 'sudo podman image inspect ghcr.io/gitlawb/node:latest --format "{{.Digest}}"'
# bump the digest in gitlawb-node.container, then:
./apply.sh
```

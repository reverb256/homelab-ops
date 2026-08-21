# Cluster deployment — apply order (cross-repo)

Some services span repos. Apply in this order so a consumer never points at a
not-yet-deployed dependency.

## Astral Key + Quill (auth chain)

astral-key owns its Deployment manifest now (`astral-key/k8s/astral-key-deployment.yaml`).
quill-api proxies to it (`ASTRAL_KEY_URL=http://astral-key.astral-key.svc.cluster.local:8080`).

Order:
1. `kubectl apply -f astral-key/k8s/astral-key-deployment.yaml`   # creates ns + deploy + svc
2. `kubectl -n astral-key rollout status deployment/astral-key --timeout=120s`
3. `kubectl apply -k quill/k8s/maplespike/`                       # or the quill manifests
4. `kubectl -n maplespike rollout restart deployment/quill-api`  # pick up new code

## Why astral-key is NOT in the quill repo

The quill `k8s/` dir deploys quill-*. astral-key is a separate Rust service
(its own repo, its own image `nexus:5000/astral-key:latest`). Colocating
its Deployment in quill would mean quill owns a service it doesn't build —
the exact ownership blur that caused the `.lan` / wrong-env-var drift
(2026-07-16). Each service's spec lives in its own repo; this file
only orchestrates the ORDER of application.

## Rebuild + push the astral-key image

```bash
# On nexus (or any host with the astral-key source + a registry push path):
cd /path/to/astral-key
just container            # or: cargo build --release + docker/podman build
podman tag astral-key:latest nexus:5000/astral-key:latest
podman push --format docker nexus:5000/astral-key:latest   # MUST be --format docker
```

Then re-apply the manifest (imagePullPolicy: IfNotPresent caches by tag; if the
tag is reused, also `kubectl -n astral-key rollout restart deployment/astral-key`).

## Env-var contract (must match astral-key/src/config.rs EXACTLY)

| Deployment env var      | Rust reads             | Notes                                         |
|------------------------|-----------------------|-----------------------------------------------|
| `FIDO2__RP_ID`       | `FIDO2_RP_ID`       | hostname, e.g. `maplespike.ca`                  |
| `FIDO2__RP_NAME`    | `FIDO2_RP_NAME`    | display name `MapleSpike`                       |
| `FIDO2__ORIGINS`     | `FIDO2_ORIGINS`     | **plural**, comma-list of allowed origins        |
| `ASTRAL_WEB3_DOMAIN` | `ASTRAL_WEB3_DOMAIN`| SIWE domain for challenge messages               |

LEGACY / DEAD VARS — do NOT use:
- `FIDO2__RP_ORIGIN`  (singular) — Rust does NOT read this; silently ignored.
- `WEB3__SIWE_DOMAIN`      — Rust does NOT read this at all; dead config.

All hostnames derive from `QUILL_DOMAIN` (set to `maplespike.ca` on both
quill-api and astral-key) so the two never drift.

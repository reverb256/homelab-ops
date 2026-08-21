# nixos-cluster-mcp

**Declarative NixOS cluster management over MCP.**

One unified `nixos_ops` tool with safety-gated actions for managing a NixOS
homelab cluster over SSH ControlMaster — status, preflight, build (streaming),
deploy, rollback, unstick.

Built for the [`homelab-ops`](https://github.com/reverb256/homelab-ops) repo.

## Why not `nix run .#nixos-cluster-mcp`?

The old approach evaluated the nix flake on every invocation — which required a
clean `/etc/nixos` git tree and enough RAM (zephyr: 31GB, earlyoom kills large
evaluations). This server runs as a **persistent SSE daemon** on nexus (46GB,
no earlyoom) so the flake is built once at deploy time, not per-call.

## Actions

| Action | Node | Safety | Description |
|--------|------|--------|-------------|
| `list_nodes` | — | ✅ | List registered nodes + safety gates |
| `status` | required | ✅ | Generation, uptime, failed-unit count, RAM, git behind |
| `git_state` | — | ✅ | Git state (branch/behind/dirty) for ALL nodes |
| `failed_units` | required | ✅ | Filtered failed systemd units (services, mounts, timers) |
| `preflight` | required | ✅ | RAM, git clean, orphaned nix processes, daemon health |
| `unstick` | required | ✅ | Kill wedged nix-store --realise / nix build processes |
| `build` | required | ✅ | Build toplevel on build_host (default nexus, never zephyr), streaming |
| `deploy` | required | 🔴 | Preflight → build → (mining pause) → switch → verify |
| `rollback` | required | 🔴 | `nixos-rebuild switch --rollback` |

Destructive actions (`deploy`, `rollback`) require `confirm=True` and respect
per-node `allow_deploy` / `allow_rollback` gates.

## Node Registry

Edit `~/.config/nixos-cluster-mcp/nodes.json` (or set `NIXOS_MCP_NODES`):

```json
[
  {
    "name": "nexus",
    "host": "10.1.1.120",
    "user": "j_kro",
    "build_host": "nexus",
    "allow_deploy": true,
    "mining_host": true
  }
]
```

Key fields:
- `build_host`: where `nix build` runs. **Must NOT be zephyr** (31GB, earlyoom).
  Defaults to nexus (46GB). All builds run here, store paths are `nix copy`'d
  to the target.
- `allow_deploy`: safety gate for `deploy` action. Default `false`.
- `mining_host`: if true, pauses `mining.target` during deploy.

## Running

```bash
# SSE daemon (production — persistent, on nexus):
systemctl --user start nixos-cluster-mcp

# Or direct (for testing):
uv run nixos-cluster-mcp --transport sse --port 8081
```

## Development

```bash
uv venv .venv && source .venv/bin/activate
uv pip install -e . pytest
python -m pytest tests/ -v
# Live smoke (requires nodes.json and SSH keys):
NIXOS_MCP_LIVE=1 python -m pytest tests/ -k test_live_status -v -s
```

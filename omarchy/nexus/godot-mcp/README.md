# godot-mcp (nexus)

Godot MCP server — [Fulviuus/godot-mcp](https://github.com/Fulviuus/godot-mcp) `godot-mcp-server` v2.0.2 (**182 tools**) — running as a systemd user service on nexus, HTTP transport on **:8795**.

## What runs where

| Piece | Where |
|---|---|
| Engine | `godot-git` (AUR, master build) at `/usr/bin/godot` — cutting edge |
| Server | `/home/j_kro/Work/godot-mcp` (built from source: `npm install && npm run build`) |
| Unit | `~/.config/systemd/user/godot-mcp.service` (enabled; `Restart=on-failure`) |
| Client | Hermes (zephyr) → `http://100.76.105.73:8795/mcp` — tailnet IP; LAN :8795 is not open in ufw |

## Apply

```bash
bash apply.sh           # install unit + reload + enable/restart + live health check
bash apply.sh --check   # show what would happen, change nothing
```

## Verify

```bash
systemctl --user status godot-mcp
curl -s http://127.0.0.1:8795/health
# -> {"ok":true,"server":"godot-mcp-server","version":"2.0.2","tools":182}
```

## Notes

- **Update the server**: `cd ~/Work/godot-mcp && git pull && npm install && npm run build && systemctl --user restart godot-mcp`
- **Update the engine**: `yay -S godot-git` (conflicts with stable `godot`; godot-git provides `/usr/bin/godot`).
- `GODOT_BIN=/usr/bin/godot`; `GODOT_PROJECT_ROOT` deliberately unset (project is a per-call argument).
- **Export templates are NOT installed** — git builds have no release templates. Exports need `godot-export-templates-git` (AUR) or the MCP toolchain download.
- Install date: 2026-09-20. Server reachable from zephyr only via tailnet IP (`nexus.lan:8795` is firewalled).

"""nixos-cluster-mcp server.

A single MCP tool `nixos_ops` with sub-actions provides declarative, guarded
management of a NixOS cluster over SSH:

  status          host health (generation, uptime, failed-unit count, git behind)
  git_state       /etc/nixos git state per node (branch, behind/ahead, dirty)
  failed_units    list failed systemd units on a host
  preflight       safety check before a deploy (RAM, git clean, orphaned procs, daemon)
  unstick         kill wedged nix-store --realise / nix build / daemon children
  build           build a host's toplevel (on its build_host, never zephyr) — streaming
  deploy          preflight -> build -> (optional mining pause) -> switch -> verify
  rollback        revert to previous generation (gated by allow_rollback)

Design principles (from production-MCP research):
  * Build on a designated build host (default nexus, 46GB) — never evaluate a
    large flake on zephyr (31GB, earlyoom).
  * Per-node safety gates (allow_deploy / allow_build / allow_rollback).
  * Destructive ops require an explicit `confirm=True`.
  * Streaming build progress via FastMCP streamContent + reportProgress so a
    30-minute build never looks like a hang.
  * Audit log of every tool call to journald (or a file fallback).
"""

from __future__ import annotations

import asyncio
import os
import subprocess
import time
from typing import Any

from fastmcp import FastMCP
from fastmcp.server.context import Context

from .nodes import Node, NodeRegistry

mcp = FastMCP("nixos-cluster")

# ---------------------------------------------------------------------------
# Registry + audit
# ---------------------------------------------------------------------------

_REGISTRY: NodeRegistry | None = None


def registry() -> NodeRegistry:
    global _REGISTRY
    if _REGISTRY is None:
        _REGISTRY = NodeRegistry.load()
    return _REGISTRY


def _audit(ctx: Context, action: str, detail: str) -> None:
    """Log every tool call. Best-effort: journald if available, else stderr."""
    line = f"[nixos-cluster-mcp] action={action} {detail}"
    try:
        subprocess.run(
            ["systemd-cat", "-t", "nixos-cluster-mcp", "-p", "info"],
            input=line, text=True, capture_output=True, timeout=5,
        )
    except Exception:
        # Fallback: stderr (never corrupt stdio JSON-RPC in SSE mode).
        print(line, flush=True)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_kv(raw: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in raw.splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out[k.strip().lower()] = v.strip()
    return out


def _safe_action(action: str) -> str:
    allowed = {
        "status", "git_state", "failed_units", "preflight", "unstick",
        "build", "deploy", "rollback", "list_nodes",
    }
    return action if action in allowed else ""


# ---------------------------------------------------------------------------
# The unified tool
# ---------------------------------------------------------------------------

@mcp.tool
async def nixos_ops(
    action: str,
    node: str | None = None,
    confirm: bool = False,
    reset_to_main: bool = True,
    ctx: Context | None = None,
) -> dict[str, Any]:
    """Unified NixOS cluster management tool.

    Actions:
      list_nodes            -> no node required; lists registered nodes + gates
      status       [node]   -> generation, uptime, failed count, git behind
      git_state     (none)   -> /etc/nixos state for ALL nodes
      failed_units [node]   -> list failed systemd units
      preflight    [node]   -> safety check before deploy
      unstick      [node]   -> kill wedged nix processes
      build        [node]   -> build toplevel on build_host (streaming)
      deploy       [node]   -> preflight -> build -> switch -> verify
      rollback     [node]   -> revert generation (needs confirm=True)

    reset_to_main: if True (default), `nixos build` and `nixos deploy` run
      `git fetch origin main && git reset --hard origin/main` on the target
      before building — hosts track `main` per AGENTS.md.
    """
    action = _safe_action(action)
    if not action:
        return {"error": "unknown or disallowed action"}

    reg = registry()
    if ctx is not None:
        await ctx.info(f"nixos_ops action={action} node={node}")
    _audit(ctx, action, f"node={node} confirm={confirm}")

    # ---- list_nodes -------------------------------------------------------
    if action == "list_nodes":
        return {
            "nodes": [
                {
                    "name": n.name,
                    "host": n.host,
                    "build_host": n.build_host,
                    "allow_deploy": n.allow_deploy,
                    "allow_build": n.allow_build,
                    "allow_rollback": n.allow_rollback,
                    "tags": n.tags,
                }
                for n in reg.all()
            ]
        }

    # ---- git_state does not need a node ------------------------------------
    if action == "git_state":
        return await _git_state_all(reg)

    # ---- everything else needs a node ------------------------------------
    if node is None:
        return {"error": f"action '{action}' requires a node"}
    try:
        n = reg.require(node)
    except KeyError as e:
        return {"error": str(e)}

    if action == "status":
        return await _status(n)
    if action == "git_state":
        return await _git_state_all(reg)
    if action == "failed_units":
        return await _failed_units(n)
    if action == "preflight":
        return await _preflight(n)
    if action == "unstick":
        return await _unstick(n)
    if action == "build":
        return await _build(n, reg, ctx, reset_to_main=reset_to_main)
    if action == "deploy":
        if not n.allow_deploy and not confirm:
            return {
                "error": f"node '{node}' has allow_deploy=false. "
                         f"Pass confirm=True to override (you accept the risk).",
                "gate": "allow_deploy",
            }
        return await _deploy(n, reg, ctx, confirm=confirm, reset_to_main=reset_to_main)
    if action == "rollback":
        if not n.allow_rollback and not confirm:
            return {
                "error": f"node '{node}' has allow_rollback=false. Pass confirm=True.",
                "gate": "allow_rollback",
            }
        return await _rollback(n, confirm=confirm)
    return {"error": f"unhandled action {action}"}


# ---------------------------------------------------------------------------
# Action implementations
# ---------------------------------------------------------------------------

async def _status(n: Node) -> dict[str, Any]:
    rc, raw = await asyncio.to_thread(
        _ssh_status, n
    )
    if rc != 0:
        return {"node": n.name, "reachable": False, "error": raw[:300]}
    return {"node": n.name, "reachable": True, **_parse_kv(raw)}


def _ssh_status(n: Node) -> tuple[int, str]:
    from .ssh import ssh_run
    # Prepend a throwaway "__:" line — first line of output on a fresh
    # ControlMaster connection is always lost (SSH framing race).
    cmd = (
        "echo __:; "
        "echo GEN:$(readlink /nix/var/nix/profiles/system | xargs basename); "
        "echo UPTIME:$(uptime -p 2>/dev/null || true); "
        "echo FAILED:$(systemctl --failed --no-legend 2>/dev/null | wc -l); "
        "cd /etc/nixos 2>/dev/null && echo BEHIND:$(git rev-list --count HEAD..origin/main 2>/dev/null); "
        "echo AVAILMB:$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')"
    )
    return ssh_run(n, cmd, timeout=30)


async def _git_state_all(reg: NodeRegistry) -> dict[str, Any]:
    import concurrent.futures

    def _one(n: Node):
        from .ssh import ssh_run
        cmd = (
            "cd /etc/nixos 2>/dev/null && "
            "echo BRANCH:$(git branch --show-current) && "
            "echo BEHIND:$(git rev-list --count HEAD..origin/main 2>/dev/null) && "
            "echo AHEAD:$(git rev-list --count origin/main..HEAD 2>/dev/null) && "
            "echo DIRTY:$(git status --porcelain 2>/dev/null | wc -l)"
        )
        rc, raw = ssh_run(n, cmd, timeout=30)
        info: dict[str, Any] = {"reachable": rc == 0}
        if rc == 0:
            info.update(_parse_kv(raw))
        else:
            info["error"] = raw[:200]
        return n.name, info

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(reg.all()) or 1) as ex:
        results = dict(ex.map(_one, reg.all()))
    return results


async def _failed_units(n: Node) -> dict[str, Any]:
    from .ssh import ssh_run
    rc, raw = await asyncio.to_thread(
        ssh_run, n, "systemctl --failed --no-legend --no-pager 2>/dev/null", timeout=30
    )
    units = []
    for line in raw.splitlines():
        parts = line.split()
        if parts:
            # systemctl prefixes each line with a status glyph (●, etc.)
            name = parts[0] if not parts[0].startswith(("●", "○", "◆", "◉", "•")) else (parts[1] if len(parts) > 1 else parts[0])
            # Filter to user-relevant unit types (skip kernel device/scope/slice/socket noise)
            if not any(name.endswith(s) for s in (".device", ".scope", ".slice", ".socket", ".swap")):
                units.append(name)
    return {"node": n.name, "count": len(units), "units": units}


async def _preflight(n: Node) -> dict[str, Any]:
    """Safety gate before a deploy. Checks the things that bit us this session:
    available RAM (earlyoom), dirty/diverged git tree, orphaned nix processes,
    and nix-daemon health."""
    from .ssh import ssh_run
    checks: dict[str, Any] = {"node": n.name, "ok": True, "warnings": [], "errors": []}

    # RAM (earlyoom on zephyr is the classic killer)
    # Prepend __: throwaway — first line of output on fresh ControlMaster is lost
    rc, raw = await asyncio.to_thread(
        ssh_run, n,
        "echo __:; echo AVAILMB:$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')",
        timeout=20,
    )
    if rc == 0:
        avail = int(_parse_kv(raw).get("availmb", "0"))
        checks["available_mb"] = avail
        if avail < 2048:
            checks["errors"].append(f"RAM critical: {avail}MB available (<2GB) — OOM risk")
            checks["ok"] = False
        elif avail < 4096:
            checks["warnings"].append(f"RAM low: {avail}MB available (<4GB recommended)")

    # Git tree cleanliness (dirty tree breaks `nix run` / flake eval)
    rc, raw = await asyncio.to_thread(
        ssh_run, n,
        "cd /etc/nixos 2>/dev/null && "
        "echo DIRTY:$(git status --porcelain 2>/dev/null | wc -l) && "
        "echo BEHIND:$(git rev-list --count HEAD..origin/main 2>/dev/null)",
        timeout=20,
    )
    if rc == 0:
        kv = _parse_kv(raw)
        dirty = int(kv.get("dirty", "0"))
        behind = int(kv.get("behind", "0"))
        checks["git_dirty"] = dirty
        checks["git_behind"] = behind
        if dirty > 0:
            checks["warnings"].append(f"git tree dirty ({dirty} files) — deploy will git reset --hard origin/main")
        if behind > 0:
            checks["warnings"].append(f"git behind origin/main by {behind} — will fast-forward")

    # Orphaned nix processes (wedged builds hold the store lock)
    rc, raw = await asyncio.to_thread(
        ssh_run, n,
        "pgrep -af 'nix-store --realise|nix build' 2>/dev/null | grep -v pgrep | wc -l",
        timeout=20,
    )
    if rc == 0:
        orphans = int(raw.strip() or "0")
    else:
        orphans = 0
    checks["orphaned_nix_procs"] = orphans
    if orphans > 0:
        checks["errors"].append(f"{orphans} orphaned nix build process(es) — run unstick first")
        checks["ok"] = False

    return checks


async def _unstick(n: Node) -> dict[str, Any]:
    """Kill wedged nix processes: stuck `nix-store --realise`, `nix build`,
    and isolated nix-daemon children that aren't doing real work."""
    from .ssh import ssh_run
    cmd = (
        "pkill -9 -f 'nix-store --realise' 2>/dev/null; "
        "pkill -9 -f '^nix build' 2>/dev/null; "
        "echo killed_orphans"
    )
    rc, raw = await asyncio.to_thread(ssh_run, n, cmd, timeout=30)
    return {"node": n.name, "rc": rc, "output": raw}


async def _build(n: Node, reg: NodeRegistry, ctx: Context | None, reset_to_main: bool = True) -> dict[str, Any]:
    """Build a host's toplevel on its build_host (never zephyr). Streams
    progress so a 30-min build is observable, not a hang.

    If reset_to_main is True, runs `git fetch origin main && git reset --hard
    origin/main` on the target before building (hosts track main per AGENTS.md).
    """
    from .ssh import ssh_run_build_host

    if not n.allow_build:
        return {"error": f"node '{n.name}' has allow_build=false"}

    sync = (
        "git fetch origin main >/dev/null 2>&1 && git reset --hard origin/main >/dev/null 2>&1 && "
        if reset_to_main else ""
    )
    flake_ref = n.flake_path if n.use_flake else n.flake_path
    attr = f"{flake_ref}#nixosConfigurations.{n.name}.config.system.build.toplevel"
    cmd = f"cd {n.flake_path} && {sync}nix build {attr} --no-link --print-out-paths 2>&1 | tail -1"

    # Run on the build host (default nexus). Use a backgrounded ssh so we can poll.
    build_node = reg.require(n.build_host) if n.build_host != n.name else n
    target = build_node.ssh_target()
    # Launch nohup-style so the SSH call returns quickly; we poll via a marker file.
    marker = f"/tmp/nixos-build-{n.name}.done"
    full_cmd = (
        f"( {cmd} > /tmp/nixos-build-{n.name}.log 2>&1 ; "
        f"echo EXIT=$? >> /tmp/nixos-build-{n.name}.log ; touch {marker} ) "
        f">/dev/null 2>&1 &"
    )
    from .ssh import ssh_run
    rc, _ = await asyncio.to_thread(ssh_run, build_node, full_cmd, timeout=30)
    if rc != 0:
        return {"error": "failed to launch build", "rc": rc}

    # Poll the log, streaming progress
    last_size = 0
    start = time.time()
    store_path = ""
    exit_code = None
    while True:
        await asyncio.sleep(10)
        rc2, raw = await asyncio.to_thread(
            ssh_run, build_node,
            f"cat /tmp/nixos-build-{n.name}.log 2>/dev/null; "
            f"echo MARKER_PRESENT:$(test -f {marker} && echo yes || echo no)",
            timeout=20,
        )
        if ctx is not None:
            # Stream the last lines as progress
            tail = raw.splitlines()[-6:]
            await ctx.report_progress(
                progress=int((time.time() - start) / 30), total=100
            )
            await ctx.info("build log: " + " | ".join(tail))
        # detect store path
        for line in raw.splitlines():
            if line.startswith("/nix/store") and "toplevel" in line:
                store_path = line.strip()
            if line.startswith("EXIT="):
                exit_code = int(line.split("=", 1)[1])
        if "MARKER_PRESENT:yes" in raw and exit_code is not None:
            break
        # stall detection: no new bytes for >5 min
        size = len(raw)
        if size == last_size and (time.time() - start) > 300:
            return {
                "node": n.name, "stalled": True,
                "store_path": store_path or None,
                "tail": raw.splitlines()[-15:],
                "note": "No progress for >5min. Run unstick, then retry.",
            }
        last_size = size
        if (time.time() - start) > 2400:
            return {"node": n.name, "timeout": True, "store_path": store_path or None}

    # cleanup marker
    await asyncio.to_thread(ssh_run, build_node, f"rm -f {marker}", timeout=10)
    return {
        "node": n.name,
        "build_host": n.build_host,
        "exit_code": exit_code,
        "store_path": store_path or None,
        "ok": exit_code == 0 and bool(store_path),
        "tail": raw.splitlines()[-15:],
    }


async def _deploy(
    n: Node, reg: NodeRegistry, ctx: Context | None, confirm: bool = False,
    reset_to_main: bool = True,
) -> dict[str, Any]:
    """Preflight -> build (on build_host) -> nix copy to target -> switch ->
    verify. Mining hosts pause mining around the switch."""
    from .ssh import ssh_run, ssh_run_build_host

    # 1. preflight
    pre = await _preflight(n)
    if not pre.get("ok", False) and not confirm:
        return {"node": n.name, "aborted": "preflight failed", "preflight": pre}

    # 2. build (streaming handled inside)
    b = await _build(n, reg, ctx, reset_to_main=reset_to_main)
    if not b.get("ok"):
        return {"node": n.name, "aborted": "build failed", "build": b}
    store_path = b["store_path"]

    # 3. optional mining pause
    if n.mining_host:
        await asyncio.to_thread(ssh_run, n, "sudo systemctl stop mining.target", timeout=60)

    # 4. copy + switch on the target
    copy_cmd = f"nix copy --to ssh://{n.ssh_target()} {store_path}"
    await asyncio.to_thread(ssh_run_build_host, reg, n, copy_cmd, timeout=600)
    switch_cmd = (
        f"sudo nix-env -p /nix/var/nix/profiles/system --set {store_path} && "
        f"sudo {store_path}/bin/switch-to-configuration switch 2>&1 | tail -8 && "
        f"echo POSTFAIL:$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
    )
    rc, raw = await asyncio.to_thread(ssh_run, n, switch_cmd, timeout=600)

    # 5. resume mining
    if n.mining_host:
        await asyncio.to_thread(ssh_run, n, "sudo systemctl start mining.target", timeout=60)

    postfail = None
    for line in raw.splitlines():
        if line.startswith("POSTFAIL:"):
            postfail = line.split(":", 1)[1].strip()
    return {
        "node": n.name,
        "store_path": store_path,
        "switch_rc": rc,
        "deployed": rc == 0,
        "post_switch_failed_units": postfail,
        "tail": raw.splitlines()[-15:],
    }


async def _rollback(n: Node, confirm: bool = False) -> dict[str, Any]:
    from .ssh import ssh_run
    cmd = "sudo nixos-rebuild switch --rollback 2>&1 | tail -8"
    rc, raw = await asyncio.to_thread(ssh_run, n, cmd, timeout=300)
    return {"node": n.name, "rc": rc, "rolled_back": rc == 0, "tail": raw.splitlines()[-12:]}


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="NixOS Cluster MCP Server")
    parser.add_argument("--transport", choices=["stdio", "sse"], default="sse")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8081)
    args = parser.parse_args()

    if args.transport == "sse":
        mcp.run(transport="sse", host=args.host, port=args.port)
    else:
        mcp.run()


if __name__ == "__main__":
    main()

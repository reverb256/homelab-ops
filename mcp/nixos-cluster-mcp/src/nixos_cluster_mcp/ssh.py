"""SSH helper with persistent ControlMaster multiplexing.

Per the mcp-nixos-ops reference design, we open one multiplexed connection
per host and reuse it: first command ~1s, subsequent ~60ms. Sockets persist
for 10 minutes (ControlPersist) between calls.

Stale sockets from SIGKILL'd SSH sessions are cleaned before each command
to avoid silent output corruption.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

from .nodes import Node, NodeRegistry

_CONTROL_DIR = Path(tempfile.gettempdir()) / "nixos-mcp-ssh"
_CONTROL_DIR.mkdir(mode=0o700, exist_ok=True)

# Safety: reject obviously dangerous hosts. Mirrors the production-MCP guidance
# that sensitive hosts should never be reachable without explicit allow-listing.
# Basic SSH options (no ControlMaster) for warmup and socket-check commands
_SSH_BARE = [
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=15",
    "-T",
]

# Multiplexed SSH options for main commands (60ms reuse after warmup)
_SSH_OPTS = _SSH_BARE + [
    "-o", "ControlMaster=auto",
    f"-o", f"ControlPath={_CONTROL_DIR}/%r@%h:%p",
    "-o", "ControlPersist=10m",
    "-o", "ConnectTimeout=15",
    "-T",
]


def _control_path(node: Node) -> str:
    return str(_CONTROL_DIR / f"{node.user}@{node.host}:{node.port}")


def _clean_stale_socket(node: Node) -> None:
    """Remove a stale ControlMaster socket if the master process is dead."""
    socket = _control_path(node)
    if os.path.exists(socket):
        # Try to check if master is alive by running a simple echo
        # If it fails, the socket is stale — remove it
        try:
            check = subprocess.run(
                ["ssh", "-S", socket, "-O", "check", node.ssh_target()],
                capture_output=True, text=True, timeout=10,
            )
            if check.returncode != 0:
                os.unlink(socket)
        except Exception:
            try:
                os.unlink(socket)
            except Exception:
                pass


def _ssh_base(node: Node) -> list[str]:
    """Build SSH base args with proper options and cleaned socket."""
    _clean_stale_socket(node)
    # Warm up a fresh ControlMaster: run a throwaway echo so the first real
    # command doesn't lose its output to connection negotiation framing.
    # Must use the same ControlMaster opts so the master socket is established.
    socket = _control_path(node)
    if not os.path.exists(socket):
        try:
            warmup_opts = [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=auto",
                "-o", f"ControlPath={socket}",
                "-o", "ControlPersist=10m",
                "-o", "ConnectTimeout=15",
                "-T",
            ]
            subprocess.run(
                ["ssh", *(["-p", str(node.port)] if node.port != 22 else []),
                 *warmup_opts, node.ssh_target(), "echo"],
                capture_output=True, text=True, timeout=15,
            )
        except Exception:
            pass
    base = [
        "ssh",
        *(["-p", str(node.port)] if node.port != 22 else []),
        *_SSH_OPTS,
    ]
    if node.ssh_key:
        base += ["-i", os.path.expanduser(node.ssh_key)]
    base += [node.ssh_target()]
    return base


def ssh_run(
    node: Node,
    cmd: str,
    *,
    timeout: int = 600,
    check: bool = False,
) -> tuple[int, str]:
    """Run a command on a node via multiplexed SSH. Returns (rc, combined_output).

    Automatically retries once with a fresh connection if stale socket detected.
    """
    base = _ssh_base(node)
    full = [*base, "bash", "--norc", "--noprofile", "-c", cmd]
    try:
        r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
        out = (r.stdout + r.stderr).strip()
        # Stale-socket detection: a successful echo should produce actual output.
        # If stdout is empty or just whitespace, the socket is stale — retry once.
        if r.returncode == 0 and not out.strip():
            _clean_stale_socket(node)
            r2 = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
            out = (r2.stdout + r2.stderr).strip()
            return r2.returncode, out
        return r.returncode, out
    except subprocess.TimeoutExpired:
        return -1, f"ssh command timed out after {timeout}s"
    except FileNotFoundError as e:
        return 127, f"ssh not found: {e}"


def ssh_run_build_host(
    registry: NodeRegistry,
    node: Node,
    cmd: str,
    *,
    timeout: int = 2400,
) -> tuple[int, str]:
    """Run a command on the node's designated build host.

    The build host is where `nix build` runs. By policy it must never be
    zephyr (31GB, earlyoom). Defaults to nexus (46GB).
    """
    if node.build_host == node.name:
        return ssh_run(node, cmd, timeout=timeout)
    build_node = registry.require(node.build_host)
    return ssh_run(build_node, cmd, timeout=timeout)


def close_control(node: Node) -> None:
    """Explicitly close the multiplexed master for a node (used on error)."""
    target = node.ssh_target()
    subprocess.run(
        ["ssh", "-p", str(node.port), "-O", "exit", target],
        capture_output=True, text=True, timeout=10,
    )

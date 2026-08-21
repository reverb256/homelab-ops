"""Tests for nixos-cluster-mcp.

Unit tests mock the SSH layer (no live cluster needed). Set NIXOS_MCP_LIVE=1
to also run a live smoke test against the registered nodes.
"""

from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path
from unittest import mock

import pytest

# Make the src package importable
SRC = Path(__file__).resolve().parents[1] / "src"
sys.path.insert(0, str(SRC))

import nixos_cluster_mcp.server as srv  # noqa: E402
from nixos_cluster_mcp.nodes import Node, NodeRegistry  # noqa: E402


@pytest.fixture
def registry():
    nodes = [
        Node(name="nexus", host="10.1.1.120", user="j_kro", build_host="nexus",
             allow_deploy=True, allow_build=True),
        Node(name="zephyr", host="10.1.1.110", user="j_kro", build_host="nexus",
             allow_deploy=True, allow_build=True, mining_host=True),
        Node(name="forge", host="10.1.1.130", user="j_kro", build_host="nexus",
             allow_deploy=False, allow_build=True, mining_host=True),
    ]
    return NodeRegistry(nodes)


def test_registry_lookup(registry):
    assert registry.require("nexus").host == "10.1.1.120"
    with pytest.raises(KeyError):
        registry.require("does-not-exist")


def test_list_nodes(registry, monkeypatch):
    monkeypatch.setattr(srv, "_REGISTRY", registry)
    import asyncio
    out = asyncio.run(srv.nixos_ops(action="list_nodes"))
    names = {n["name"] for n in out["nodes"]}
    assert names == {"nexus", "zephyr", "forge"}
    forge = next(n for n in out["nodes"] if n["name"] == "forge")
    assert forge["allow_deploy"] is False


def test_unknown_action(registry, monkeypatch):
    monkeypatch.setattr(srv, "_REGISTRY", registry)
    import asyncio
    out = asyncio.run(srv.nixos_ops(action="bogus"))
    assert "error" in out


def test_status_parses_kv(registry, monkeypatch):
    monkeypatch.setattr(srv, "_REGISTRY", registry)
    monkeypatch.setattr(srv, "_ssh_status", lambda n: (0, "GEN:system-322-link\nUPTIME:up 3 days\nFAILED:0\nBEHIND:0\nAVAILMB:12000"))
    import asyncio
    out = asyncio.run(srv.nixos_ops(action="status", node="nexus"))
    assert out["gen"] == "system-322-link"
    assert out["failed"] == "0"
    assert out["availmb"] == "12000"


def test_failed_units_parses(registry, monkeypatch):
    monkeypatch.setattr(srv, "_REGISTRY", registry)
    raw = "● foo.service loaded failed failed /foo\n● bar.service loaded failed failed /bar"
    monkeypatch.setattr("nixos_cluster_mcp.ssh.ssh_run", lambda n, c, timeout=30: (0, raw))
    import asyncio
    out = asyncio.run(srv.nixos_ops(action="failed_units", node="nexus"))
    assert out["count"] == 2
    assert "foo.service" in out["units"]


def test_deploy_gate_blocks_without_confirm(registry, monkeypatch):
    monkeypatch.setattr(srv, "_REGISTRY", registry)
    import asyncio
    out = asyncio.run(srv.nixos_ops(action="deploy", node="forge"))
    assert "error" in out
    assert out.get("gate") == "allow_deploy"


def test_deploy_gate_allows_with_confirm(registry, monkeypatch):
    monkeypatch.setattr(srv, "_REGISTRY", registry)
    # Stub the whole pipeline
    async def _mock_preflight(n):
        return {"ok": True}
    monkeypatch.setattr(srv, "_preflight", _mock_preflight)
    async def _mock_build(n, reg, ctx, reset_to_main=True):
        return {"ok": True, "store_path": "/nix/store/abc"}
    monkeypatch.setattr(srv, "_build", _mock_build)
    monkeypatch.setattr("nixos_cluster_mcp.ssh.ssh_run", lambda n, c, timeout=30: (0, "POSTFAIL:0"))
    monkeypatch.setattr("nixos_cluster_mcp.ssh.ssh_run_build_host", lambda reg, n, c, timeout=600: (0, ""))
    import asyncio
    out = asyncio.run(srv.nixos_ops(action="deploy", node="forge", confirm=True))
    assert out["deployed"] is True
    assert out["post_switch_failed_units"] == "0"


def test_preflight_flags_orphans(registry, monkeypatch):
    monkeypatch.setattr(srv, "_REGISTRY", registry)
    # RAM ok, git clean, but orphaned nix procs present
    def fake_ssh(n, c, timeout=20):
        if "MemAvailable" in c:
            return (0, "AVAILMB:12000")
        if "git status" in c:
            return (0, "DIRTY:0\nBEHIND:0")
        if "pgrep" in c:
            return (0, "2")
        return (0, "")
    monkeypatch.setattr("nixos_cluster_mcp.ssh.ssh_run", fake_ssh)
    import asyncio
    out = asyncio.run(srv.nixos_ops(action="preflight", node="nexus"))
    assert out["ok"] is False
    assert any("orphaned" in e for e in out["errors"])


# ---------------------------------------------------------------------------
# Live smoke test (opt-in)
# ---------------------------------------------------------------------------

@pytest.mark.skipif(not os.environ.get("NIXOS_MCP_LIVE"), reason="set NIXOS_MCP_LIVE=1")
def test_live_status():
    srv._REGISTRY = NodeRegistry.load()
    import asyncio
    out = asyncio.run(srv.nixos_ops(action="status", node="nexus"))
    assert out.get("reachable") is True
    assert "failed" in out  # confirms SSH + parsing works
    assert out.get("failed") is not None

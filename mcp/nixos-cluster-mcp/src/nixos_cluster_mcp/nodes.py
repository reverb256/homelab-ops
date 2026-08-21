"""Node registry for nixos-cluster-mcp.

Loaded from a JSON file (default: /etc/nixos-cluster-mcp/nodes.json or
$XDG_CONFIG_HOME/nixos-cluster-mcp/nodes.json). Each node declares its
SSH target, whether it uses flakes, which host to *build* on (never zephyr
— 31GB, earlyoom kills large builds), and per-node safety gates.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


DEFAULT_NODES_PATH = os.getenv(
    "NIXOS_MCP_NODES",
    os.path.join(
        os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
        "nixos-cluster-mcp",
        "nodes.json",
    ),
)


@dataclass
class Node:
    """A single managed NixOS host."""

    name: str
    host: str
    user: str = "root"
    port: int = 22
    ssh_key: str | None = None
    use_flake: bool = True
    flake_path: str = "/etc/nixos"
    # Host to run `nix build` on. MUST NOT be zephyr (earlyoom). Defaults to nexus.
    build_host: str = "nexus"
    # Safety gates
    allow_deploy: bool = False
    allow_build: bool = True
    allow_rollback: bool = True
    # If true, pause mining.target on this host before deploy and resume after.
    mining_host: bool = False
    tags: list[str] = field(default_factory=list)
    # Optional jump/bastion host name (must also be a registered node).
    jump_host: str | None = None

    def ssh_target(self) -> str:
        return f"{self.user}@{self.host}"

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "host": self.host,
            "user": self.user,
            "port": self.port,
            "ssh_key": self.ssh_key,
            "use_flake": self.use_flake,
            "flake_path": self.flake_path,
            "build_host": self.build_host,
            "allow_deploy": self.allow_deploy,
            "allow_build": self.allow_build,
            "allow_rollback": self.allow_rollback,
            "mining_host": self.mining_host,
            "tags": self.tags,
            "jump_host": self.jump_host,
        }


class NodeRegistry:
    """In-memory registry of managed nodes, loaded from JSON."""

    def __init__(self, nodes: list[Node]):
        self._nodes = {n.name: n for n in nodes}

    @classmethod
    def load(cls, path: str = DEFAULT_NODES_PATH) -> "NodeRegistry":
        p = Path(path)
        if not p.exists():
            raise FileNotFoundError(
                f"Node registry not found at {path}. Set NIXOS_MCP_NODES or create the file."
            )
        raw = json.loads(p.read_text())
        nodes = [Node(**n) for n in raw]
        return cls(nodes)

    def get(self, name: str) -> Node | None:
        return self._nodes.get(name)

    def all(self) -> list[Node]:
        return list(self._nodes.values())

    def names(self) -> list[str]:
        return list(self._nodes.keys())

    def require(self, name: str) -> Node:
        node = self.get(name)
        if node is None:
            raise KeyError(
                f"Unknown node '{name}'. Known: {', '.join(sorted(self._nodes))}"
            )
        return node

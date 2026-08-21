"""nixos-cluster-mcp: declarative NixOS cluster management over MCP."""

__version__ = "0.2.0"

from .server import mcp

__all__ = ["mcp", "__version__"]

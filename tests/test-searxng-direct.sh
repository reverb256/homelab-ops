#!/usr/bin/env bash
#
# Test SearXNG connectivity using external instance
#

SEARXNG_URL="https://search.reverb256.ca"

echo "=== SearXNG Connectivity Test ==="
echo ""
echo "1. Testing SearXNG external instance..."
if curl -s "${SEARXNG_URL}/search?q=test&format=json" | jq -e '.results | length' >/dev/null 2>&1; then
	echo "   ✅ SearXNG is responding"
else
	echo "   ❌ SearXNG is not responding"
	exit 1
fi

echo ""
echo "2. Testing MCP wrapper..."
MCP_OUTPUT=$(/etc/nixos/modules/services/ai-inference/bin/searxng-mcp-wrapper 2>&1)
if [ -n "$MCP_OUTPUT" ]; then
	echo "   ✅ MCP wrapper is working"
else
	echo "   ❌ MCP wrapper failed"
	exit 1
fi
echo ""
echo "=== Tests Complete ==="

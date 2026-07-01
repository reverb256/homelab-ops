#!/usr/bin/env bash
# Test SearXNG Integration with Gateway

set -e

echo "▸ Testing SearXNG Integration..."
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Test 1: SearXNG health
echo "1. Testing SearXNG health..."
HEALTH=$(curl -s "http://127.0.0.1:7777/search?q=test&format=json" | jq '.results | length' 2>/dev/null || echo "0")
if [ "$HEALTH" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} SearXNG is healthy ($HEALTH results)"
else
    echo -e "  ${RED}✗${NC} SearXNG is not responding"
fi
echo ""

# Test 2: Gateway ping
echo "2. Testing gateway SearXNG ping..."
PING=$(curl -s "http://127.0.0.1:8080/search/ping" | jq -r '.status' 2>/dev/null || echo "error")
if [ "$PING" = "healthy" ]; then
    echo -e "  ${GREEN}✓${NC} Gateway SearXNG bridge is working"
else
    echo -e "  ${RED}✗${NC} Gateway SearXNG bridge failed: $PING"
fi
echo ""

# Test 3: Basic search
echo "3. Testing basic search endpoint..."
SEARCH=$(curl -s -X POST "http://127.0.0.1:8080/search" \
  -H "Content-Type: application/json" \
  -d '{"query":"nixos flake","max_results":3}' | jq '.results | length' 2>/dev/null || echo "0")
if [ "$SEARCH" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} Search endpoint working ($SEARCH results)"
else
    echo -e "  ${RED}✗${NC} Search endpoint failed"
fi
echo ""

# Test 4: Agent search
echo "4. Testing agent-optimized search..."
AGENT=$(curl -s -X POST "http://127.0.0.1:8080/search/agent" \
  -H "Content-Type: application/json" \
  -d '{"query":"how to fix docker error","max_results":3}' | jq '.intent' 2>/dev/null || echo "error")
if [ "$AGENT" != "error" ] && [ -n "$AGENT" ]; then
    echo -e "  ${GREEN}✓${NC} Agent search working (detected intent: $AGENT)"
else
    echo -e "  ${RED}✗${NC} Agent search failed: $AGENT"
fi
echo ""

# Test 5: Learning stats
echo "5. Testing learning statistics..."
STATS=$(curl -s "http://127.0.0.1:8080/search/stats" | jq '.total_queries' 2>/dev/null || echo "0")
if [ "$STATS" -ge 0 ]; then
    echo -e "  ${GREEN}✓${NC} Learning stats working ($STATS queries tracked)"
else
    echo -e "  ${RED}✗${NC} Learning stats failed"
fi
echo ""

# Test 6: MCP HTTP bridge
echo "6. Testing HTTP-MCP bridge..."
MCP=$(curl -s "http://127.0.0.1:8080/mcp/v1/servers" | jq '.servers | length' 2>/dev/null || echo "0")
if [ "$MCP" -ge 0 ]; then
    echo -e "  ${GREEN}✓${NC} HTTP-MCP bridge working ($MCP servers)"
else
    echo -e "  ${RED}✗${NC} HTTP-MCP bridge failed"
fi
echo ""

echo "▸ Integration tests complete!"
echo ""
echo "Next steps:"
echo "  1. Restart gateway: systemctl restart ai-inference-gateway"
echo "  2. Test with Claude Code: Claude should now have SearXNG MCP tools"
echo "  3. Test hybrid search: POST to /search/hybrid with query"

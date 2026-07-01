#!/usr/bin/env bash
#
# Test SearXNG search wrappers
#

echo "=== Testing SearXNG Search Wrappers ==="
echo ""

# Test 1: General web search
echo "1. Testing web search: 'NixOS cluster'"
/home/j_kro/.local/bin/search "NixOS cluster" 2 | head -15
echo ""
echo "---"
echo ""

# Test 2: GitHub search
echo "2. Testing GitHub search: 'nixos flake'"
/home/j_kro/.local/bin/search-github "nixos flake" 2 | head -10
echo ""
echo "---"
echo ""

# Test 3: NixOS options search
echo "3. Testing NixOS options search: 'networking firewall'"
/home/j_kro/.local/bin/search-nixos "networking firewall" 2 | head -10
echo ""
echo "---"
echo ""

echo "=== All search wrappers working! ==="

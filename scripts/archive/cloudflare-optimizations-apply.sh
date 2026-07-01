#!/usr/bin/env bash
#
# Cloudflare Optimizations
# ============================================
# This script applies Cloudflare optimizations to improve reliability,
# performance, and security.
#
# Usage:
#   export CLOUDFLARE_API_TOKEN="your_token_here"
#   ./cloudflare-optimizations-apply.sh
#
# Or run interactively (will prompt for token):
#   ./cloudflare-optimizations-apply.sh
#

set -euo pipefail

# Configuration
DOMAIN="reverb256.ca"
ZONE_ID="9062487114ef5404de8de6689cb54895"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get API token
get_token() {
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    echo "$CLOUDFLARE_API_TOKEN"
  elif [ -f "/run/agenix/cloudflare-api-token" ]; then
    cat /run/agenix/cloudflare-api-token
  else
    read -rp "Enter Cloudflare API token: " token
    echo "$token"
  fi
}

# Verify token works
verify_token() {
  local token="$1"

  log_info "Verifying API token..."

  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  local success
  success=$(echo "$response" | jq -r '.success // false')

  if [ "$success" = "true" ]; then
    log_success "API token is valid"
    return 0
  else
    log_error "API token is invalid or expired"
    echo "$response" | jq -r '.errors[]?.message' | head -1
    return 1
  fi
}

# Get current SSL/TLS setting
check_ssl_setting() {
  local token="$1"

  log_info "Checking current SSL/TLS setting..."

  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  local value
  value=$(echo "$response" | jq -r '.result.value // "unknown"')

  log_info "Current SSL/TLS setting: $value"

  case "$value" in
    "strict")
      log_success "SSL/TLS is already set to Full (strict) - optimal!"
      return 0
      ;;
    "full")
      log_warning "SSL/TLS is set to Full, recommend upgrading to Full (strict)"
      return 1
      ;;
    "flexible")
      log_warning "SSL/TLS is set to Flexible, NOT recommended for provider"
      return 1
      ;;
    *)
      log_warning "SSL/TLS setting unknown: $value"
      return 1
      ;;
  esac
}

# Set SSL/TLS to Full (strict)
set_ssl_strict() {
  local token="$1"

  log_info "Setting SSL/TLS to Full (strict)..."

  local response
  response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data '{"value":"strict"}')

  local success
  success=$(echo "$response" | jq -r '.success // false')

  if [ "$success" = "true" ]; then
    log_success "SSL/TLS set to Full (strict)"
    return 0
  else
    log_error "Failed to set SSL/TLS"
    echo "$response" | jq -r '.errors[]?.message' | head -1
    return 1
  fi
}

# Check minimum TLS version
check_min_tls() {
  local token="$1"

  log_info "Checking minimum TLS version..."

  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/min_tls_version" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  local value
  value=$(echo "$response" | jq -r '.result.value // "unknown"')

  log_info "Current minimum TLS version: $value"

  if [ "$value" = "1.2" ] || [ "$value" = "1.3" ]; then
    log_success "Minimum TLS version is already secure (1.2+)"
    return 0
  else
    log_warning "Minimum TLS version is $value, recommend 1.2 or higher"
    return 1
  fi
}

# Set minimum TLS version to 1.2
set_min_tls() {
  local token="$1"

  log_info "Setting minimum TLS version to 1.2..."

  local response
  response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/min_tls_version" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data '{"value":"1.2"}')

  local success
  success=$(echo "$response" | jq -r '.success // false')

  if [ "$success" = "true" ]; then
    log_success "Minimum TLS version set to 1.2"
    return 0
  else
    log_error "Failed to set minimum TLS version"
    echo "$response" | jq -r '.errors[]?.message' | head -1
    return 1
  fi
}

# List all DNS records
list_dns_records() {
  local token="$1"

  log_info "Listing DNS records for tenant domains..."

  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=100" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  echo "$response" | jq -r '.result[] | select(.name | test("ingress|dedicated")) | "\(.name) \(.type) \(.content) TTL=\(.ttl) Proxied=\(.proxied)"'
}

# Check for existing page rules
check_page_rules() {
  local token="$1"

  log_info "Checking for existing page rules..."
  log_warning "Page rules cannot be managed via API - must use dashboard"
  echo ""
  echo "MANUAL STEP REQUIRED:"
  echo "1. Go to: https://dash.cloudflare.com/$ZONE_ID/rules/page-rules"
  echo "2. Create rule for: *.ingress.reverb256.ca/*"
  echo "   - Cache Level: Bypass"
  echo "3. Create rule for: *.dedicated.ingress.reverb256.ca/*"
  echo "   - Cache Level: Bypass"
  echo ""
}

# Check for existing rate limit rules
check_rate_limits() {
  local token="$1"

  log_info "Checking for existing rate limit rules..."
  log_warning "Rate limiting requires Cloudflare Pro plan or higher"
  echo ""
  echo "MANUAL STEP REQUIRED (if Pro plan available):"
  echo "1. Go to: https://dash.cloudflare.com/$ZONE_ID/security/rate-limiting-rules"
  echo "2. Create rule: provider.reverb256.ca/* → 100 req/min"
  echo "3. Create rule: grpc.provider.reverb256.ca/* → 50 req/min"
  echo ""
}

# Generate summary report
generate_report() {
  local token="$1"

  echo ""
  echo "======================================================================"
  echo "  Cloudflare Optimization Report for $DOMAIN"
  echo "======================================================================"
  echo ""

  # SSL/TLS Check
  if check_ssl_setting "$token"; then
    echo "✅ SSL/TLS: Optimal (Full strict)"
  else
    echo "⚠️  SSL/TLS: Needs attention"
  fi

  # Minimum TLS Check
  if check_min_tls "$token"; then
    echo "✅ Minimum TLS: Secure (1.2+)"
  else
    echo "⚠️  Minimum TLS: Needs upgrade to 1.2"
  fi

  echo ""
  echo "DNS Records:"
  list_dns_records "$token" | while read -r line; do
    echo "  - $line"
  done

  echo ""
  check_page_rules "$token"
  check_rate_limits "$token"

  echo "======================================================================"
  echo ""
}

# Apply all optimizations
apply_optimizations() {
  local token="$1"

  log_info "Applying Cloudflare optimizations for $DOMAIN..."
  echo ""

  # SSL/TLS
  if ! check_ssl_setting "$token"; then
    log_info "Upgrading SSL/TLS to Full (strict)..."
    if set_ssl_strict "$token"; then
      log_success "SSL/TLS upgraded successfully"
    else
      log_error "Failed to upgrade SSL/TLS - manual intervention required"
    fi
  fi

  # Minimum TLS
  if ! check_min_tls "$token"; then
    log_info "Upgrading minimum TLS version to 1.2..."
    if set_min_tls "$token"; then
      log_success "Minimum TLS version upgraded successfully"
    else
      log_error "Failed to upgrade minimum TLS - manual intervention required"
    fi
  fi

  echo ""
  log_success "Automatic optimizations complete!"
  echo ""
  log_warning "Some optimizations require manual steps via Cloudflare Dashboard:"
  echo "  - Page rules for cache bypass"
  echo "  - Rate limiting rules"
  echo "  - Security headers"
  echo ""
  echo "See: docs/cloudflare-optimizations.md"
}

# Main function
main() {
  echo "======================================================================"
  echo "  Cloudflare Optimizations"
  echo "  Domain: $DOMAIN"
  echo "  Zone ID: $ZONE_ID"
  echo "======================================================================"
  echo ""

  # Get and verify token
  TOKEN=$(get_token)
  if ! verify_token "$TOKEN"; then
    exit 1
  fi

  echo ""

  # Parse arguments
  case "${1:-apply}" in
    check)
      generate_report "$TOKEN"
      ;;
    apply)
      apply_optimizations "$TOKEN"
      generate_report "$TOKEN"
      ;;
    ssl)
      set_ssl_strict "$TOKEN"
      ;;
    tls)
      set_min_tls "$TOKEN"
      ;;
    dns)
      list_dns_records "$TOKEN"
      ;;
    *)
      echo "Usage: $0 [check|apply|ssl|tls|dns]"
      echo ""
      echo "Commands:"
      echo "  check  - Show current configuration status"
      echo "  apply  - Apply all automatic optimizations"
      echo "  ssl    - Set SSL/TLS to Full (strict)"
      echo "  tls    - Set minimum TLS version to 1.2"
      echo "  dns    - List all DNS records"
      echo ""
      exit 1
      ;;
  esac
}

# Run main
main "$@"

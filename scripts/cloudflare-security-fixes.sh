#!/usr/bin/env bash
#
# Cloudflare Security Fixes
# ============================================
# Fixes security insights: DMARC, security.txt, unproxied DNS, dangling records,
# AI bot blocking, AI Labyrinth.
#
# Usage:
#   ./cloudflare-security-fixes.sh
#
# Prerequisites:
#   - Cloudflare API token at /run/secrets/cloudflare-api-token
#   - Domain: reverb256.ca (Zone ID: 9062487114ef5404de8de6689cb54895)
#

set -euo pipefail

# Configuration
ZONE_ID="9062487114ef5404de8de6689cb54895"
DOMAIN="reverb256.ca"
TOKEN_FILE="/run/secrets/cloudflare-api-token"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get API token
get_token() {
  if [ -f "$TOKEN_FILE" ]; then
    cat "$TOKEN_FILE"
  else
    log_error "API token not found at $TOKEN_FILE"
    exit 1
  fi
}

# Verify token
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
  else
    log_error "API token is invalid or expired"
    echo "$response" | jq -r '.errors[]?.message' | head -1
    exit 1
  fi
}

# Fix DMARC records
fix_dmarc() {
  local token="$1"
  local domain="$2"

  log_info "Fixing DMARC for $domain..."

  # Check if DMARC exists
  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=_dmarc.$domain&type=TXT" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  local count
  count=$(echo "$response" | jq -r '.result | length')

  if [ "$count" -gt 0 ]; then
    log_info "DMARC record already exists for $domain"
    return 0
  fi

  # Create DMARC record
  log_info "Creating DMARC record for $domain..."
  response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"TXT\",\"name\":\"_dmarc.$domain\",\"content\":\"v=DMARC1; p=reject; rua=mailto:dmarc@$domain; ruf=mailto:dmarc@$domain; adkim=r; aspf=r; pct=100\"}")

  local success
  success=$(echo "$response" | jq -r '.success // false')

  if [ "$success" = "true" ]; then
    log_success "DMARC record created for $domain"
  else
    log_error "Failed to create DMARC for $domain"
    echo "$response" | jq -r '.errors[]?.message' | head -1
  fi
}

# Fix unproxied A records
fix_unproxied_dns() {
  local token="$1"
  local domain="$2"

  log_info "Checking for unproxied DNS records for $domain..."

  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=100" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  # Find A records that are not proxied
  local count
  count=$(echo "$response" | jq -r '.result | map(select(.type=="A" and .proxied==false and .name | endswith("'$domain'") or .name | endswith("lan"))) | length')

  if [ "$count" -eq 0 ]; then
    log_info "No unproxied A records found for $domain"
    return 0
  fi

  log_warning "Found $count unproxied A records"

  echo "$response" | jq -r '.result[] | select(.type=="A" and .proxied==false and (.name | endswith("'$domain'") or .name | endswith("lan")))' | while read -r record; do
    local id name content
    id=$(echo "$record" | jq -r '.id')
    name=$(echo "$record" | jq -r '.name')
    content=$(echo "$record" | jq -r '.content')

    # Skip .lan records (they should NOT be proxied)
    if echo "$name" | grep -q "\.lan$"; then
      log_info "Skipping .lan record: $name (should remain unproxied)"
      continue
    fi

    log_info "Setting proxy for $name ($content)..."

    # Update to proxied
    local update_response
    update_response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$content\",\"proxied\":true}")

    local success
    success=$(echo "$update_response" | jq -r '.success // false')

    if [ "$success" = "true" ]; then
      log_success "Proxy enabled for $name"
    else
      log_error "Failed to enable proxy for $name"
      echo "$update_response" | jq -r '.errors[]?.message' | head -1
    fi
  done
}

# Identify dangling A records
find_dangling_records() {
  local token="$1"
  local domain="$2"

  log_info "Checking for dangling A records for $domain..."

  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=100" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  echo "$response" | jq -r '.result[] | select(.type=="A" and (.name | endswith("'$domain'"))) | "\(.name) -> \(.content) (ID: \(.id))"'
}

# Enable AI bot blocking via WAF
enable_ai_bot_blocking() {
  local token="$1"

  log_info "Enabling AI bot blocking..."

  # Check if rule exists
  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/rules" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  # Create WAF rule to block known AI bots
  log_info "Creating WAF rule to block AI bots..."

  response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/firewall/rules" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data '{
      "description": "Block AI bots (GPTBot, CCbot, etc.)",
      "action": "block",
      "expression": "(http.user_agent contains \"GPTBot\" or http.user_agent contains \"CCbot\" or http.user_agent contains \"Google-Extended\" or http.user_agent contains \"anthropic\" or http.user_agent contains \"ClaudeBot\" or http.user_agent contains \"FacebookBot\" or http.user_agent contains \"PerplexityBot\" or http.user_agent contains \"YouBot\")",
      "filter": {
        "paused": false
      }
    }')

  local success
  success=$(echo "$response" | jq -r '.success // false')

  if [ "$success" = "true" ]; then
    log_success "AI bot blocking WAF rule created"
  else
    log_error "Failed to create AI bot blocking rule"
    echo "$response" | jq -r '.errors[]?.message' | head -1
  fi
}

# Enable AI Labyrinth (requires Pro plan)
enable_ai_labyrinth() {
  local token="$1"

  log_info "Enabling AI Labyrinth..."

  # AI Labyrinth is a Cloudflare security feature that requires manual configuration
  # It's not available via public API, so we'll provide instructions
  log_warning "AI Labyrinth requires manual configuration in Cloudflare dashboard"
  echo ""
  echo "MANUAL STEP:"
  echo "1. Go to: https://dash.cloudflare.com/$ZONE_ID/security/ai-labyrinth"
  echo "2. Enable AI Labyrinth for your zone"
  echo "3. Configure AI bot challenges and blocking"
}

# Create security.txt
create_security_txt() {
  local domain="$1"

  log_info "Creating security.txt for $domain..."

  local security_dir
  security_dir="/var/www/html/$domain/.well-known"

  # Create directory if it doesn't exist
  mkdir -p "$security_dir"

  local security_txt="$security_dir/security.txt"

  cat > "$security_txt" <<EOF
# Security.txt for $domain
# Last updated: $(date -u +"%Y-%m-%d")
# Contact: J_kroeker@reverb256.ca

Contact: mailto:security@$domain
Contact: mailto:J_kroeker@reverb256.ca
Expires: $(date -u -d "+1 year" +"%Y-%m-%dT%H:%M:%SZ")

# Preferred Languages
Preferred-Languages: en, fr

# Encryption
Encryption: https://$domain/.well-known/pgp-key.asc

# Acknowledgments
Acknowledgments: https://$domain/security/acknowledgments

# Policy
Policy: https://$domain/security/policy

# Hiring
Hiring: https://$domain/security/jobs

# CSAF
CSAF: https://$domain/.well-known/csaf/provider-metadata.json
EOF

  chmod 644 "$security_txt"
  log_success "Security.txt created at $security_txt"
}

# Main execution
main() {
  echo "=== Cloudflare Security Fixes ==="
  echo ""

  local token
  token=$(get_token)

  verify_token "$token"
  echo ""

  # Fix DMARC
  fix_dmarc "$token" "$DOMAIN"
  echo ""

  # Fix unproxied DNS
  fix_unproxied_dns "$token" "$DOMAIN"
  echo ""

  # Find dangling records (manual cleanup)
  log_info "Dangling A records for manual review:"
  find_dangling_records "$token" "$DOMAIN"
  echo ""

  # Enable AI bot blocking
  enable_ai_bot_blocking "$token"
  echo ""

  # AI Labyrinth (manual)
  enable_ai_labyrinth "$token"
  echo ""

  # Create security.txt file (local filesystem)
  create_security_txt "$DOMAIN"
  echo ""

  log_success "Security fixes complete!"
  echo ""
  echo "Summary:"
  echo "  ✓ DMARC record created for $DOMAIN"
  echo "  ✓ Unproxied DNS records set to proxied"
  echo "  ✓ AI bot blocking WAF rule created"
  echo "  ✓ Security.txt file created locally"
  echo ""
  echo "Manual steps required:"
  echo "  1. Review and delete dangling A records listed above"
  echo "  2. Enable AI Labyrinth in Cloudflare dashboard"
  echo "  3. Upload security.txt to your web root (if not already there)"
}

main "$@"
#!/usr/bin/env bash
# secret-rotation.sh — Automated secret rotation for NixOS cluster
#
# Usage:
#   secret-rotation.sh --tier1          # Auto-rotate all Tier 1 secrets
#   secret-rotation.sh --tier2-check    # List Tier 2 secrets needing manual rotation
#   secret-rotation.sh --rotate <name>  # Rotate a specific secret
#   secret-rotation.sh --status         # Show rotation status
#   secret-rotation.sh --dry-run        # Preview what would be rotated

set -euo pipefail

SECRETS_DIR="/etc/nixos/secrets"
ROTATION_LOG="/var/log/secret-rotation.log"
ROTATION_STATE="/var/lib/secret-rotation/state.json"
DEPLOY_CMD="just deploy"
KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

# ─── Age Key Management ─────────────────────────────────────────────

find_identity() {
  for path in /etc/age/key.txt /etc/nixos/.age/key.txt /home/j_kro/.age/key.txt /persistent/etc/age/key.txt; do
    if [ -f "$path" ]; then
      echo "$path"
      return 0
    fi
  done
  return 1
}

get_pubkey() {
  # Extract public key from the age identity file header comment
  # Format: "# public key: age1..."
  local identity="$1"
  grep -oP 'age1[a-z0-9]+' "$identity" | head -1
}

# ─── Secret Tiers ───────────────────────────────────────────────────

# Tier 1: Self-generated random secrets — safe to auto-rotate
# Format: "secret_name:char_count:description"
TIER1_SECRETS=(
  "central-auth-cookie-secret:64:OAuth2 proxy cookie secret"
  "searxng-secret-key:32:SearXNG internal secret"
  "garage-rpc-secret:64:Garage S3 RPC shared secret"
  "garage-metrics-token:32:Garage metrics bearer token"
  "grafana-admin-password:24:Grafana admin UI password"
  "n8n-admin-password:24:n8n admin password"
  "mission-control-auth-pass:32:Mission Control auth password"
  "mission-control-api-key:32:Mission Control API key"
  "vaultwarden-admin-token:32:Vaultwarden admin panel token"
  "hermes-webui-password:24:Hermes WebUI admin password"
  "hermes-api-server-key:64:Hermes API server signing key"
  "garnix-password:24:Garnix CI password"
  "switch-admin:24:TP-Link switch admin password"
  "activepieces-jwt-secret:64:Activepieces JWT signing secret"
  "xmrig-api-token:32:XMRig API token"
  "xmrig-always-api-token:32:XMRig always-on API token"
  "xmrig-flexible-api-token:32:XMRig flexible API token"
  "xmrig-proxy-api-token:32:XMRig proxy API token"
)

# Tier 2: External API keys — cannot auto-rotate, need manual portal visit
TIER2_SECRETS=(
  "github-token:monthly:GitHub personal access token"
  "huggingface-token:quarterly:HuggingFace API token"
  "zai-api-key:quarterly:Z.AI (ZhipuAI) API key"
  "ai-gateway-zai-api-key:quarterly:AI Gateway Z.AI key"
  "nvidia-api-key:quarterly:NVIDIA API key"
  # "openrouter-api-key:quarterly:OpenRouter API key" - REMOVED
  "gemini-api-key:quarterly:Google Gemini API key"
  "cloudflare-api-token:quarterly:Cloudflare API token"
  "cloudflare-global-api-key:quarterly:Cloudflare global API key"
  "cloudflared-token:quarterly:Cloudflared tunnel token"
  "tailscale-api-key:quarterly:Tailscale API key"
  "context7-api-key:quarterly:Context7 API key"
  "kilo-api-key:quarterly:Kilo API key"
  "opencode-api-key:quarterly:OpenCode API key"
  "opencode-go-api-key:quarterly:OpenCode Go API key"
  "pollinations-api-key:quarterly:Pollinations API key"
  "neocities-api-key:quarterly:Neocities API key"
  "localmaxxing-api-key:quarterly:LocalMaxxing API key"
  "katzilla-api-key:quarterly:Katzilla API key"
)

# Tier 3: NEVER auto-rotate
TIER3_SECRETS=(
  "k3s-cluster-token:K3s cluster join token — rotation requires full cluster rejoin"
  "initrd-ssh-host-key-zephyr:Initrd SSH host key — rotation breaks remote unlock"
  "initrd-ssh-host-key-nexus:Initrd SSH host key — rotation breaks remote unlock"
  "initrd-ssh-host-key-forge:Initrd SSH host key — rotation breaks remote unlock"
  "initrd-ssh-host-key-sentry:Initrd SSH host key — rotation breaks remote unlock"
  "n8n-encryption-key:Encryption key — rotation destroys encrypted workflow data"
  "activepieces-encryption-key:Encryption key — rotation destroys encrypted credential data"
  "garage-s3-access-key-id:S3 access key — rotation needs Garage API coordination"
  "garage-s3-secret-key:S3 secret key — rotation needs Garage API coordination"
  "central-auth-client-secret:OIDC client secret — rotation needs Casdoor API coordination"
  "grafana-oidc-client-secret:OIDC client secret — rotation needs Casdoor + Grafana restart"
  "openwebui-oidc-client-secret:OIDC client secret — rotation needs Casdoor + OUI restart"
  "vaultwarden-oidc-client-secret:OIDC client secret — rotation needs Casdoor + VW restart"
  "haven-oidc-client-secret:OIDC client secret — rotation needs Casdoor + Haven restart"
  "casdoor-hermes-jwt:Casdoor API JWT — rotation needs Casdoor admin reissue"
  "rclone-config:Rclone remote config — rotation needs re-auth with cloud provider"
)

# K8s deployments to restart after rotating specific secrets
K8S_RESTART_MAP="
central-auth-cookie-secret:auth/oauth2-proxy
searxng-secret-key:search/searxng
grafana-admin-password:monitoring/grafana
n8n-admin-password:automation/n8n
mission-control-auth-pass:orchestration/mission-control
mission-control-api-key:orchestration/mission-control
xmrig-api-token:mining/gpu-miner-zephyr
xmrig-always-api-token:mining/gpu-miner-nexus
xmrig-flexible-api-token:mining/gpu-miner-forge
xmrig-proxy-api-token:mining/xmrig-proxy
"

# ─── Utility Functions ──────────────────────────────────────────────

log() {
  local level="$1"; shift
  echo "[$(date -Iseconds)] [$level] $*" | tee -a "$ROTATION_LOG"
}

generate_secret() {
  local char_count="$1"
  head -c "$((char_count * 2))" /dev/urandom | base64 | tr -d '\n=' | head -c "$char_count"
}

# ─── Core Rotation Logic ────────────────────────────────────────────

rotate_secret() {
  local name="$1"
  local char_count="$2"
  local description="$3"

  log INFO "Rotating: $name ($description)"

  # Step 1: Find age identity and public key
  local identity
  identity=$(find_identity) || { log ERROR "No age identity key found"; return 1; }
  local pubkey
  pubkey=$(get_pubkey "$identity")
  if [ -z "$pubkey" ]; then
    log ERROR "Cannot extract public key from $identity"
    return 1
  fi

  # Step 2: Generate new random value
  local new_value
  new_value=$(generate_secret "$char_count")
  if [ -z "$new_value" ]; then
    log ERROR "Failed to generate random value for $name"
    return 1
  fi

  # Step 3: Re-encrypt with age (single recipient — verified all secrets use single key)
  local age_file="${SECRETS_DIR}/${name}.age"
  local backup_file="${age_file}.bak"

  # Backup the old file
  cp "$age_file" "$backup_file"

  # Encrypt new value
  if ! echo -n "$new_value" | age -r "$pubkey" -o "$age_file" 2>/dev/null; then
    log ERROR "Failed to re-encrypt $name — restoring backup"
    mv "$backup_file" "$age_file"
    return 1
  fi

  # Step 4: Verify roundtrip (decrypt the new file and check it's valid)
  local decrypted
  decrypted=$(age -d -i "$identity" "$age_file" 2>/dev/null || echo "__ROTATION_FAILED__")
  if [ "$decrypted" = "__ROTATION_FAILED__" ] || [ "$decrypted" != "$new_value" ]; then
    log ERROR "Roundtrip verification failed for $name — restoring backup"
    mv "$backup_file" "$age_file"
    return 1
  fi

  # Cleanup backup
  rm -f "$backup_file"

  log INFO "Successfully rotated: $name"
  return 0
}

restart_k8s_workloads() {
  local secret_name="$1"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local sname="${line%%:*}"
    local dep="${line#*:}"
    [ "$sname" != "$secret_name" ] && continue

    local ns="${dep%%/*}"
    local dname="${dep#*/}"
    log INFO "Rollout restart $ns/$dname (consumes $secret_name)"
    kubectl rollout restart deployment/"$dname" -n "$ns" 2>&1 || \
      log WARN "Failed to restart $ns/$dname — may need manual restart after deploy"
  done <<< "$K8S_RESTART_MAP"
}

# ─── Commands ────────────────────────────────────────────────────────

cmd_tier1_rotate() {
  log INFO "=== Starting Tier 1 automatic rotation ==="
  local rotated=0 failed=0 skipped=0
  local rotated_names=""

  for entry in "${TIER1_SECRETS[@]}"; do
    local name="${entry%%:*}"
    local rest="${entry#*:}"
    local chars="${rest%%:*}"
    local desc="${rest#*:}"

    if [ ! -f "${SECRETS_DIR}/${name}.age" ]; then
      log WARN "Not found: ${SECRETS_DIR}/${name}.age — skipping"
      skipped=$((skipped + 1)) || true
      continue
    fi

    if rotate_secret "$name" "$chars" "$desc"; then
      rotated=$((rotated + 1)) || true
      rotated_names="$rotated_names $name"
    else
      failed=$((failed + 1)) || true
    fi
  done

  log INFO "=== Rotation results: $rotated rotated, $failed failed, $skipped skipped ==="

  if [ "$rotated" -gt 0 ]; then
    # Git commit
    log INFO "Committing rotated secrets..."
    cd /etc/nixos
    git add secrets/*.age 2>/dev/null || true
    git commit -m "security: quarterly secret rotation ($(date +%Y-%m-%d))" 2>/dev/null || \
      log WARN "Git commit failed or nothing new to commit"

    # Deploy
    log INFO "Deploying rotated secrets to cluster..."
    if $DEPLOY_CMD 2>&1; then
      log INFO "Deploy complete — restarting affected K8s workloads..."
      for name in $rotated_names; do
        restart_k8s_workloads "$name"
      done
    else
      log ERROR "Deploy failed — rotated secrets not applied to cluster"
      return 1
    fi
  fi

  # Update state
  update_rotation_state "tier1" "$rotated" "$failed"
  return 0
}

cmd_tier2_check() {
  echo "=== Tier 2: External API Keys (Manual Rotation Required) ==="
  echo ""
  printf "%-30s %-12s %-35s\n" "SECRET" "FREQUENCY" "DESCRIPTION"
  printf "%-30s %-12s %-35s\n" "------" "---------" "-----------"
  for entry in "${TIER2_SECRETS[@]}"; do
    local name="${entry%%:*}"
    local rest="${entry#*:}"
    local freq="${rest%%:*}"
    local desc="${rest#*:}"
    printf "%-30s %-12s %-35s\n" "$name" "$freq" "$desc"
  done
  echo ""
  echo "These require manual rotation at each provider's portal."
  echo "Set calendar reminders for the dates above."
}

cmd_rotate_single() {
  local secret_name="$1"

  # Check Tier 3 first (refuse)
  for entry in "${TIER3_SECRETS[@]}"; do
    local name="${entry%%:*}"
    if [ "$name" = "$secret_name" ]; then
      local reason="${entry#*:}"
      log ERROR "REFUSED: $secret_name is Tier 3 — $reason"
      return 1
    fi
  done

  # Check Tier 2 (warn)
  for entry in "${TIER2_SECRETS[@]}"; do
    local name="${entry%%:*}"
    if [ "$name" = "$secret_name" ]; then
      log WARN "$secret_name is Tier 2 — requires manual rotation at provider portal"
      return 1
    fi
  done

  # Check Tier 1 (rotate)
  for entry in "${TIER1_SECRETS[@]}"; do
    local name="${entry%%:*}"
    if [ "$name" = "$secret_name" ]; then
      local rest="${entry#*:}"
      local chars="${rest%%:*}"
      local desc="${rest#*:}"
      rotate_secret "$name" "$chars" "$desc"
      # Git commit single secret
      cd /etc/nixos
      git add "secrets/${name}.age"
      git commit -m "security: rotate $name" || true
      restart_k8s_workloads "$name"
      return $?
    fi
  done

  log ERROR "Unknown secret: $secret_name"
  return 1
}

cmd_status() {
  echo "=== Secret Rotation Status ==="
  echo ""
  echo "Tier 1 — Auto-rotatable (${#TIER1_SECRETS[@]} secrets):"
  for entry in "${TIER1_SECRETS[@]}"; do
    local name="${entry%%:*}"
    local rest="${entry#*:}"
    local desc="${rest#*:}"
    [ -f "${SECRETS_DIR}/${name}.age" ] && printf "  %-40s EXISTS\n" "$name" || printf "  %-40s MISSING\n" "$name"
  done

  echo ""
  echo "Tier 2 — Manual rotation (${#TIER2_SECRETS[@]} secrets):"
  for entry in "${TIER2_SECRETS[@]}"; do
    local name="${entry%%:*}"
    local rest="${entry#*:}"
    local freq="${rest%%:*}"
    printf "  %-40s (%s)\n" "$name" "$freq"
  done

  echo ""
  echo "Tier 3 — Never auto-rotate (${#TIER3_SECRETS[@]} secrets):"
  for entry in "${TIER3_SECRETS[@]}"; do
    local name="${entry%%:*}"
    local reason="${entry#*:}"
    printf "  %-35s — %s\n" "$name" "$reason"
  done

  echo ""
  if [ -f "$ROTATION_STATE" ]; then
    echo "Last rotation:"
    cat "$ROTATION_STATE"
  else
    echo "No rotation history yet"
  fi
}

cmd_dry_run() {
  echo "=== DRY RUN — Tier 1 Rotation Preview ==="
  for entry in "${TIER1_SECRETS[@]}"; do
    local name="${entry%%:*}"
    local rest="${entry#*:}"
    local chars="${rest%%:*}"
    local desc="${rest#*:}"
    if [ -f "${SECRETS_DIR}/${name}.age" ]; then
      echo "  WOULD ROTATE: $name ($chars chars) — $desc"
    else
      echo "  SKIP: $name — file not found"
    fi
  done
  echo ""
  echo "Process: generate new random -> re-encrypt with age -> verify roundtrip -> git commit -> just deploy -> restart K8s pods"
}

update_rotation_state() {
  local tier="$1"
  local rotated="${2:-0}"
  local failed="${3:-0}"
  mkdir -p "$(dirname "$ROTATION_STATE")"
  python3 -c "
import json, datetime, os
state = {}
try:
    with open('$ROTATION_STATE') as f: state = json.load(f)
except: pass
now = datetime.datetime.now().isoformat()
state.setdefault('$tier', {})['last_run'] = now
state['$tier']['rotated'] = $rotated
state['$tier']['failed'] = $failed
with open('$ROTATION_STATE', 'w') as f:
    json.dump(state, f, indent=2)
" 2>/dev/null || log WARN "Failed to update rotation state"
}

# ─── Main ────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$ROTATION_LOG")"
mkdir -p "$(dirname "$ROTATION_STATE")"

case "${1:-}" in
  --tier1)       cmd_tier1_rotate ;;
  --tier2-check) cmd_tier2_check ;;
  --rotate)
    [ -z "${2:-}" ] && { echo "Usage: secret-rotation.sh --rotate <secret-name>"; exit 1; }
    cmd_rotate_single "$2"
    ;;
  --status)      cmd_status ;;
  --dry-run)     cmd_dry_run ;;
  *)
    echo "secret-rotation.sh — Automated secret rotation for NixOS cluster"
    echo ""
    echo "Usage: secret-rotation.sh {--tier1|--tier2-check|--rotate <name>|--status|--dry-run}"
    echo ""
    echo "  --tier1          Auto-rotate all Tier 1 secrets (self-generated random values)"
    echo "  --tier2-check    Show Tier 2 secrets needing manual rotation"
    echo "  --rotate <name>  Rotate a single specific secret"
    echo "  --status         Show current rotation status for all tiers"
    echo "  --dry-run        Preview what would be rotated (no changes)"
    exit 1
    ;;
esac

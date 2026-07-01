#!/usr/bin/env bash
#
# cleanup-zombie-pods.sh
#
# Purpose: Clean up Failed/Unknown/Evicted pods that are consuming Flannel IP addresses
#
# Background: The Flannel overlay network allocates IPs from a /24 subnet (254 IPs per node).
# When pods fail but aren't deleted, they continue consuming IP addresses until the pool
# is exhausted, preventing new pods from being scheduled.
#
# Usage:
#   ./cleanup-zombie-pods.sh          # Show count only
#   ./cleanup-zombie-pods.sh --dry-run # Show what would be deleted
#   ./cleanup-zombie-pods.sh --clean   # Actually delete zombie pods
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Count zombie pods
count_zombies() {
  local count
  count=$(kubectl get pods -A | grep -E "Failed|Unknown|ImagePullBackOff|Evicted" | wc -l | tr -d ' ')
  echo "$count"
}

# Show zombie pods by namespace
show_zombies() {
  log_info "Scanning for zombie pods..."
  echo ""

  local count
  count=$(count_zombies)

  echo "Total zombie pods: ${RED}${count}${NC}"
  echo ""

  if [[ "$count" -gt 0 ]]; then
    echo "Breakdown by status:"
    kubectl get pods -A | grep -E "Failed|Unknown|ImagePullBackOff|Evicted" | awk '{print $5}' | sort | uniq -c | sort -rn
    echo ""

    echo "Top 10 namespaces with zombies:"
    kubectl get pods -A | grep -E "Failed|Unknown|ImagePullBackOff|Evicted" | awk '{print $1}' | sort | uniq -c | sort -rn | head -10
    echo ""

    echo "Sample pods (first 20):"
    kubectl get pods -A | grep -E "Failed|Unknown|ImagePullBackOff|Evicted" | head -20 | awk '{printf "  %-40s %-10s %s\n", $1 "/" $2, $5, $6}'
  fi
}

# Dry run - show what would be deleted
dry_run() {
  log_info "Dry run mode - showing pods that would be deleted..."
  echo ""

  local count
  count=$(count_zombies)

  if [[ "$count" -eq 0 ]]; then
    log_info "✅ No zombie pods found!"
    return 0
  fi

  echo "Would delete ${count} zombie pods"
  echo ""

  echo "Sample (first 50):"
  kubectl get pods -A | grep -E "Failed|Unknown|ImagePullBackOff|Evicted" | head -50 | awk '{printf "  %s/%s\n", $1, $2}'
}

# Clean up zombie pods
clean_zombies() {
  log_warn "Deleting zombie pods in batches of 100..."
  echo ""

  local total
  total=$(count_zombies)

  if [[ "$total" -eq 0 ]]; then
    log_info "✅ No zombie pods found!"
    return 0
  fi

  log_info "Total zombie pods: ${total}"
  log_info "This will take a few minutes..."
  echo ""

  local deleted=0
  local batch=0

  # Get all zombie pods and delete in batches
  kubectl get pods -A | grep -E "Failed|Unknown|ImagePullBackOff|Evicted" | while read -r namespace rest; do
    local pod_name
    pod_name=$(echo "$rest" | awk '{print $1}')

    # Delete pod with short timeout
    if kubectl delete pod -n "$namespace" "$pod_name" --grace-period=5 --timeout=5s >/dev/null 2>&1; then
      ((deleted++)) || true
      ((batch++)) || true

      # Progress every 100 deletions
      if [[ $((batch % 100)) -eq 0 ]]; then
        echo "[$deleted/$total] Deleted batch..."
        batch=0
      fi
    fi
  done

  echo ""
  log_info "✅ Cleanup complete!"
  echo ""

  # Verify cleanup
  local remaining
  remaining=$(count_zombies)

  if [[ "$remaining" -gt 0 ]]; then
    log_warn "⚠️  $remaining zombie pods remain (may need to run again)"
  else
    log_info "✅ All zombie pods removed!"
  fi
}

# Check Flannel IP exhaustion
check_flannel() {
  log_info "Checking Flannel IP pool status..."
  echo ""

  # Check each node's pod CIDR
  kubectl get nodes -o custom-name=NAME:.metadata.name -o custom-name=POD_CIDR:.spec.podCIDR | grep -v "POD_CIDR" | while read -r node cidr; do
    if [[ -n "$cidr" ]]; then
      # Count pods on this node
      local pod_count
      pod_count=$(kubectl get pods -A --field-selector spec.nodeName="$node" --no-headers 2>/dev/null | wc -l | tr -d ' ')

      # Calculate IPs in CIDR
      local ip_count
      if [[ "$cidr" =~ /([0-9]+) ]]; then
        local prefix=${BASH_REMATCH[1]}
        ip_count=$((2 ** (32 - prefix)))
      fi

      local usage
      usage=$((pod_count * 100 / ip_count))

      printf "  %-15s %-20s %4s/%-5s IPs (%3s%%)" "$node" "$cidr" "$pod_count" "$ip_count" "$usage"

      if [[ $usage -gt 90 ]]; then
        echo " ${RED}⚠️  HIGH USAGE${NC}"
      elif [[ $usage -gt 75 ]]; then
        echo " ${YELLOW}⚠️  MEDIUM USAGE${NC}"
      else
        echo " ${GREEN}✅${NC}"
      fi
    fi
  done
  echo ""
}

# Main
main() {
  local action="${1:-status}"

  case "$action" in
    status|--status)
      show_zombies
      check_flannel
      ;;
    dry-run|--dry-run)
      show_zombies
      echo ""
      dry_run
      ;;
    clean|--clean)
      show_zombies
      check_flannel
      echo ""
      dry_run
      echo ""
      read -p "Continue with deletion? (yes/no): " confirm
      if [[ "$confirm" == "yes" ]]; then
        clean_zombies
      else
        log_info "Cancelled."
      fi
      ;;
    force|--force)
      show_zombies
      check_flannel
      echo ""
      log_warn "Force mode - deleting without confirmation..."
      echo ""
      clean_zombies
      ;;
    *)
      log_error "Unknown action: $action"
      echo ""
      echo "Usage: $0 [status|dry-run|clean|force]"
      echo ""
      echo "Actions:"
      echo "  status    Show zombie pod count and Flannel IP usage (default)"
      echo "  dry-run   Show what would be deleted"
      echo "  clean     Delete zombie pods (with confirmation)"
      echo "  force     Delete zombie pods (no confirmation)"
      exit 1
      ;;
  esac
}

main "$@"

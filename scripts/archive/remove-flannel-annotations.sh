#!/usr/bin/env bash
# Remove Flannel annotations from all nodes
# Required for Calico to properly manage node podCIDRs

set -e

echo "Removing Flannel annotations from all nodes..."

# Get all nodes
nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

for node in $nodes; do
  echo "Processing node: $node"

  # Remove Flannel annotations
  kubectl annotate node "$node" \
    flannel.alpha.coreos.com/backend-data- \
    flannel.alpha.coreos.com/backend-type- \
    flannel.alpha.coreos.com/kube-subnet-manager- \
    flannel.alpha.coreos.com/public-ip- \
    --overwrite 2>/dev/null || echo "  Some annotations not found on $node"

  # Remove old podCIDR if it's the Flannel one (10.244.x.x)
  current_cidr=$(kubectl get node "$node" -o jsonpath='{.spec.podCIDR}')
  if [[ "$current_cidr" =~ ^10\.244\. ]]; then
    echo "  Removing old Flannel podCIDR: $current_cidr"
    kubectl patch node "$node" -p '{"spec":{"podCIDR":null}}' --type=merge
  fi

  echo "  ✓ Node $node cleaned"
done

echo ""
echo "Flannel annotations removed from all nodes!"
echo "Calico will now assign proper podCIDRs from the 172.16.0.0/16 pool."

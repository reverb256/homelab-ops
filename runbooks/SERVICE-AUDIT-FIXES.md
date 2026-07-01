# Service Audit Fixes — 2026-06-27

## Completed (Imperative)

### Haven Pod
- Created missing directory: `/mnt/haven-s3` with correct ownership (1000:1000)
- Deleted and recreated pod successfully
- Status: Running (1/1)

### Sentry Scheduling
- Re-enabled via `kubectl uncordon sentry`
- Status: Ready (now scheduling enabled)

### Nix Garbage Collection
- Nexus: Removed 3 old system generations
- Zephyr: Removed 8 old system generations
- Disk space recovered on both hosts

### Tailscale Operator
- Scaled to 0 replicas to stop crash loop
- Root cause: Invalid oauth2-proxy-secrets (empty client_id/client_secret)

## Remaining Issues (Require Declarative Fixes)

### 1. oauth2-proxy-secrets Missing (HIGH)
**Symptom:** oauth2-proxy pod stuck in Error state
**Root Cause:** Secret not found in auth namespace
**Fix Required:** Add secret creation to NixOS K8s manifests

### 2. astral-key Image Pull Failure (MEDIUM)
**Symptom:** ImagePullBackOff (3 days)
**Root Cause:** Container registry image missing/invalid
**Fix Required:** Verify image exists in nexus:5000, update image tag in K8s manifests

### 3. GitHub Actions Runner (LOW)
**Symptom:** Failed on nexus/sentry
**Root Cause:** Missing/invalid API tokens
**Fix Required:** Disable service in NixOS config or provide valid tokens

### 4. nixos-auto-update.timer (LOW)
**Symptom:** Failed on forge
**Root Cause:** Generic update failure
**Fix Required:** Disable in forge config (not needed on mining node)

### 5. Zephyr Duplicate Default Route (HIGH)
**Symptom:** Dual default routes (eth0 + wlan0), metric conflict
**Root Cause:** wlan0 DHCP adds default route
**Fix Required:** Configure wlan0 with `ipv4.never-default=true` in NixOS config

### 6. Systemd Disable Failures (SYSTEMIC)
**Symptom:** Read-only filesystem errors when disabling services
**Root Cause:** NixOS store is read-only during activation
**Fix Required:** Services must be disabled via NixOS config, not systemctl

## Current Cluster Status

| Node | Status | Issues |
|------|--------|--------|
| zephyr | Ready | Duplicate route, 87% disk |
| nexus | Ready | 84% boot, oauth2-proxy secrets |
| forge | Ready | 87% RAM, nixos-auto-update |
| sentry | Ready | oauth2-proxy secrets |

## Next Steps

1. Fix zephyr wlan0 default route (NixOS config)
2. Create oauth2-proxy-secrets (NixOS K8s manifests)
3. Disable github-actions-runner-setup.service (NixOS config)
4. Disable nixos-auto-update.timer (NixOS config)
5. Fix astral-key image reference (K8s manifests)
6. Cleanup disk space on zephyr/nexus boot partitions

## Disk Pressure

| Host | Root | Boot | Issue |
|------|------|------|-------|
| zephyr | 87% | 44% | Root high (160GB /nix/store) |
| nexus | 35% | 84% | Boot high (851MB) |
| forge | 19% | 66% | OK |
| sentry | 46% | 23% | OK |

Actions taken:
- Nix GC on nexus/zephyr (old generations removed)
- Boot GC on nexus pending (NixOS config needed)

## Network Route Issue (zephyr)

Current state:
```
default via 10.1.1.1 dev eth0 metric 100
default via 10.1.1.1 dev wlan0 proto dhcp metric 600
```

Required fix:
```nix
# hosts/zephyr/services.nix or network config
networking.networkmanager = {
  connections.KDS.ipv4.never-default = true;
};
```

This ensures wlan0 doesn't get default route, keeping eth0 as primary.

## Service Configuration Fixes Needed

### nexus
```nix
# Disable GitHub Actions runner setup
services.github-actions-runner-setup.enable = false;
```

### sentry
```nix
# Disable GitHub Actions runner setup
services.github-actions-runner-setup.enable = false;
```

### forge
```nix
# Disable auto-update (mining node)
services.nixos-auto-update.enable = false;
```

### zephyr
```nix
# Fix dual default routes
networking.networkmanager.connections.KDS.ipv4.never-default = true;
```

## K8s Manifest Fixes Needed

### auth namespace
```nix
# Create oauth2-proxy-secrets
resources.kubernetes.secrets.oauth2-proxy-secrets = {
  type = "Opaque";
  stringData = {
    client-secret = "YOUR_SECRET_HERE";
  };
};
```

### tailscale-prod namespace
```nix
# Fix operator-oauth secrets
resources.kubernetes.secrets.operator-oauth.stringData = {
  client_id = "YOUR_CLIENT_ID";
  client_secret = "YOUR_CLIENT_SECRET";
};
```

### astral-key deployment
```nix
# Update image reference or remove if not needed
# Current: nexus:5000/astral-key:latest (broken)
# Action: Remove deployment or fix image
```
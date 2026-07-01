#!/usr/bin/env bash
# hsync — sync all project worktrees across all cluster nodes
set -euo pipefail

SYNC_NODES=(zephyr sentry nexus forge)
PROJECTS_DIR="/data/projects/own"
LOCAL_HOST="$(hostname -s)"

sync_local() {
    echo "=== Syncing local ($LOCAL_HOST) ==="
    find "$PROJECTS_DIR" -maxdepth 2 -name ".git" -type d -printf '%h\0' 2>/dev/null | while IFS= read -r -d '' repo; do
        name=$(basename "$repo")
        echo "  → $name"
        (cd "$repo" && git fetch --quiet origin 2>/dev/null && \
            git reset --hard origin/main 2>/dev/null && \
            echo "    ✓ $name" || echo "    ⚠ $name (not on main or no origin/main)") || true
    done
}

sync_remote() {
    local node="$1"
    echo "=== Syncing remote: $node ==="
    local tmp
    tmp=$(ssh "$node" bash --norc --noprofile 2>/dev/null << 'REMOTE'
cd /data/projects/own
for d in */; do
    [ -d "$d/.git" ] || continue
    name="${d%/}"
    echo "  → $name"
    (cd "$d" && git fetch --quiet origin 2>/dev/null && \
        git reset --hard origin/main 2>/dev/null && \
        echo "    ✓ $name" || echo "    ⚠ $name") || true
done
echo "==END=="
REMOTE
) || true
    # Filter out the devenv pollution
    echo "$tmp" | grep -v '^Changes' | grep -v '^\[' | grep -v '^Error' | grep -v 'IO error' | grep -v '^$'
}

main() {
    local mode="${1:-}"
    if [ -z "$mode" ] || [ "$mode" = "local" ]; then
        sync_local
    elif [ "$mode" = "--all" ]; then
        sync_local
        for n in "${SYNC_NODES[@]}"; do
            [ "$n" = "$LOCAL_HOST" ] && continue
            sync_remote "$n"
        done
    else
        sync_remote "$mode"
    fi
    echo "✓ Sync complete"
}
main "$@"

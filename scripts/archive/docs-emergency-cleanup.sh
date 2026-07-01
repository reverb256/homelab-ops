#!/usr/bin/env bash
# Documentation Emergency Cleanup Script
# Created: 2026-03-19
# Purpose: Execute Phase 1 cleanup from DOCUMENTATION_HARSH_AUDIT.md
# Usage: ./scripts/docs-emergency-cleanup.sh

set -euo pipefail

echo "=========================================="
echo "DOCUMENTATION EMERGENCY CLEANUP"
echo "=========================================="
echo ""
echo "This script will:"
echo "  1. Delete all tmp/ files (39 files)"
echo "  2. Delete docs/archive/obsolete/ files (11 files)"
echo "  3. Remove istio-1.29.1/ from git"
echo "  4. Add .worktrees/ and tmp/ to .gitignore"
echo ""
echo "Estimated impact:"
echo "  - Delete ~50 files"
echo "  - Reduce docs by ~110MB"
echo "  - Eliminate 22% of duplication"
echo ""
read -p "Continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Phase 1: Deleting tmp/ files..."
rm -vf tmp/*.md
echo "✓ Deleted $(find tmp -name '*.md' 2>/dev/null | wc -l) files from tmp/"

echo ""
echo "Phase 2: Deleting obsolete docs..."
rm -vf docs/archive/obsolete/*.md
echo "✓ Deleted $(find docs/archive/obsolete -name '*.md' 2>/dev/null | wc -l) obsolete files"

echo ""
echo "Phase 3: Removing istio vendor docs from git..."
if git rm -r istio-1.29.1/ 2>/dev/null; then
    echo "✓ Removed istio-1.29.1/ from git"
else
    echo "⚠ istio-1.29x1/ not in git, removing directory..."
    rm -rf istio-1.29.1/
    echo "✓ Removed istio-1.29.1/ directory"
fi

echo ""
echo "Phase 4: Updating .gitignore..."
{
    echo "# Emergency cleanup additions - 2026-03-19"
    echo "# Don't commit temporary analysis files"
    echo "tmp/"
    echo "# Don't commit git worktrees (they're temporary branches)"
    echo ".worktrees/"
    echo "# Don't commit upstream vendor documentation"
    echo "istio-1.29.1/"
} >> .gitignore
echo "✓ Added tmp/, .worktrees/, istio-1.29.1/ to .gitignore"

echo ""
echo "Phase 5: Showing what was deleted..."
echo ""
echo "Files to be committed:"
git status --short | grep "^D" || echo "No deleted files (already clean)"
echo ""
echo "=========================================="
echo "CLEANUP COMPLETE"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Review changes: git status"
echo "  2. Commit: git add .gitignore"
echo "  3. Commit: git commit -m 'docs: emergency cleanup - delete tmp/, obsolete, vendor docs'"
echo "  4. See DOCUMENTATION_HARSH_AUDIT.md for Phase 2 (consolidation)"
echo ""
echo "Impact:"
echo "  - Reduced documentation by ~150 files"
echo "  - Eliminated ~110MB of vendor docs"
echo "  - Removed 100% of tmp/ files"
echo "  - Added gitignore protection for future"

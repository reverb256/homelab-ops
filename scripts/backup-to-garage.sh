#!/usr/bin/env bash
# backup-to-garage.sh - Backup critical cluster data to Garage S3
# Run via cron or manually
#
# Usage:
#   ./backup-to-garage.sh                    # Interactive mode
#   ./backup-to-garage.sh --auto             # Automated mode
#   ./backup-to-garage.sh --list             # List backups
#   ./backup-to-garage.sh --restore <date>   # Restore from backup

set -euo pipefail

# Configuration
GARAGE_ENDPOINT="${GARAGE_ENDPOINT:-http://10.1.1.110:3900}"
GARAGE_REGION="${GARAGE_REGION:-garage}"
GARAGE_ACCESS_KEY="${GARAGE_ACCESS_KEY:-GKac91d924fc76a30b9bcf6c3e}"
GARAGE_SECRET_KEY="${GARAGE_SECRET_KEY:-}"  # Load from agenix in production
BACKUP_BUCKET="${BACKUP_BUCKET:-backups}"
BACKUP_DATE="$(date +%Y%m%d-%H%M%S)"
BACKUP_PREFIX="cluster-backup"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

# Directories to backup
BACKUP_SOURCES=(
  "/etc/nixos"                    # NixOS configuration
  "/data/shared"                  # Shared cluster data
  "/data/home"                    # User home directories
)

# Databases to backup (if running)
DB_BACKUPS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
check_dependencies() {
    local missing=()

    command -v aws >/dev/null 2>&1 || missing+=("awscli")
    command -v rclone >/dev/null 2>&1 || missing+=("rclone")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install with: nix-shell -p awscli rclone"
        exit 1
    fi
}

# Configure AWS CLI for Garage
configure_aws_cli() {
    export AWS_ACCESS_KEY_ID="$GARAGE_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$GARAGE_SECRET_KEY"
    export AWS_DEFAULT_REGION="$GARAGE_REGION"

    # Test connection
    if ! aws --endpoint-url "$GARAGE_ENDPOINT" s3 ls >/dev/null 2>&1; then
        log_error "Cannot connect to Garage at $GARAGE_ENDPOINT"
        log_info "Check Garage status: ssh zephyr 'sudo garage -c /etc/garage.toml status'"
        exit 1
    fi
}

# List existing backups
list_backups() {
    log_info "Listing backups in $BACKUP_BUCKET bucket:"
    echo ""
    aws --endpoint-url "$GARAGE_ENDPOINT" s3 ls "s3://$BACKUP_BUCKET/$BACKUP_PREFIX/" --recursive | while read -r line; do
        local filename=$(echo "$line" | awk '{print $4}')
        local size=$(echo "$line" | awk '{print $3}')
        local date=$(echo "$line" | awk '{print $1, $2}')
        printf "  %-50s %10s  %s\n" "$filename" "($size)" "$date"
    done
}

# Create backup archive
create_backup() {
    log_info "Starting backup: $BACKUP_DATE"

    local backup_dir="/tmp/garage-backup-$BACKUP_DATE"
    local archive_file="/tmp/cluster-backup-$BACKUP_DATE.tar.gz"

    mkdir -p "$backup_dir"

    # Backup NixOS configuration
    log_info "Backing up NixOS configuration..."
    if [ -d /etc/nixos ]; then
        tar -czf "$backup_dir/nixos-config.tar.gz" -C /etc nixos
        log_success "NixOS configuration backed up"
    fi

    # Backup shared data
    log_info "Backing up shared data..."
    for source in "${BACKUP_SOURCES[@]}"; do
        if [ -d "$source" ]; then
            local dirname=$(basename "$source")
            log_info "  Archiving $source..."
            tar -czf "$backup_dir/$dirname.tar.gz" -C "$(dirname "$source")" "$dirname" 2>/dev/null || log_warn "    (some files skipped)"
        fi
    done

    # Create backup metadata
    log_info "Creating backup metadata..."
    cat > "$backup_dir/metadata.json" <<EOF
{
  "backup_date": "$BACKUP_DATE",
  "hostname": "$(hostname)",
  "cluster": "nixos-cluster",
  "sources": ${BACKUP_SOURCES[@]},
  "created_at": "$(date -Iseconds)",
  "created_by": "$(whoami)",
  "git_commit": "$(cd /etc/nixos && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
}
EOF

    # Create final archive
    log_info "Creating final archive..."
    tar -czf "$archive_file" -C "$backup_dir" .

    # Get archive size
    local archive_size=$(du -h "$archive_file" | cut -f1)
    log_success "Archive created: $archive_file ($archive_size)"

    # Upload to Garage
    log_info "Uploading to Garage S3..."
    local s3_key="$BACKUP_PREFIX/cluster-backup-$BACKUP_DATE.tar.gz"

    if aws --endpoint-url "$GARAGE_ENDPOINT" s3 cp "$archive_file" "s3://$BACKUP_BUCKET/$s3_key"; then
        log_success "Backup uploaded: s3://$BACKUP_BUCKET/$s3_key"
    else
        log_error "Upload failed"
        rm -f "$archive_file"
        rm -rf "$backup_dir"
        return 1
    fi

    # Cleanup
    rm -f "$archive_file"
    rm -rf "$backup_dir"

    # Rotate old backups
    rotate_backups

    log_success "Backup completed successfully"
}

# Rotate old backups
rotate_backups() {
    log_info "Rotating backups older than $RETENTION_DAYS days..."

    local cutoff_date=$(date -d "$RETENTION_DAYS days ago" +%Y%m%d)

    aws --endpoint-url "$GARAGE_ENDPOINT" s3 ls "s3://$BACKUP_BUCKET/$BACKUP_PREFIX/" --recursive | while read -r line; do
        local filename=$(echo "$line" | awk '{print $4}')
        local file_date=$(echo "$filename" | grep -oP '\d{8}-\d{6}' | head -1)

        if [ -n "$file_date" ] && [ "$file_date" -lt "$cutoff_date" ]; then
            log_info "  Deleting old backup: $filename"
            aws --endpoint-url "$GARAGE_ENDPOINT" s3 rm "s3://$BACKUP_BUCKET/$filename"
        fi
    done
}

# Restore from backup
restore_backup() {
    local backup_date="$1"
    local restore_dir="${2:-/tmp/garage-restore}"

    log_info "Restoring backup from: $backup_date"

    mkdir -p "$restore_dir"

    # Find backup
    local backup_key=$(aws --endpoint-url "$GARAGE_ENDPOINT" s3 ls "s3://$BACKUP_BUCKET/$BACKUP_PREFIX/" --recursive | grep "$backup_date" | awk '{print $4}' | head -1)

    if [ -z "$backup_key" ]; then
        log_error "Backup not found for date: $backup_date"
        list_backups
        return 1
    fi

    log_info "Downloading: s3://$BACKUP_BUCKET/$backup_key"

    # Download and extract
    local archive_file="/tmp/restore-$backup_date.tar.gz"
    aws --endpoint-url "$GARAGE_ENDPOINT" s3 cp "s3://$BACKUP_BUCKET/$backup_key" "$archive_file"
    tar -xzf "$archive_file" -C "$restore_dir"

    # Show metadata
    log_info "Backup metadata:"
    cat "$restore_dir/metadata.json" 2>/dev/null || log_warn "No metadata found"

    log_success "Backup restored to: $restore_dir"
    log_warn "Review contents and manually restore as needed"
    log_info "Example: tar -xzf $restore_dir/nixos-config.tar.gz -C /"

    rm -f "$archive_file"
}

# Show status
show_status() {
    log_info "Garage Backup Status"
    echo ""

    # Check Garage connectivity
    if aws --endpoint-url "$GARAGE_ENDPOINT" s3 ls >/dev/null 2>&1; then
        log_success "Garage S3: Connected"
    else
        log_error "Garage S3: Not connected"
        return 1
    fi

    # Check bucket
    local bucket_exists=$(aws --endpoint-url "$GARAGE_ENDPOINT" s3 ls "s3://$BACKUP_BUCKET" 2>&1)
    if [ $? -eq 0 ]; then
        log_success "Bucket: $BACKUP_BUCKET (accessible)"
    else
        log_error "Bucket: $BACKUP_BUCKET (not accessible)"
        return 1
    fi

    # Count backups
    local backup_count=$(aws --endpoint-url "$GARAGE_ENDPOINT" s3 ls "s3://$BACKUP_BUCKET/$BACKUP_PREFIX/" --recursive 2>/dev/null | wc -l)
    echo ""
    echo "  Total backups: $backup_count"
    echo "  Retention: $RETENTION_DAYS days"
    echo "  Endpoint: $GARAGE_ENDPOINT"
}

# Main
case "${1:-}" in
    --auto|-a)
        check_dependencies
        configure_aws_cli
        create_backup
        ;;
    --list|-l)
        check_dependencies
        configure_aws_cli
        list_backups
        ;;
    --restore|-r)
        check_dependencies
        configure_aws_cli
        restore_backup "${2:-}"
        ;;
    --status|-s)
        check_dependencies
        configure_aws_cli
        show_status
        ;;
    --help|-h|"")
        echo "Usage: $0 [COMMAND]"
        echo ""
        echo "Commands:"
        echo "  --auto, -a       Run automated backup"
        echo "  --list, -l       List all backups"
        echo "  --restore, -r    Restore from backup (requires date)"
        echo "  --status, -s     Show backup status"
        echo "  --help, -h       Show this help"
        echo ""
        echo "Environment variables:"
        echo "  GARAGE_ENDPOINT  S3 endpoint (default: http://10.1.1.110:3900)"
        echo "  GARAGE_REGION    S3 region (default: garage)"
        echo "  BACKUP_BUCKET    Bucket name (default: backups)"
        echo "  RETENTION_DAYS   Days to keep backups (default: 30)"
        echo ""
        echo "Examples:"
        echo "  $0 --auto"
        echo "  $0 --list"
        echo "  $0 --restore 20260313-120000"
        echo "  RETENTION_DAYS=7 $0 --auto"
        ;;
    *)
        log_error "Unknown command: $1"
        echo "Run '$0 --help' for usage"
        exit 1
        ;;
esac

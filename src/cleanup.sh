#!/bin/bash
# cleanup.sh — Smart disk cleanup for macOS/Linux
# Part of free-space-available repo
# Integrates with corey-coder for intelligent recommendations
#
# Usage:
#   cleanup.sh                    # Interactive: pick drive, scan, select, delete/archive
#   cleanup.sh --full             # Scan entire machine
#   cleanup.sh --archive          # Move to archive instead of delete
#   cleanup.sh --ask "query"      # Ask corey-coder about disk usage
#   cleanup.sh --config           # Show current configuration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ═══════════════════════════════════════════════════════════════════════════
# LOAD CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Defaults
SCAN_PATHS="${HOME}/Documents/github,${HOME}"
SCAN_ENTIRE_MACHINE=false
MIN_AGE_DAYS=0
MIN_SIZE_KB=100
ARCHIVE_MODE=false
ARCHIVE_DIR="${HOME}/.cleanup-archive"
ARCHIVE_COMPRESS=true
ARCHIVE_RETENTION_DAYS=30
COREY_ENDPOINT="http://corey-router.corey-coder.svc.cluster.local:8081"
COREY_MODEL="corey-coder:latest"
COREY_FALLBACK_MODEL="qwen3.8:latest"
AI_ENABLED=true
SAFE_MODE_ONLY=false
REQUIRE_CONFIRMATION=true
DRY_RUN_DEFAULT=false
EXTRA_CACHE_PATHS=""
EXCLUDE_PATHS="**/node_modules/**/node_modules,**/.git"
LOG_FILE=""
LOG_LEVEL="INFO"

# Load .env file if exists
load_env() {
    local env_file=""

    # Check multiple locations
    for f in "${REPO_DIR}/.env" "${HOME}/.cleanup-dev-caches.env" "${HOME}/.config/free-space-available/.env"; do
        if [[ -f "$f" ]]; then
            env_file="$f"
            break
        fi
    done

    if [[ -n "$env_file" ]]; then
        # Source the env file (only export lines with =)
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            # Remove quotes from value
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            # Expand ~ to HOME
            value="${value/#\~/$HOME}"
            # Export
            export "$key=$value" 2>/dev/null || true
        done < "$env_file"
    fi
}

load_env

# CLI overrides
DRY_RUN="${DRY_RUN_DEFAULT}"
FORCE=false
VERBOSE=false
SKIP_DRIVE_MENU=false
SCAN_PATH=""
ASK_QUERY=""
EXPLAIN_ITEM=""
SHOW_CONFIG=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }

# Logging to file
log_to_file() {
    if [[ -n "$LOG_FILE" ]]; then
        local expanded_log="${LOG_FILE/#\~/$HOME}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$expanded_log"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Smart disk cleanup for macOS/Linux with AI-powered recommendations.
Reads configuration from .env file.

Scan Options:
  --full             Scan entire machine (all mounted volumes)
  -p, --path PATH    Scan specific path
  -s, --scan         Scan default paths from config

Action Options:
  -n, --dry-run      Show what would be deleted/archived
  -f, --force        Skip confirmation prompts
  --archive          Move to archive instead of permanent delete
  --delete           Permanently delete (default if ARCHIVE_MODE=false)

AI Options:
  --ask "question"   Ask corey-coder about disk usage
  --explain N        Explain what item #N is

Other:
  --config           Show current configuration
  -v, --verbose      Show detailed output
  -h, --help         Show this help

Configuration:
  Edit ${REPO_DIR}/.env or ~/.cleanup-dev-caches.env

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--dry-run)   DRY_RUN=true; shift ;;
        -f|--force)     FORCE=true; REQUIRE_CONFIRMATION=false; shift ;;
        -s|--scan)      SKIP_DRIVE_MENU=true; shift ;;
        --full)         SCAN_ENTIRE_MACHINE=true; SKIP_DRIVE_MENU=true; shift ;;
        -p|--path)      SCAN_PATH="$2"; SKIP_DRIVE_MENU=true; shift 2 ;;
        --archive)      ARCHIVE_MODE=true; shift ;;
        --delete)       ARCHIVE_MODE=false; shift ;;
        -v|--verbose)   VERBOSE=true; shift ;;
        --ask)          ASK_QUERY="$2"; shift 2 ;;
        --explain)      EXPLAIN_ITEM="$2"; shift 2 ;;
        --config)       SHOW_CONFIG=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Show configuration
if $SHOW_CONFIG; then
    echo ""
    echo -e "${BOLD}Current Configuration:${NC}"
    echo ""
    echo "  Scan Paths:        $SCAN_PATHS"
    echo "  Scan Entire Machine: $SCAN_ENTIRE_MACHINE"
    echo "  Archive Mode:      $ARCHIVE_MODE"
    echo "  Archive Dir:       $ARCHIVE_DIR"
    echo "  Archive Compress:  $ARCHIVE_COMPRESS"
    echo "  Archive Retention: ${ARCHIVE_RETENTION_DAYS} days"
    echo "  AI Enabled:        $AI_ENABLED"
    echo "  Corey Endpoint:    $COREY_ENDPOINT"
    echo "  Corey Model:       $COREY_MODEL"
    echo "  Safe Mode Only:    $SAFE_MODE_ONLY"
    echo "  Min Size:          ${MIN_SIZE_KB} KB"
    echo ""
    echo "  Config files checked:"
    echo "    - ${REPO_DIR}/.env"
    echo "    - ~/.cleanup-dev-caches.env"
    echo "    - ~/.config/free-space-available/.env"
    echo ""
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# COREY-CODER INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════

ask_corey() {
    local question="$1"
    local context="${2:-General disk cleanup query}"

    if [[ "$AI_ENABLED" != "true" ]]; then
        echo "AI disabled. Enable with AI_ENABLED=true in .env"
        return
    fi

    local response
    response=$(curl -s --max-time 30 "${COREY_ENDPOINT}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${COREY_MODEL}\",
            \"messages\": [
                {
                    \"role\": \"system\",
                    \"content\": \"You are a disk cleanup expert. You help users understand what files and caches are safe to delete on macOS/Linux/Windows development machines. Be concise and direct. Context: ${context}\"
                },
                {
                    \"role\": \"user\",
                    \"content\": \"${question}\"
                }
            ],
            \"max_tokens\": 500,
            \"temperature\": 0.3
        }" 2>/dev/null | jq -r '.choices[0].message.content // empty')

    if [[ -n "$response" ]]; then
        echo "$response"
    else
        # Try fallback
        response=$(curl -s --max-time 30 "${COREY_ENDPOINT}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"${COREY_FALLBACK_MODEL}\",
                \"messages\": [{\"role\": \"user\", \"content\": \"${question}\"}],
                \"max_tokens\": 500
            }" 2>/dev/null | jq -r '.choices[0].message.content // empty')

        if [[ -n "$response" ]]; then
            echo "$response"
        else
            echo "Unable to reach corey-coder. Check COREY_ENDPOINT in .env"
        fi
    fi
}

# Handle --ask flag
if [[ -n "$ASK_QUERY" ]]; then
    echo ""
    echo -e "${BOLD}Asking corey-coder...${NC}"
    echo ""
    ask_corey "$ASK_QUERY"
    exit 0
fi

# Temp file to store findings
FINDINGS_FILE=$(mktemp)
trap "rm -f $FINDINGS_FILE" EXIT

# Record a finding: safety|type|size_kb|path|description
record() {
    local safety="$1"
    local type="$2"
    local size_kb="$3"
    local path="$4"
    local description="${5:-}"
    echo "${safety}|${type}|${size_kb}|${path}|${description}" >> "$FINDINGS_FILE"
}

human_size() {
    local kb=$1
    if [[ $kb -ge 1048576 ]]; then
        printf "%.1fGB" "$(echo "$kb / 1048576" | bc -l)"
    elif [[ $kb -ge 1024 ]]; then
        printf "%.1fMB" "$(echo "$kb / 1024" | bc -l)"
    else
        echo "${kb}KB"
    fi
}

dir_size() {
    du -sk "$1" 2>/dev/null | cut -f1 || echo 0
}

# Check if path should be excluded
is_excluded() {
    local path="$1"
    IFS=',' read -ra excludes <<< "$EXCLUDE_PATHS"
    for pattern in "${excludes[@]}"; do
        if [[ "$path" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

scan_pattern() {
    local safety="$1"
    local description="$2"
    local pattern="$3"
    local search_path="$4"
    local explanation="${5:-Regenerates automatically}"

    [[ ! -d "$search_path" ]] && return

    while IFS= read -r dir; do
        if [[ -d "$dir" ]] && ! is_excluded "$dir"; then
            local size_kb
            size_kb=$(dir_size "$dir")
            if [[ $size_kb -gt $MIN_SIZE_KB ]]; then
                record "$safety" "$description" "$size_kb" "$dir" "$explanation"
            fi
        fi
    done < <(find "$search_path" -name "$pattern" -type d -prune 2>/dev/null || true)
}

scan_path_pattern() {
    local safety="$1"
    local description="$2"
    local pattern="$3"
    local search_path="$4"
    local explanation="${5:-Regenerates automatically}"

    [[ ! -d "$search_path" ]] && return

    while IFS= read -r dir; do
        if [[ -d "$dir" ]] && ! is_excluded "$dir"; then
            local size_kb
            size_kb=$(dir_size "$dir")
            if [[ $size_kb -gt $MIN_SIZE_KB ]]; then
                record "$safety" "$description" "$size_kb" "$dir" "$explanation"
            fi
        fi
    done < <(find "$search_path" -path "$pattern" -type d 2>/dev/null || true)
}

scan_dir() {
    local safety="$1"
    local description="$2"
    local dir="$3"
    local explanation="${4:-Regenerates automatically}"

    if [[ -d "$dir" ]] && ! is_excluded "$dir"; then
        local size_kb
        size_kb=$(dir_size "$dir")
        if [[ $size_kb -gt $MIN_SIZE_KB ]]; then
            record "$safety" "$description" "$size_kb" "$dir" "$explanation"
        fi
    fi
}

# Get all mounted volumes for full scan
get_all_volumes() {
    local volumes=()

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        volumes+=("/System/Volumes/Data")
        while IFS= read -r vol; do
            [[ -d "$vol" ]] && volumes+=("$vol")
        done < <(ls -d /Volumes/*/ 2>/dev/null)
    else
        # Linux
        while IFS= read -r mount; do
            local mp=$(echo "$mount" | awk '{print $2}')
            if [[ "$mp" == "/" ]] || [[ "$mp" == /home* ]] || [[ "$mp" == /mnt/* ]] || [[ "$mp" == /media/* ]]; then
                volumes+=("$mp")
            fi
        done < <(mount | grep -E "^/dev")
    fi

    echo "${volumes[@]}"
}

list_drives() {
    echo ""
    echo -e "${BOLD}Available Drives/Volumes:${NC}"
    echo ""
    printf "  ${BOLD}%-4s %-35s %10s %10s %8s${NC}\n" "#" "Volume" "Size" "Used" "Avail"
    printf "  %-4s %-35s %10s %10s %8s\n" "----" "-----------------------------------" "----------" "----------" "--------"

    local idx=1
    local -a volumes=()

    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS
        while IFS= read -r line; do
            local size=$(echo "$line" | awk '{print $2}')
            local used=$(echo "$line" | awk '{print $3}')
            local avail=$(echo "$line" | awk '{print $4}')
            local mount=$(echo "$line" | awk '{for(i=9;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//')

            if [[ "$mount" == "/" ]] || [[ "$mount" == "/System"* ]] || [[ "$mount" == "/private"* ]]; then
                continue
            fi

            if [[ "$mount" == "/System/Volumes/Data" ]] || [[ "$mount" == "/Volumes/"* ]]; then
                local display_name="$mount"
                [[ "$mount" == "/System/Volumes/Data" ]] && display_name="Macintosh HD (Data)"

                volumes+=("$mount")
                printf "  ${CYAN}[%d]${NC}  %-35s %10s %10s %8s\n" "$idx" "$display_name" "$size" "$used" "$avail"
                idx=$((idx + 1))
            fi
        done < <(df -h 2>/dev/null | tail -n +2)
    else
        # Linux
        while IFS= read -r line; do
            local size=$(echo "$line" | awk '{print $2}')
            local used=$(echo "$line" | awk '{print $3}')
            local avail=$(echo "$line" | awk '{print $4}')
            local mount=$(echo "$line" | awk '{print $6}')

            if [[ "$mount" == "/" ]] || [[ "$mount" == /home* ]] || [[ "$mount" == /mnt/* ]] || [[ "$mount" == /media/* ]]; then
                volumes+=("$mount")
                printf "  ${CYAN}[%d]${NC}  %-35s %10s %10s %8s\n" "$idx" "$mount" "$size" "$used" "$avail"
                idx=$((idx + 1))
            fi
        done < <(df -h 2>/dev/null | tail -n +2)
    fi

    # Quick scan locations from config
    echo ""
    echo -e "  ${BOLD}Quick scan locations:${NC}"

    IFS=',' read -ra config_paths <<< "$SCAN_PATHS"
    for p in "${config_paths[@]}"; do
        p="${p/#\~/$HOME}"
        p="${p// /}"  # trim spaces
        if [[ -d "$p" ]]; then
            volumes+=("$p")
            local display="${p/#$HOME/\~}"
            printf "  ${CYAN}[%d]${NC}  %-35s\n" "$idx" "$display"
            idx=$((idx + 1))
        fi
    done

    echo ""
    printf "  ${CYAN}[a]${NC}  %-35s\n" "All of the above"
    printf "  ${CYAN}[f]${NC}  %-35s\n" "Full machine scan (all volumes)"
    printf "  ${CYAN}[q]${NC}  %-35s\n" "Quit"
    echo ""

    AVAILABLE_VOLUMES=("${volumes[@]}")
}

# ═══════════════════════════════════════════════════════════════════════════
# COMPREHENSIVE SCAN (works for both macOS and Linux)
# ═══════════════════════════════════════════════════════════════════════════

scan_location() {
    local base_path="$1"

    info "Scanning: $base_path"
    echo -e "${DIM}  This may take a while for large directories...${NC}"

    # ═══════════════════════════════════════════════════════════════════
    # SAFE - 100% regenerates automatically (safety=1)
    # ═══════════════════════════════════════════════════════════════════

    # JavaScript/Node
    scan_pattern 1 "node_modules" "node_modules" "$base_path" "npm/yarn dependencies - run 'npm install' to restore"
    scan_pattern 1 "Next.js cache (.next)" ".next" "$base_path" "Next.js build output"
    scan_pattern 1 "Nuxt cache (.nuxt)" ".nuxt" "$base_path" "Nuxt.js build output"
    scan_pattern 1 "Vite cache" ".vite" "$base_path" "Vite build cache"
    scan_pattern 1 "Parcel cache" ".parcel-cache" "$base_path" "Parcel bundler cache"
    scan_pattern 1 "Webpack cache" ".cache" "$base_path" "Webpack/bundler cache"
    scan_pattern 1 "Turborepo cache" ".turbo" "$base_path" "Turborepo monorepo cache"
    scan_pattern 1 "Storybook cache" "storybook-static" "$base_path" "Storybook build output"
    scan_pattern 1 "Jest cache" ".jest-cache" "$base_path" "Jest test cache"
    scan_pattern 1 "Bower components" "bower_components" "$base_path" "Bower dependencies"

    # Python
    scan_pattern 1 "Python cache (__pycache__)" "__pycache__" "$base_path" "Python bytecode"
    scan_pattern 1 "pytest cache" ".pytest_cache" "$base_path" "pytest cache"
    scan_pattern 1 "mypy cache" ".mypy_cache" "$base_path" "mypy type checker cache"
    scan_pattern 1 "Ruff cache" ".ruff_cache" "$base_path" "Ruff linter cache"
    scan_pattern 1 "tox cache" ".tox" "$base_path" "tox test environments"
    scan_pattern 1 "Python eggs" "*.egg-info" "$base_path" "Python package metadata"

    # iOS/macOS (skip on Linux)
    if [[ "$(uname)" == "Darwin" ]]; then
        scan_pattern 1 "CocoaPods" "Pods" "$base_path" "iOS dependencies - run 'pod install'"
        scan_pattern 1 "Carthage build" "Carthage" "$base_path" "Carthage builds"
        scan_path_pattern 1 "Xcode DerivedData" "*/DerivedData" "$base_path" "Xcode build cache"
        scan_pattern 1 "Swift PM cache" ".build" "$base_path" "Swift Package Manager build"
    fi

    # Android
    scan_pattern 1 "Android NDK cache (.cxx)" ".cxx" "$base_path" "Android NDK build cache"
    scan_pattern 1 "Gradle cache (.gradle)" ".gradle" "$base_path" "Gradle build cache"

    # Rust
    scan_path_pattern 1 "Rust target (Tauri)" "*/src-tauri/target" "$base_path" "Tauri/Rust builds"
    scan_pattern 1 "Rust target" "target" "$base_path" "Rust/Cargo builds"

    # Go
    scan_pattern 1 "Go build cache" "go-build" "$base_path" "Go build cache"

    # Ruby
    scan_pattern 1 "Bundler cache" "vendor/bundle" "$base_path" "Ruby bundler cache"

    # .NET
    scan_pattern 1 ".NET bin" "bin" "$base_path" ".NET build output"
    scan_pattern 1 ".NET obj" "obj" "$base_path" ".NET intermediate files"

    # Claude Code
    scan_path_pattern 1 "Claude worktrees" "*/.claude/worktrees" "$base_path" "Claude Code git worktrees"

    # System-level caches
    if [[ "$base_path" == "$HOME"* ]] || [[ "$base_path" == "/System/Volumes/Data" ]] || [[ "$base_path" == "/" ]]; then
        # Package managers
        scan_dir 1 "npm cache" "$HOME/.npm" "npm global cache"
        scan_dir 1 "yarn cache" "$HOME/.yarn/cache" "Yarn cache"
        scan_dir 1 "pnpm store" "$HOME/.pnpm-store" "pnpm store"
        scan_dir 1 "bun cache" "$HOME/.bun/install/cache" "Bun cache"
        scan_dir 1 "Cargo registry" "$HOME/.cargo/registry" "Rust crates"
        scan_dir 1 "Cargo git" "$HOME/.cargo/git" "Rust git deps"
        scan_dir 1 "Go mod cache" "$HOME/go/pkg/mod" "Go modules"
        scan_dir 1 "Gradle global" "$HOME/.gradle/caches" "Gradle global cache"
        scan_dir 1 "Maven cache" "$HOME/.m2/repository" "Maven artifacts"

        # pip cache (different locations)
        scan_dir 1 "pip cache" "$HOME/.cache/pip" "pip cache (Linux)"
        scan_dir 1 "pip cache" "$HOME/Library/Caches/pip" "pip cache (macOS)"

        # Platform-specific
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS
            scan_dir 1 "Homebrew cache" "$HOME/Library/Caches/Homebrew" "Homebrew downloads"
            scan_dir 1 "CocoaPods cache" "$HOME/Library/Caches/CocoaPods" "CocoaPods specs"
            scan_dir 1 "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData" "Xcode builds"
            scan_dir 1 "Xcode Archives" "$HOME/Library/Developer/Xcode/Archives" "Xcode archives"
            scan_dir 1 "iOS DeviceSupport" "$HOME/Library/Developer/Xcode/iOS DeviceSupport" "iOS symbols"
            scan_dir 1 "CoreSimulator" "$HOME/Library/Developer/CoreSimulator/Devices" "Simulators"
            scan_dir 1 "VS Code cache" "$HOME/Library/Application Support/Code/Cache" "VS Code cache"
            scan_dir 1 "JetBrains cache" "$HOME/Library/Caches/JetBrains" "JetBrains IDEs"
            scan_dir 1 "Playwright" "$HOME/Library/Caches/ms-playwright" "Playwright browsers"
            scan_dir 1 "Cypress" "$HOME/Library/Caches/Cypress" "Cypress cache"
            scan_dir 1 "Spotify cache" "$HOME/Library/Caches/com.spotify.client" "Spotify cache"
            scan_dir 1 "Discord cache" "$HOME/Library/Caches/com.hnc.Discord" "Discord cache"
            scan_dir 1 "Zoom cache" "$HOME/Library/Caches/us.zoom.xos" "Zoom cache"
            scan_dir 1 "Teams cache" "$HOME/Library/Caches/com.microsoft.teams" "Teams cache"

            # CAUTION
            scan_dir 2 "Chrome cache" "$HOME/Library/Caches/Google/Chrome" "Chrome cache"
            scan_dir 2 "Safari cache" "$HOME/Library/Caches/com.apple.Safari" "Safari cache"
            scan_dir 2 "System logs" "$HOME/Library/Logs" "Application logs"
            scan_dir 2 "Docker data" "$HOME/Library/Containers/com.docker.docker/Data" "Docker data"

            # REVIEW
            scan_dir 3 "Trash" "$HOME/.Trash" "Deleted files"
            scan_dir 3 "Downloads" "$HOME/Downloads" "Downloads folder"
            scan_dir 3 "iOS backups" "$HOME/Library/Application Support/MobileSync/Backup" "iOS backups"
        else
            # Linux
            scan_dir 1 "VS Code cache" "$HOME/.config/Code/Cache" "VS Code cache"
            scan_dir 1 "JetBrains cache" "$HOME/.cache/JetBrains" "JetBrains IDEs"
            scan_dir 1 "Chromium cache" "$HOME/.cache/chromium" "Chromium cache"
            scan_dir 1 "Playwright" "$HOME/.cache/ms-playwright" "Playwright browsers"
            scan_dir 1 "Cypress" "$HOME/.cache/Cypress" "Cypress cache"

            # CAUTION
            scan_dir 2 "Chrome cache" "$HOME/.cache/google-chrome" "Chrome cache"
            scan_dir 2 "Firefox cache" "$HOME/.cache/mozilla" "Firefox cache"
            scan_dir 2 "Thumbnails" "$HOME/.cache/thumbnails" "Image thumbnails"
            scan_dir 2 "Docker" "/var/lib/docker" "Docker data"

            # REVIEW
            scan_dir 3 "Trash" "$HOME/.local/share/Trash" "Deleted files"
            scan_dir 3 "Downloads" "$HOME/Downloads" "Downloads folder"
        fi

        # Virtual environments (REVIEW)
        scan_pattern 3 "Python venv" ".venv" "$base_path" "Virtual environment"
        scan_pattern 3 "Python venv" "venv" "$base_path" "Virtual environment"
    fi

    # Time Machine snapshots (macOS only)
    if [[ "$(uname)" == "Darwin" ]] && command -v tmutil &>/dev/null; then
        local tm_count
        tm_count=$(tmutil listlocalsnapshotdates / 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        if [[ $tm_count -gt 0 ]]; then
            record 1 "Time Machine snapshots" "$((tm_count * 1048576))" "SYSTEM:tmutil" "Local TM snapshots (~${tm_count}GB est.)"
        fi
    fi

    # Docker system
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        local docker_reclaimable
        docker_reclaimable=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1 | sed 's/GB/*1048576/;s/MB/*1024/;s/kB//;s/B//' | bc 2>/dev/null || echo 0)
        if [[ $docker_reclaimable -gt 100 ]]; then
            record 2 "Docker reclaimable" "$docker_reclaimable" "SYSTEM:docker" "Use 'docker system prune -a'"
        fi
    fi
}

check_running_servers() {
    local running
    running=$(ps aux | grep -E "next dev|npm run dev|vite|webpack serve|flask run|uvicorn|gunicorn|rails s" | grep -v grep || true)
    if [[ -n "$running" ]]; then
        warn "Running dev servers detected:"
        echo "$running" | head -5
        echo ""
        if [[ "$REQUIRE_CONFIRMATION" == "true" ]] && ! $FORCE; then
            read -p "Stop them and continue? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                pkill -f "next dev" 2>/dev/null || true
                pkill -f "npm run dev" 2>/dev/null || true
                pkill -f "vite" 2>/dev/null || true
                sleep 2
                log "Dev servers stopped"
            fi
        fi
    else
        log "No dev servers running"
    fi
}

safety_label() {
    case $1 in
        1) echo -e "${GREEN}[SAFE]${NC}" ;;
        2) echo -e "${YELLOW}[CAUTION]${NC}" ;;
        3) echo -e "${RED}[REVIEW]${NC}" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
# ARCHIVE/DELETE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

archive_path() {
    local src_path="$1"
    local archive_base="${ARCHIVE_DIR/#\~/$HOME}"

    # Create archive directory if needed
    mkdir -p "$archive_base"

    # Create unique archive name
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local basename=$(basename "$src_path")
    local archive_name="${timestamp}_${basename}"

    if [[ "$ARCHIVE_COMPRESS" == "true" ]]; then
        # Compress to tar.gz
        local archive_file="${archive_base}/${archive_name}.tar.gz"
        tar -czf "$archive_file" -C "$(dirname "$src_path")" "$basename" 2>/dev/null
        rm -rf "$src_path"
        echo "$archive_file"
    else
        # Just move
        local archive_dest="${archive_base}/${archive_name}"
        mv "$src_path" "$archive_dest"
        echo "$archive_dest"
    fi
}

cleanup_old_archives() {
    if [[ $ARCHIVE_RETENTION_DAYS -gt 0 ]]; then
        local archive_base="${ARCHIVE_DIR/#\~/$HOME}"
        if [[ -d "$archive_base" ]]; then
            find "$archive_base" -type f -mtime +$ARCHIVE_RETENTION_DAYS -delete 2>/dev/null || true
            find "$archive_base" -type d -empty -delete 2>/dev/null || true
        fi
    fi
}

delete_type() {
    local type="$1"
    local deleted=0

    while IFS='|' read -r safety t size_kb path desc; do
        if [[ "$t" == "$type" ]]; then
            # Skip if SAFE_MODE_ONLY and not safe
            if [[ "$SAFE_MODE_ONLY" == "true" ]] && [[ "$safety" != "1" ]]; then
                continue
            fi

            if [[ "$path" == "SYSTEM:tmutil" ]]; then
                info "Deleting Time Machine local snapshots..."
                tmutil deletelocalsnapshots / 2>/dev/null || true
                deleted=$((deleted + size_kb))
                log_to_file "Deleted Time Machine snapshots"
            elif [[ "$path" == "SYSTEM:docker" ]]; then
                info "Running docker system prune..."
                docker system prune -af 2>/dev/null || true
                deleted=$((deleted + size_kb))
                log_to_file "Ran docker system prune"
            elif [[ -d "$path" ]]; then
                if [[ "$ARCHIVE_MODE" == "true" ]]; then
                    local archive_dest
                    archive_dest=$(archive_path "$path")
                    deleted=$((deleted + size_kb))
                    if $VERBOSE; then
                        log "Archived: $path -> $archive_dest"
                    fi
                    log_to_file "Archived: $path -> $archive_dest"
                else
                    rm -rf "$path"
                    deleted=$((deleted + size_kb))
                    if $VERBOSE; then
                        log "Deleted: $path"
                    fi
                    log_to_file "Deleted: $path"
                fi
            fi
        fi
    done < "$FINDINGS_FILE"

    if [[ "$type" == "npm cache" ]]; then
        npm cache clean --force 2>/dev/null || true
    fi

    echo $deleted
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       Free Space Available — Smart Disk Cleanup              ║"
    echo "║                 Powered by corey-coder                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Show mode
    if [[ "$ARCHIVE_MODE" == "true" ]]; then
        info "Mode: ARCHIVE (files moved to $ARCHIVE_DIR)"
    else
        info "Mode: DELETE (permanent removal)"
    fi

    # Current disk usage
    info "Current disk usage:"
    df -h ~ 2>/dev/null | tail -1 | awk '{print "  Used: "$3" / "$2" ("$5" full), Available: "$4}'
    echo ""

    check_running_servers
    echo ""

    # Clean old archives
    if [[ "$ARCHIVE_MODE" == "true" ]]; then
        cleanup_old_archives
    fi

    # Drive selection
    local -a scan_paths=()

    if [[ -n "$SCAN_PATH" ]]; then
        scan_paths+=("$SCAN_PATH")
    elif [[ "$SCAN_ENTIRE_MACHINE" == "true" ]]; then
        warn "Full machine scan - this may take a while..."
        IFS=' ' read -ra scan_paths <<< "$(get_all_volumes)"
    elif $SKIP_DRIVE_MENU; then
        IFS=',' read -ra scan_paths <<< "$SCAN_PATHS"
        for i in "${!scan_paths[@]}"; do
            scan_paths[$i]="${scan_paths[$i]/#\~/$HOME}"
            scan_paths[$i]="${scan_paths[$i]// /}"
        done
    else
        list_drives

        read -p "Select drive/location to scan: " -r selection

        case "$selection" in
            q|Q) warn "Aborted."; exit 0 ;;
            a|A) scan_paths=("${AVAILABLE_VOLUMES[@]}") ;;
            f|F)
                warn "Full machine scan - this may take a while..."
                IFS=' ' read -ra scan_paths <<< "$(get_all_volumes)"
                ;;
            *)
                if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#AVAILABLE_VOLUMES[@]} ]]; then
                    scan_paths+=("${AVAILABLE_VOLUMES[$((selection-1))]}")
                else
                    error "Invalid selection"
                    exit 1
                fi
                ;;
        esac
    fi

    echo ""

    # Scanning
    for path in "${scan_paths[@]}"; do
        [[ -d "$path" ]] && scan_location "$path"
    done

    if [[ ! -s "$FINDINGS_FILE" ]]; then
        echo ""
        log "No caches found to clean!"
        exit 0
    fi

    # Calculate totals
    local total_kb=0 safe_kb=0 caution_kb=0 review_kb=0

    while IFS='|' read -r safety type size_kb path desc; do
        total_kb=$((total_kb + size_kb))
        case $safety in
            1) safe_kb=$((safe_kb + size_kb)) ;;
            2) caution_kb=$((caution_kb + size_kb)) ;;
            3) review_kb=$((review_kb + size_kb)) ;;
        esac
    done < "$FINDINGS_FILE"

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}                    SCAN RESULTS                               ${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    echo -e "${BOLD}Summary:${NC}"
    echo -e "  ${GREEN}[SAFE]${NC}     $(human_size $safe_kb) — 100% safe"
    echo -e "  ${YELLOW}[CAUTION]${NC}  $(human_size $caution_kb) — Usually safe"
    echo -e "  ${RED}[REVIEW]${NC}   $(human_size $review_kb) — Check first"
    echo -e "  ${BOLD}TOTAL${NC}      $(human_size $total_kb)"
    echo ""

    printf "  ${BOLD}%-4s %-10s %-30s %10s %6s${NC}\n" "#" "Safety" "Type" "Size" "Items"
    printf "  %-4s %-10s %-30s %10s %6s\n" "----" "----------" "------------------------------" "----------" "------"

    local menu_num=1
    local -a menu_types=()
    local -a menu_sizes=()
    local -a menu_safety=()
    local -a menu_descs=()

    while IFS=' ' read -r size safety type; do
        local count
        count=$(grep -c "|${type}|" "$FINDINGS_FILE" 2>/dev/null || echo 0)
        local desc
        desc=$(grep "|${type}|" "$FINDINGS_FILE" | head -1 | cut -d'|' -f5)

        menu_types+=("$type")
        menu_sizes+=("$size")
        menu_safety+=("$safety")
        menu_descs+=("$desc")

        printf "  ${CYAN}[%2d]${NC} %-10s %-30s %10s %6d\n" \
            "$menu_num" \
            "$(safety_label "$safety" | sed 's/\[0m/[0m /g')" \
            "$type" \
            "$(human_size "$size")" \
            "$count"

        menu_num=$((menu_num + 1))
    done < <(awk -F'|' '{size[$2]+=$3; safety[$2]=$1} END {for (t in size) print size[t], safety[t], t}' "$FINDINGS_FILE" | sort -rn)

    echo ""

    if [[ -n "$EXPLAIN_ITEM" ]]; then
        local idx=$((EXPLAIN_ITEM - 1))
        if [[ $idx -ge 0 ]] && [[ $idx -lt ${#menu_types[@]} ]]; then
            echo -e "${BOLD}Explanation for: ${menu_types[$idx]}${NC}"
            echo "  Safety: $(safety_label "${menu_safety[$idx]}")"
            echo "  Description: ${menu_descs[$idx]}"
            echo ""
            if [[ "$AI_ENABLED" == "true" ]]; then
                info "Asking corey-coder..."
                ask_corey "What is '${menu_types[$idx]}'? Is it safe to delete?" "Type: ${menu_types[$idx]}, Desc: ${menu_descs[$idx]}"
            fi
        fi
        exit 0
    fi

    if $VERBOSE; then
        echo -e "${BOLD}All directories:${NC}"
        while IFS='|' read -r safety type size_kb path desc; do
            printf "  %10s  %-10s  %s\n" "$(human_size "$size_kb")" "$(safety_label "$safety")" "$path"
        done < "$FINDINGS_FILE"
        echo ""
    fi

    echo -e "${BOLD}Recommendations:${NC}"
    if [[ $safe_kb -gt 0 ]]; then
        local action="Delete"
        [[ "$ARCHIVE_MODE" == "true" ]] && action="Archive"
        echo -e "  ${GREEN}→${NC} $action all ${GREEN}[SAFE]${NC} items: $(human_size $safe_kb) (enter 'r')"
    fi
    echo ""

    if $DRY_RUN; then
        warn "DRY RUN — no changes made."
        exit 0
    fi

    echo -e "${BOLD}Select what to clean:${NC}"
    echo -e "  ${DIM}Enter numbers (1 3 5), 'r' for recommended, 'a' for all, 'q' to quit${NC}"
    echo ""

    local selection
    if $FORCE; then
        selection="r"
        echo "Selection: r (--force mode)"
    else
        read -p "Selection: " -r selection
    fi

    [[ "$selection" == "q" || "$selection" == "Q" ]] && { warn "Aborted."; exit 0; }

    local -a selected_types=()

    if [[ "$selection" == "r" || "$selection" == "R" ]]; then
        for i in "${!menu_safety[@]}"; do
            [[ "${menu_safety[$i]}" == "1" ]] && selected_types+=("${menu_types[$i]}")
        done
    elif [[ "$selection" == "a" || "$selection" == "A" ]]; then
        selected_types=("${menu_types[@]}")
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#menu_types[@]} ]]; then
                selected_types+=("${menu_types[$((num-1))]}")
            fi
        done
    fi

    [[ ${#selected_types[@]} -eq 0 ]] && { warn "Nothing selected."; exit 0; }

    echo ""
    local action_word="delete"
    [[ "$ARCHIVE_MODE" == "true" ]] && action_word="archive"

    echo -e "${BOLD}Will ${action_word}:${NC}"
    local selected_total=0
    for type in "${selected_types[@]}"; do
        local type_size
        type_size=$(grep "|${type}|" "$FINDINGS_FILE" | cut -d'|' -f3 | awk '{sum+=$1} END {print sum+0}')
        local type_safety
        type_safety=$(grep "|${type}|" "$FINDINGS_FILE" | head -1 | cut -d'|' -f1)
        echo -e "  $(safety_label "$type_safety") $type ($(human_size "$type_size"))"
        selected_total=$((selected_total + type_size))
    done
    echo ""
    echo -e "  ${BOLD}Total: $(human_size $selected_total)${NC}"
    echo ""

    if [[ "$REQUIRE_CONFIRMATION" == "true" ]] && ! $FORCE; then
        read -p "Proceed? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && { warn "Aborted."; exit 0; }
    fi

    echo ""
    info "Processing..."

    local deleted_kb=0
    for type in "${selected_types[@]}"; do
        info "Cleaning: $type"
        local freed
        freed=$(delete_type "$type")
        deleted_kb=$((deleted_kb + freed))
    done

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    if [[ "$ARCHIVE_MODE" == "true" ]]; then
        log "Archived: $(human_size $deleted_kb) to $ARCHIVE_DIR"
    else
        log "Reclaimed: $(human_size $deleted_kb)"
    fi
    echo ""
    info "Updated disk usage:"
    df -h ~ 2>/dev/null | tail -1 | awk '{print "  Used: "$3" / "$2" ("$5" full), Available: "$4}'
    echo ""
    log "Done!"
}

main

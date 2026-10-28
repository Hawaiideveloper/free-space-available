#!/bin/bash
# cleanup.sh — Smart disk cleanup for development machines
# Part of free-space-available repo
# Integrates with corey-coder for intelligent recommendations
#
# Usage:
#   cleanup.sh                # Interactive: pick drive, scan, select, delete
#   cleanup.sh --scan         # Scan default locations only (no drive menu)
#   cleanup.sh --dry-run      # Show what would be deleted
#   cleanup.sh --force        # Delete all recommendations without prompts
#   cleanup.sh --ask "query"  # Ask corey-coder about disk usage
#   cleanup.sh --explain 5    # Explain what item #5 is and if it's safe

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

DRY_RUN=false
FORCE=false
VERBOSE=false
SKIP_DRIVE_MENU=false
SCAN_PATH=""
ASK_QUERY=""
EXPLAIN_ITEM=""

# Corey-coder endpoint (via corey-router)
COREY_ENDPOINT="${COREY_ENDPOINT:-http://corey-router.corey-coder.svc.cluster.local:8081}"
COREY_MODEL="${COREY_MODEL:-corey-coder:latest}"

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

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Smart disk cleanup for development machines with AI-powered recommendations.
Integrates with corey-coder for intelligent analysis.

Workflow:
  1. Lists available drives/volumes
  2. You select which drive to scan
  3. Scans for all known cache types
  4. Shows recommendations sorted by size and safety
  5. You select what to delete (or use 'r' for recommended)

Options:
  -s, --scan         Skip drive menu, scan default locations
  -p, --path PATH    Scan specific path
  -n, --dry-run      Show findings without deleting
  -f, --force        Delete all recommended items without prompts
  -v, --verbose      Show every directory found
  -h, --help         Show this help

AI Integration:
  --ask "question"   Ask corey-coder about disk usage or caches
  --explain N        Explain what item #N is and if it's safe to delete

Safety Levels:
  ${GREEN}[SAFE]${NC}      100% safe to delete, regenerates automatically
  ${YELLOW}[CAUTION]${NC}   Usually safe, but check if you need cached data
  ${RED}[REVIEW]${NC}    Review before deleting, may contain important data

Environment:
  COREY_ENDPOINT     Corey-router endpoint (default: cluster internal)
  COREY_MODEL        Model to use (default: corey-coder:latest)

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--dry-run) DRY_RUN=true; shift ;;
        -f|--force)   FORCE=true; shift ;;
        -s|--scan)    SKIP_DRIVE_MENU=true; shift ;;
        -p|--path)    SCAN_PATH="$2"; SKIP_DRIVE_MENU=true; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        --ask)        ASK_QUERY="$2"; shift 2 ;;
        --explain)    EXPLAIN_ITEM="$2"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *) error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ═══════════════════════════════════════════════════════════════════════════
# COREY-CODER INTEGRATION
# ═══════════════════════════════════════════════════════════════════════════

ask_corey() {
    local question="$1"
    local context="$2"

    # Try corey-coder via corey-router
    local response
    response=$(curl -s --max-time 30 "${COREY_ENDPOINT}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${COREY_MODEL}\",
            \"messages\": [
                {
                    \"role\": \"system\",
                    \"content\": \"You are a disk cleanup expert. You help users understand what files and caches are safe to delete on macOS/Linux development machines. Be concise and direct. Context about the current scan: ${context}\"
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
        echo "Unable to reach corey-coder. Using built-in knowledge."
    fi
}

# Handle --ask flag
if [[ -n "$ASK_QUERY" ]]; then
    echo ""
    echo -e "${BOLD}Asking corey-coder...${NC}"
    echo ""
    ask_corey "$ASK_QUERY" "General disk cleanup query"
    exit 0
fi

# Temp file to store findings
FINDINGS_FILE=$(mktemp)
trap "rm -f $FINDINGS_FILE" EXIT

# Record a finding: safety|type|size_kb|path|description
# Safety: 1=SAFE, 2=CAUTION, 3=REVIEW
record() {
    local safety="$1"
    local type="$2"
    local size_kb="$3"
    local path="$4"
    local description="${5:-}"
    echo "${safety}|${type}|${size_kb}|${path}|${description}" >> "$FINDINGS_FILE"
}

# Format size in human readable
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

# Get directory size in KB
dir_size() {
    du -sk "$1" 2>/dev/null | cut -f1 || echo 0
}

# Scan for a pattern in a path
scan_pattern() {
    local safety="$1"
    local description="$2"
    local pattern="$3"
    local search_path="$4"
    local explanation="${5:-Regenerates automatically}"

    [[ ! -d "$search_path" ]] && return

    while IFS= read -r dir; do
        if [[ -d "$dir" ]]; then
            local size_kb
            size_kb=$(dir_size "$dir")
            if [[ $size_kb -gt 100 ]]; then
                record "$safety" "$description" "$size_kb" "$dir" "$explanation"
            fi
        fi
    done < <(find "$search_path" -name "$pattern" -type d -prune 2>/dev/null || true)
}

# Scan for a path pattern
scan_path_pattern() {
    local safety="$1"
    local description="$2"
    local pattern="$3"
    local search_path="$4"
    local explanation="${5:-Regenerates automatically}"

    [[ ! -d "$search_path" ]] && return

    while IFS= read -r dir; do
        if [[ -d "$dir" ]]; then
            local size_kb
            size_kb=$(dir_size "$dir")
            if [[ $size_kb -gt 100 ]]; then
                record "$safety" "$description" "$size_kb" "$dir" "$explanation"
            fi
        fi
    done < <(find "$search_path" -path "$pattern" -type d 2>/dev/null || true)
}

# Check a single directory
scan_dir() {
    local safety="$1"
    local description="$2"
    local dir="$3"
    local explanation="${4:-Regenerates automatically}"

    if [[ -d "$dir" ]]; then
        local size_kb
        size_kb=$(dir_size "$dir")
        if [[ $size_kb -gt 100 ]]; then
            record "$safety" "$description" "$size_kb" "$dir" "$explanation"
        fi
    fi
}

# List available drives/volumes
list_drives() {
    echo ""
    echo -e "${BOLD}Available Drives/Volumes:${NC}"
    echo ""
    printf "  ${BOLD}%-4s %-30s %10s %10s %8s${NC}\n" "#" "Volume" "Size" "Used" "Avail"
    printf "  %-4s %-30s %10s %10s %8s\n" "----" "------------------------------" "----------" "----------" "--------"

    local idx=1
    local -a volumes=()

    # macOS: Get mounted volumes
    while IFS= read -r line; do
        local filesystem=$(echo "$line" | awk '{print $1}')
        local size=$(echo "$line" | awk '{print $2}')
        local used=$(echo "$line" | awk '{print $3}')
        local avail=$(echo "$line" | awk '{print $4}')
        local capacity=$(echo "$line" | awk '{print $5}')
        local mount=$(echo "$line" | awk '{for(i=9;i<=NF;i++) printf $i" "; print ""}' | sed 's/ $//')

        # Skip system volumes
        if [[ "$mount" == "/" ]] || \
           [[ "$mount" == "/System"* ]] || \
           [[ "$mount" == "/private"* ]] || \
           [[ "$mount" == "/dev" ]] || \
           [[ "$mount" == "/Volumes/Recovery" ]]; then
            continue
        fi

        # Include data volume and external volumes
        if [[ "$mount" == "/System/Volumes/Data" ]] || \
           [[ "$mount" == "/Volumes/"* ]] || \
           [[ "$mount" == "$HOME"* ]]; then

            local display_name="$mount"
            if [[ "$mount" == "/System/Volumes/Data" ]]; then
                display_name="Macintosh HD (Data)"
            fi

            volumes+=("$mount")
            printf "  ${CYAN}[%d]${NC}  %-30s %10s %10s %8s\n" "$idx" "$display_name" "$size" "$used" "$avail"
            idx=$((idx + 1))
        fi
    done < <(df -h 2>/dev/null | tail -n +2)

    # Quick scan locations
    echo ""
    echo -e "  ${BOLD}Quick scan locations:${NC}"

    if [[ -d "$HOME/Documents/github" ]]; then
        volumes+=("$HOME/Documents/github")
        printf "  ${CYAN}[%d]${NC}  %-30s %10s\n" "$idx" "~/Documents/github" "(dev projects)"
        idx=$((idx + 1))
    fi

    if [[ -d "$HOME/Developer" ]]; then
        volumes+=("$HOME/Developer")
        printf "  ${CYAN}[%d]${NC}  %-30s %10s\n" "$idx" "~/Developer" "(Xcode projects)"
        idx=$((idx + 1))
    fi

    if [[ -d "$HOME" ]]; then
        volumes+=("$HOME")
        printf "  ${CYAN}[%d]${NC}  %-30s %10s\n" "$idx" "~ (Home directory)" "(full scan)"
        idx=$((idx + 1))
    fi

    echo ""
    printf "  ${CYAN}[a]${NC}  %-30s\n" "All of the above"
    printf "  ${CYAN}[q]${NC}  %-30s\n" "Quit"
    echo ""

    AVAILABLE_VOLUMES=("${volumes[@]}")
}

# ═══════════════════════════════════════════════════════════════════════════
# COMPREHENSIVE SCAN
# ═══════════════════════════════════════════════════════════════════════════

scan_location() {
    local base_path="$1"

    info "Scanning: $base_path"
    echo -e "${DIM}  This may take a minute for large directories...${NC}"

    # ═══════════════════════════════════════════════════════════════════
    # SAFE - 100% regenerates automatically (safety=1)
    # ═══════════════════════════════════════════════════════════════════

    # JavaScript/Node
    scan_pattern 1 "node_modules" "node_modules" "$base_path" "npm/yarn dependencies - run 'npm install' to restore"
    scan_pattern 1 "Next.js cache (.next)" ".next" "$base_path" "Next.js build output - run 'npm run build' to restore"
    scan_pattern 1 "Nuxt cache (.nuxt)" ".nuxt" "$base_path" "Nuxt.js build output"
    scan_pattern 1 "Vite cache" ".vite" "$base_path" "Vite build cache"
    scan_pattern 1 "Parcel cache" ".parcel-cache" "$base_path" "Parcel bundler cache"
    scan_pattern 1 "Webpack cache" ".cache" "$base_path" "Webpack/bundler cache"
    scan_pattern 1 "Turborepo cache" ".turbo" "$base_path" "Turborepo monorepo cache"
    scan_pattern 1 "Storybook cache" "storybook-static" "$base_path" "Storybook build output"
    scan_pattern 1 "Jest cache" ".jest-cache" "$base_path" "Jest test cache"

    # Python
    scan_pattern 1 "Python cache (__pycache__)" "__pycache__" "$base_path" "Python bytecode - regenerates on import"
    scan_pattern 1 "pytest cache" ".pytest_cache" "$base_path" "pytest test cache"
    scan_pattern 1 "mypy cache" ".mypy_cache" "$base_path" "mypy type checker cache"
    scan_pattern 1 "Ruff cache" ".ruff_cache" "$base_path" "Ruff linter cache"
    scan_pattern 1 "Python eggs" "*.egg-info" "$base_path" "Python package metadata"
    scan_pattern 1 "Python build" "build" "$base_path" "Python build artifacts"
    scan_pattern 1 "Python dist" "dist" "$base_path" "Python distribution files"

    # iOS/macOS
    scan_pattern 1 "CocoaPods" "Pods" "$base_path" "iOS dependencies - run 'pod install' to restore"
    scan_pattern 1 "Carthage build" "Carthage" "$base_path" "Carthage dependency builds"
    scan_path_pattern 1 "Xcode DerivedData" "*/DerivedData" "$base_path" "Xcode build cache"
    scan_pattern 1 "Swift PM cache" ".build" "$base_path" "Swift Package Manager build"
    scan_pattern 1 "xcarchive" "*.xcarchive" "$base_path" "Xcode archives"

    # Android
    scan_pattern 1 "Android NDK cache (.cxx)" ".cxx" "$base_path" "Android NDK build cache"
    scan_pattern 1 "Gradle cache (.gradle)" ".gradle" "$base_path" "Gradle build cache"
    scan_pattern 1 "Android build" "build" "$base_path" "Android build output"

    # Rust
    scan_path_pattern 1 "Rust target (Tauri)" "*/src-tauri/target" "$base_path" "Tauri/Rust build artifacts"
    scan_pattern 1 "Rust target" "target" "$base_path" "Rust/Cargo build artifacts"

    # Go
    scan_pattern 1 "Go build cache" "go-build" "$base_path" "Go build cache"

    # Ruby
    scan_pattern 1 "Bundler cache" "vendor/bundle" "$base_path" "Ruby bundler cache"

    # Claude Code
    scan_path_pattern 1 "Claude worktrees" "*/.claude/worktrees" "$base_path" "Claude Code git worktrees"

    # System-level caches (only if scanning home)
    if [[ "$base_path" == "$HOME"* ]] || [[ "$base_path" == "/System/Volumes/Data" ]]; then
        # Package managers
        scan_dir 1 "npm cache" "$HOME/.npm" "npm global cache - run 'npm cache clean' to clear"
        scan_dir 1 "yarn cache" "$HOME/.yarn/cache" "Yarn package cache"
        scan_dir 1 "pnpm store" "$HOME/.pnpm-store" "pnpm content-addressable store"
        scan_dir 1 "bun cache" "$HOME/.bun/install/cache" "Bun package cache"
        scan_dir 1 "pip cache" "$HOME/.cache/pip" "pip download cache"
        scan_dir 1 "pip cache (Library)" "$HOME/Library/Caches/pip" "pip download cache (macOS)"
        scan_dir 1 "Poetry cache" "$HOME/Library/Caches/pypoetry" "Poetry package cache"
        scan_dir 1 "Cargo registry" "$HOME/.cargo/registry" "Rust crate downloads"
        scan_dir 1 "Cargo git" "$HOME/.cargo/git" "Rust git dependencies"
        scan_dir 1 "Go mod cache" "$HOME/go/pkg/mod" "Go module cache"
        scan_dir 1 "Gradle global cache" "$HOME/.gradle/caches" "Gradle global cache"
        scan_dir 1 "Maven cache" "$HOME/.m2/repository" "Maven artifact cache"
        scan_dir 1 "CocoaPods cache" "$HOME/Library/Caches/CocoaPods" "CocoaPods spec cache"
        scan_dir 1 "Homebrew cache" "$HOME/Library/Caches/Homebrew" "Homebrew download cache"
        scan_dir 1 "Homebrew downloads" "$(brew --cache 2>/dev/null || echo '/nonexistent')" "Homebrew formula downloads"

        # IDE/Editor caches
        scan_dir 1 "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData" "Xcode build cache"
        scan_dir 1 "Xcode Archives" "$HOME/Library/Developer/Xcode/Archives" "Old Xcode archives"
        scan_dir 1 "iOS DeviceSupport" "$HOME/Library/Developer/Xcode/iOS DeviceSupport" "iOS debug symbols"
        scan_dir 1 "watchOS DeviceSupport" "$HOME/Library/Developer/Xcode/watchOS DeviceSupport" "watchOS debug symbols"
        scan_dir 1 "CoreSimulator Devices" "$HOME/Library/Developer/CoreSimulator/Devices" "iOS Simulator data"
        scan_dir 1 "VS Code cache" "$HOME/Library/Application Support/Code/Cache" "VS Code cache"
        scan_dir 1 "VS Code CachedData" "$HOME/Library/Application Support/Code/CachedData" "VS Code extension cache"
        scan_dir 1 "JetBrains cache" "$HOME/Library/Caches/JetBrains" "IntelliJ/WebStorm/etc cache"

        # React Native / Mobile
        scan_dir 1 "Metro cache" "$HOME/.metro" "React Native Metro bundler cache"
        scan_dir 1 "Expo cache" "$HOME/.expo" "Expo CLI cache"
        scan_dir 1 "Watchman state" "$HOME/Library/Caches/watchman" "Watchman file watcher state"

        # Testing tools
        scan_dir 1 "Playwright browsers" "$HOME/Library/Caches/ms-playwright" "Playwright browser binaries"
        scan_dir 1 "Cypress cache" "$HOME/Library/Caches/Cypress" "Cypress browser/cache"
        scan_dir 1 "Puppeteer cache" "$HOME/.cache/puppeteer" "Puppeteer Chrome binaries"

        # Misc development
        scan_dir 1 "TypeScript cache" "$HOME/Library/Caches/typescript" "TypeScript compiler cache"

        # App caches (usually safe)
        scan_dir 1 "Spotify cache" "$HOME/Library/Caches/com.spotify.client" "Spotify streaming cache"
        scan_dir 1 "Discord cache" "$HOME/Library/Caches/com.hnc.Discord" "Discord cache"
        scan_dir 1 "Zoom cache" "$HOME/Library/Caches/us.zoom.xos" "Zoom cache"
        scan_dir 1 "Teams cache" "$HOME/Library/Caches/com.microsoft.teams" "Microsoft Teams cache"

        # Font caches
        scan_dir 1 "Font caches" "$HOME/Library/Caches/com.apple.FontRegistry" "macOS font cache"
    fi

    # ═══════════════════════════════════════════════════════════════════
    # CAUTION - Usually safe but double-check (safety=2)
    # ═══════════════════════════════════════════════════════════════════

    if [[ "$base_path" == "$HOME"* ]] || [[ "$base_path" == "/System/Volumes/Data" ]]; then
        # Docker
        scan_dir 2 "Docker data" "$HOME/Library/Containers/com.docker.docker/Data" "Docker images, containers, volumes - use 'docker system prune' instead"

        # Logs
        scan_dir 2 "System logs" "$HOME/Library/Logs" "Application logs - may need for debugging"

        # Browser caches
        scan_dir 2 "Chrome cache" "$HOME/Library/Caches/Google/Chrome" "Chrome browser cache - will slow browsing temporarily"
        scan_dir 2 "Safari cache" "$HOME/Library/Caches/com.apple.Safari" "Safari browser cache"
        scan_dir 2 "Firefox cache" "$HOME/Library/Caches/Firefox" "Firefox browser cache"

        # Cloud storage
        scan_dir 2 "iCloud cache" "$HOME/Library/Caches/CloudKit" "iCloud sync cache"
        scan_dir 2 "Dropbox cache" "$HOME/Library/Caches/com.getdropbox.dropbox" "Dropbox sync cache"

        # Email
        scan_dir 2 "Mail attachments" "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads" "Email attachment cache"

        # Xcode downloads
        scan_dir 2 "Xcode downloads" "$HOME/Library/Developer/Xcode/Downloads" "Xcode component downloads"
    fi

    # ═══════════════════════════════════════════════════════════════════
    # REVIEW - Check before deleting (safety=3)
    # ═══════════════════════════════════════════════════════════════════

    if [[ "$base_path" == "$HOME"* ]] || [[ "$base_path" == "/System/Volumes/Data" ]]; then
        # Virtual environments
        scan_pattern 3 "Python venv" ".venv" "$base_path" "Python virtual environment - may have custom packages"
        scan_pattern 3 "Python venv (venv)" "venv" "$base_path" "Python virtual environment"

        # User data
        scan_dir 3 "Trash" "$HOME/.Trash" "Deleted files - empty via Finder if sure"
        scan_dir 3 "Downloads" "$HOME/Downloads" "Downloaded files - review before deleting"

        # iOS backups
        scan_dir 3 "iOS backups" "$HOME/Library/Application Support/MobileSync/Backup" "iPhone/iPad backups - may be your only copy"
    fi

    # ═══════════════════════════════════════════════════════════════════
    # SPECIAL SCANS (command-based, not directory-based)
    # ═══════════════════════════════════════════════════════════════════

    # Time Machine local snapshots (macOS only)
    if command -v tmutil &>/dev/null; then
        local tm_size
        tm_size=$(tmutil listlocalsnapshotdates / 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        if [[ $tm_size -gt 0 ]]; then
            # Estimate ~1GB per snapshot
            record 1 "Time Machine snapshots" "$((tm_size * 1048576))" "SYSTEM:tmutil" "Local Time Machine snapshots - safe to delete, will recreate"
        fi
    fi

    # Docker system (if docker is available)
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        local docker_size
        docker_size=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 | sed 's/GB/*1048576/;s/MB/*1024/;s/kB//;s/B//' | bc 2>/dev/null || echo 0)
        if [[ $docker_size -gt 100 ]]; then
            record 2 "Docker system" "$docker_size" "SYSTEM:docker" "Docker images/containers/volumes - use 'docker system prune -a' to clean"
        fi
    fi
}

# Check for running dev servers
check_running_servers() {
    local running
    running=$(ps aux | grep -E "next dev|npm run dev|vite|webpack serve|flask run|uvicorn|gunicorn" | grep -v grep || true)
    if [[ -n "$running" ]]; then
        warn "Running dev servers detected:"
        echo "$running" | head -5
        echo ""
        if ! $FORCE; then
            read -p "Stop them and continue? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                pkill -f "next dev" 2>/dev/null || true
                pkill -f "npm run dev" 2>/dev/null || true
                pkill -f "vite" 2>/dev/null || true
                sleep 2
                log "Dev servers stopped"
            else
                warn "Continuing anyway (some caches may be locked)"
            fi
        fi
    else
        log "No dev servers running"
    fi
}

# Get safety label with color
safety_label() {
    case $1 in
        1) echo -e "${GREEN}[SAFE]${NC}" ;;
        2) echo -e "${YELLOW}[CAUTION]${NC}" ;;
        3) echo -e "${RED}[REVIEW]${NC}" ;;
    esac
}

# Delete entries of a specific type
delete_type() {
    local type="$1"
    local deleted=0

    while IFS='|' read -r safety t size_kb path desc; do
        if [[ "$t" == "$type" ]]; then
            if [[ "$path" == "SYSTEM:tmutil" ]]; then
                # Handle Time Machine snapshots
                info "Deleting Time Machine local snapshots..."
                tmutil deletelocalsnapshots / 2>/dev/null || true
                deleted=$((deleted + size_kb))
            elif [[ "$path" == "SYSTEM:docker" ]]; then
                # Handle Docker cleanup
                info "Running docker system prune..."
                docker system prune -af 2>/dev/null || true
                deleted=$((deleted + size_kb))
            elif [[ -d "$path" ]]; then
                rm -rf "$path"
                deleted=$((deleted + size_kb))
                if $VERBOSE; then
                    log "Deleted: $path"
                fi
            fi
        fi
    done < "$FINDINGS_FILE"

    # Special handling for npm cache
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

    # Show current disk usage
    info "Current disk usage:"
    df -h ~ 2>/dev/null | tail -1 | awk '{print "  Used: "$3" / "$2" ("$5" full), Available: "$4}'
    echo ""

    check_running_servers
    echo ""

    # Drive selection
    local -a scan_paths=()

    if [[ -n "$SCAN_PATH" ]]; then
        scan_paths+=("$SCAN_PATH")
    elif $SKIP_DRIVE_MENU; then
        scan_paths+=("$HOME/Documents/github")
        scan_paths+=("$HOME")
    else
        list_drives

        read -p "Select drive/location to scan: " -r selection

        if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
            warn "Aborted."
            exit 0
        fi

        if [[ "$selection" == "a" || "$selection" == "A" ]]; then
            scan_paths=("${AVAILABLE_VOLUMES[@]}")
        elif [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 1 ]] && [[ $selection -le ${#AVAILABLE_VOLUMES[@]} ]]; then
            scan_paths+=("${AVAILABLE_VOLUMES[$((selection-1))]}")
        else
            error "Invalid selection"
            exit 1
        fi
    fi

    echo ""

    # Scanning
    for path in "${scan_paths[@]}"; do
        scan_location "$path"
    done

    # Analysis
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

    # Summary
    echo -e "${BOLD}Summary:${NC}"
    echo -e "  ${GREEN}[SAFE]${NC}     $(human_size $safe_kb) — 100% safe to delete"
    echo -e "  ${YELLOW}[CAUTION]${NC}  $(human_size $caution_kb) — Usually safe, verify first"
    echo -e "  ${RED}[REVIEW]${NC}   $(human_size $review_kb) — Check before deleting"
    echo -e "  ${BOLD}TOTAL${NC}      $(human_size $total_kb)"
    echo ""

    # Detailed table
    printf "  ${BOLD}%-4s %-10s %-28s %10s %6s${NC}\n" "#" "Safety" "Type" "Size" "Items"
    printf "  %-4s %-10s %-28s %10s %6s\n" "----" "----------" "----------------------------" "----------" "------"

    local menu_num=1
    local -a menu_types=()
    local -a menu_sizes=()
    local -a menu_safety=()
    local -a menu_descs=()

    while IFS=' ' read -r size safety type; do
        local count
        count=$(grep "|${type}|" "$FINDINGS_FILE" | wc -l | tr -d ' ')
        local desc
        desc=$(grep "|${type}|" "$FINDINGS_FILE" | head -1 | cut -d'|' -f5)

        menu_types+=("$type")
        menu_sizes+=("$size")
        menu_safety+=("$safety")
        menu_descs+=("$desc")

        printf "  ${CYAN}[%2d]${NC} %-10s %-28s %10s %6d\n" \
            "$menu_num" \
            "$(safety_label "$safety" | sed 's/\[0m/[0m /g')" \
            "$type" \
            "$(human_size "$size")" \
            "$count"

        menu_num=$((menu_num + 1))
    done < <(awk -F'|' '{size[$2]+=$3; safety[$2]=$1} END {for (t in size) print size[t], safety[t], t}' "$FINDINGS_FILE" | sort -rn)

    echo ""

    # Handle --explain flag
    if [[ -n "$EXPLAIN_ITEM" ]]; then
        local idx=$((EXPLAIN_ITEM - 1))
        if [[ $idx -ge 0 ]] && [[ $idx -lt ${#menu_types[@]} ]]; then
            local type="${menu_types[$idx]}"
            local desc="${menu_descs[$idx]}"
            local safety="${menu_safety[$idx]}"

            echo -e "${BOLD}Explanation for: ${type}${NC}"
            echo ""
            echo -e "  Safety: $(safety_label "$safety")"
            echo -e "  Description: $desc"
            echo ""

            # Ask corey-coder for more details
            info "Asking corey-coder for more details..."
            ask_corey "What is '${type}' cache/directory? Is it safe to delete? What are the consequences?" "Item: ${type}, Built-in description: ${desc}"
        else
            error "Invalid item number"
        fi
        exit 0
    fi

    # Verbose mode
    if $VERBOSE; then
        echo -e "${BOLD}All directories found:${NC}"
        while IFS='|' read -r safety type size_kb path desc; do
            printf "  %10s  %-10s  %s\n" "$(human_size "$size_kb")" "$(safety_label "$safety")" "$path"
        done < "$FINDINGS_FILE"
        echo ""
    fi

    # Recommendations
    echo -e "${BOLD}Recommendations:${NC}"
    if [[ $safe_kb -gt 0 ]]; then
        echo -e "  ${GREEN}→${NC} Delete all ${GREEN}[SAFE]${NC} items: $(human_size $safe_kb) (enter 'r')"
    fi
    if [[ $safe_kb -gt 1048576 ]]; then
        echo -e "  ${GREEN}→${NC} This will free significant space with zero risk"
    fi
    echo -e "  ${DIM}Tip: Use --explain N to learn more about any item${NC}"
    echo ""

    # Selection
    if $DRY_RUN; then
        warn "DRY RUN — no files deleted."
        exit 0
    fi

    echo -e "${BOLD}Select what to delete:${NC}"
    echo -e "  ${DIM}Enter numbers (e.g., 1 3 5), 'r' for recommended, 'a' for all, 'q' to quit${NC}"
    echo ""

    if $FORCE; then
        selection="r"
        echo "Selection: r (--force mode)"
    else
        read -p "Selection: " -r selection
    fi

    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        warn "Aborted."
        exit 0
    fi

    local -a selected_types=()

    if [[ "$selection" == "r" || "$selection" == "R" ]]; then
        for i in "${!menu_safety[@]}"; do
            if [[ "${menu_safety[$i]}" == "1" ]]; then
                selected_types+=("${menu_types[$i]}")
            fi
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

    if [[ ${#selected_types[@]} -eq 0 ]]; then
        warn "Nothing selected. Aborted."
        exit 0
    fi

    # Confirmation
    echo ""
    echo -e "${BOLD}Will delete:${NC}"
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

    if ! $FORCE; then
        read -p "Proceed? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            warn "Aborted."
            exit 0
        fi
    fi

    # Deletion
    echo ""
    info "Deleting selected items..."

    local deleted_kb=0
    for type in "${selected_types[@]}"; do
        info "Cleaning: $type"
        local freed
        freed=$(delete_type "$type")
        deleted_kb=$((deleted_kb + freed))
    done

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    log "Reclaimed: $(human_size $deleted_kb)"
    echo ""
    info "Updated disk usage:"
    df -h ~ 2>/dev/null | tail -1 | awk '{print "  Used: "$3" / "$2" ("$5" full), Available: "$4}'
    echo ""
    log "Done! Run 'npm install', 'pod install', etc. in projects as needed."
}

main

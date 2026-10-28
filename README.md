# free-space-available

Smart disk cleanup for development machines, powered by corey-coder AI.

**Cross-platform**: Works on macOS, Linux, and Windows.

## Features

- **Drive Selection**: Lists available volumes and quick-scan locations
- **Comprehensive Scanning**: 50+ cache types across all major languages/tools
- **Safety Levels**: `[SAFE]`, `[CAUTION]`, `[REVIEW]` categories
- **Archive Mode**: Move files to archive instead of permanent delete
- **AI-Powered**: Ask corey-coder about any cache type or disk question
- **MCP Integration**: Use from Claude Code or any MCP client
- **Interactive Menu**: Select exactly what to delete
- **Configuration**: .env file support for all settings

## Quick Start

### macOS / Linux

```bash
# Run the cleanup tool
./src/cleanup.sh

# Or link to ~/bin for easy access
ln -sf ~/Documents/github/free-space-available/src/cleanup.sh ~/bin/cleanup-dev-caches.sh
chmod +x ~/Documents/github/free-space-available/src/cleanup.sh
cleanup-dev-caches.sh
```

### Windows (PowerShell)

```powershell
# Run the cleanup tool
.\src\cleanup.ps1

# Or with full path
C:\Users\YourName\Documents\github\free-space-available\src\cleanup.ps1
```

## Configuration

Copy `.env.example` to `.env` and customize:

```bash
cp .env.example .env
```

The tool looks for configuration in these locations (first found wins):
1. `<repo>/.env`
2. `~/.cleanup-dev-caches.env`
3. `~/.config/free-space-available/.env`

### Key Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `SCAN_PATHS` | `~/Documents/github,~` | Default scan locations (comma-separated) |
| `SCAN_ENTIRE_MACHINE` | `false` | Scan all drives/volumes |
| `ARCHIVE_MODE` | `false` | Move to archive instead of delete |
| `ARCHIVE_DIR` | `~/.cleanup-archive` | Archive storage location |
| `ARCHIVE_COMPRESS` | `true` | Compress archives (.tar.gz / .zip) |
| `ARCHIVE_RETENTION_DAYS` | `30` | Auto-delete archives older than N days |
| `AI_ENABLED` | `true` | Enable corey-coder queries |
| `COREY_ENDPOINT` | Cluster internal | corey-router API endpoint |
| `COREY_MODEL` | `corey-coder:latest` | Model for AI queries |
| `SAFE_MODE_ONLY` | `false` | Only delete SAFE items |
| `MIN_SIZE_KB` | `100` | Minimum size to report |

## Usage

### Interactive Mode (default)

```bash
# macOS/Linux
./src/cleanup.sh

# Windows
.\src\cleanup.ps1
```

1. Shows available drives/volumes
2. You select where to scan
3. Displays categorized results with safety levels
4. You select what to delete (or `r` for recommended)

### Command Line Options

#### macOS/Linux

```bash
cleanup.sh --dry-run        # Preview only
cleanup.sh --scan           # Skip drive menu, use config paths
cleanup.sh --full           # Scan entire machine
cleanup.sh --path ~/code    # Scan specific path
cleanup.sh --force          # Delete SAFE items automatically
cleanup.sh --archive        # Move to archive instead of delete
cleanup.sh --verbose        # Show all directories
cleanup.sh --config         # Show current configuration
```

#### Windows

```powershell
cleanup.ps1 -DryRun         # Preview only
cleanup.ps1 -Scan           # Skip drive menu, use config paths
cleanup.ps1 -Full           # Scan entire machine
cleanup.ps1 -Path "C:\code" # Scan specific path
cleanup.ps1 -Force          # Delete SAFE items automatically
cleanup.ps1 -Archive        # Move to archive instead of delete
cleanup.ps1 -Verbose        # Show all directories
cleanup.ps1 -Config         # Show current configuration
```

### Archive Mode

Instead of permanently deleting files, move them to an archive directory:

```bash
# Enable via command line
cleanup.sh --archive

# Or set in .env
ARCHIVE_MODE=true
ARCHIVE_DIR=~/backup/cleanup-archive
ARCHIVE_COMPRESS=true
ARCHIVE_RETENTION_DAYS=30
```

Archives are:
- Named with timestamp: `20261028_143022_node_modules.tar.gz`
- Compressed by default (`.tar.gz` on Unix, `.zip` on Windows)
- Auto-deleted after retention period

### AI Integration

```bash
# Ask corey-coder about disk cleanup
cleanup.sh --ask "Is it safe to delete .venv folders?"

# Explain a specific cache type
cleanup.sh --explain 5   # Explain item #5 from scan

# Windows
cleanup.ps1 -Ask "What's using the most space?"
cleanup.ps1 -Explain 5
```

### Python API

```python
from src.corey_integration import CoreyCleanupAdvisor

advisor = CoreyCleanupAdvisor()

# Ask questions
answer = advisor.ask("What's using the most space on a dev machine?")

# Get safety info
safety = advisor.get_safety("node_modules")  # SafetyLevel.SAFE

# Explain cache type
explanation = advisor.explain("DerivedData")

# Analyze scan results
recommendations = advisor.analyze_scan(scan_results)
```

### MCP Server

Add to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "free-space-available": {
      "command": "python",
      "args": ["-m", "mcp.server"],
      "cwd": "~/Documents/github/free-space-available"
    }
  }
}
```

Available MCP tools:
- `scan_disk` - Scan for deletable caches
- `explain_cache` - Explain what a cache is
- `ask_cleanup` - Ask corey-coder questions
- `delete_caches` - Delete selected cache types
- `get_disk_usage` - Check disk usage

## Safety Levels

| Level | Color | Meaning |
|-------|-------|---------|
| `[SAFE]` | Green | 100% safe to delete, auto-regenerates |
| `[CAUTION]` | Yellow | Usually safe, but verify first |
| `[REVIEW]` | Red | Check before deleting, may have important data |

## What It Scans

### JavaScript/Node
- `node_modules/` - npm/yarn dependencies
- `.next/` - Next.js build cache
- `.nuxt/` - Nuxt.js cache
- `.vite/` - Vite cache
- `.turbo/` - Turborepo cache
- `storybook-static/` - Storybook builds

### Python
- `__pycache__/` - Bytecode cache
- `.venv/` / `venv/` - Virtual environments (REVIEW)
- `.pytest_cache/` - pytest cache
- `.mypy_cache/` - mypy cache
- `dist/` / `build/` - Build artifacts

### iOS/macOS
- `Pods/` - CocoaPods
- `DerivedData/` - Xcode build cache
- `CoreSimulator/` - iOS Simulator data
- `*.xcarchive` - Xcode archives

### Android
- `.gradle/` - Gradle cache
- `.cxx/` - NDK build cache
- `build/` - Android build output

### Rust
- `target/` - Cargo build artifacts

### Go
- `go/pkg/mod/` - Module cache
- `go-build/` - Build cache

### .NET (Windows)
- `bin/` / `obj/` - Build output
- `packages/` - NuGet packages
- `.nuget/packages/` - Global NuGet cache

### System Caches (macOS/Linux)
- `~/.npm` - npm global cache
- `~/.cargo/registry` - Rust crates
- `~/Library/Caches/Homebrew` - Homebrew
- `~/Library/Caches/pip` - pip
- Plus many more...

### System Caches (Windows)
- `%APPDATA%\npm-cache` - npm cache
- `%LOCALAPPDATA%\pip\Cache` - pip cache
- `%USERPROFILE%\.nuget\packages` - NuGet cache
- `%APPDATA%\Code\Cache` - VS Code cache
- `%TEMP%` - Temp files
- Plus many more...

## Architecture

```
free-space-available/
├── src/
│   ├── cleanup.sh          # macOS/Linux bash script
│   ├── cleanup.ps1         # Windows PowerShell script
│   └── corey_integration.py # Python AI integration
├── mcp/
│   └── server.py           # MCP server for Claude
├── .env.example            # Configuration template
└── README.md
```

## Contributing

1. Add new cache types to `scan_location()` in `cleanup.sh` or `Scan-Location` in `cleanup.ps1`
2. Add knowledge to `CACHE_KNOWLEDGE` in `corey_integration.py`
3. Test with `--dry-run` / `-DryRun` before committing

## License

MIT

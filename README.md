# free-space-available

Smart disk cleanup for development machines, powered by **corey-coder AI**.

Cross-platform support for **macOS**, **Linux**, and **Windows**.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           free-space-available                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         USER INTERFACES                              │   │
│   ├─────────────────┬─────────────────┬─────────────────────────────────┤   │
│   │                 │                 │                                 │   │
│   │  cleanup.sh     │  cleanup.ps1    │  MCP Server                     │   │
│   │  (macOS/Linux)  │  (Windows)      │  (Claude Code / MCP Clients)    │   │
│   │                 │                 │                                 │   │
│   │  Interactive    │  Interactive    │  Tools:                         │   │
│   │  • Drive select │  • Drive select │  • scan_disk                    │   │
│   │  • Scan         │  • Scan         │  • explain_cache                │   │
│   │  • Menu select  │  • Menu select  │  • ask_cleanup                  │   │
│   │  • Delete/Arch  │  • Delete/Arch  │  • delete_caches                │   │
│   │                 │                 │  • get_disk_usage               │   │
│   │                 │                 │  • list_cache_types             │   │
│   └────────┬────────┴────────┬────────┴──────────────┬──────────────────┘   │
│            │                 │                       │                      │
│            └─────────────────┼───────────────────────┘                      │
│                              │                                              │
│                              ▼                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    corey_integration.py                              │   │
│   │                    (Python AI Module)                                │   │
│   ├─────────────────────────────────────────────────────────────────────┤   │
│   │  CoreyCleanupAdvisor                                                 │   │
│   │  ├── explain(cache_type)     → Explain what a cache is               │   │
│   │  ├── ask(question)           → Ask any cleanup question              │   │
│   │  ├── analyze_scan(results)   → Get prioritized recommendations       │   │
│   │  └── get_safety(type)        → Get SafetyLevel for cache type        │   │
│   │                                                                      │   │
│   │  CACHE_KNOWLEDGE             → Built-in fallback knowledge base      │   │
│   │  SafetyLevel                 → SAFE | CAUTION | REVIEW               │   │
│   └────────────────────────────────────┬────────────────────────────────┘   │
│                                        │                                    │
│                                        ▼                                    │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         CONFIGURATION                                │   │
│   │                           (.env file)                                │   │
│   ├─────────────────────────────────────────────────────────────────────┤   │
│   │  Load order (first found wins):                                      │   │
│   │  1. <repo>/.env                                                      │   │
│   │  2. ~/.cleanup-dev-caches.env                                        │   │
│   │  3. ~/.config/free-space-available/.env                              │   │
│   │                                                                      │   │
│   │  Settings: SCAN_PATHS, ARCHIVE_MODE, ARCHIVE_DIR, AI_ENABLED,        │   │
│   │            COREY_ENDPOINT, COREY_MODEL, SAFE_MODE_ONLY, etc.         │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                        │                                    │
│                                        ▼                                    │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                      EXTERNAL SERVICES                               │   │
│   ├─────────────────────────────────────────────────────────────────────┤   │
│   │                                                                      │   │
│   │   ┌─────────────────┐         ┌─────────────────────────────────┐   │   │
│   │   │  corey-router   │────────▶│  corey-coder / qwen3.8          │   │   │
│   │   │  (AI Gateway)   │         │  (LLM for recommendations)      │   │   │
│   │   │  :8081          │         │                                 │   │   │
│   │   └─────────────────┘         └─────────────────────────────────┘   │   │
│   │                                                                      │   │
│   │   Falls back to built-in CACHE_KNOWLEDGE if AI unavailable           │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘


                              DATA FLOW
                              ─────────

   User runs cleanup.sh/ps1          Claude Code calls MCP tool
            │                                   │
            ▼                                   ▼
   ┌────────────────────┐              ┌────────────────────┐
   │ 1. Load .env config│              │ 1. MCP server rcvs │
   │ 2. List drives     │              │    tool call       │
   │ 3. Scan selected   │              │ 2. Execute scan/   │
   │ 4. Display results │              │    explain/delete  │
   │ 5. User selects    │              │ 3. Return results  │
   │ 6. Delete/Archive  │              │    to Claude       │
   └────────────────────┘              └────────────────────┘


                           SAFETY LEVELS
                           ─────────────

   ┌───────────┬─────────┬────────────────────────────────────────┐
   │  Level    │  Color  │  Meaning                               │
   ├───────────┼─────────┼────────────────────────────────────────┤
   │  [SAFE]   │  Green  │  100% safe, auto-regenerates           │
   │           │         │  e.g., node_modules, .next, __pycache__│
   ├───────────┼─────────┼────────────────────────────────────────┤
   │ [CAUTION] │  Yellow │  Usually safe, verify first            │
   │           │         │  e.g., Docker, browser cache           │
   ├───────────┼─────────┼────────────────────────────────────────┤
   │  [REVIEW] │  Red    │  Check before deleting                 │
   │           │         │  e.g., .venv, Downloads, iOS backups   │
   └───────────┴─────────┴────────────────────────────────────────┘
```

## Features

| Feature | Description |
|---------|-------------|
| **Drive Selection** | Interactive list of volumes and quick-scan locations |
| **50+ Cache Types** | JavaScript, Python, iOS, Android, Rust, Go, .NET, and more |
| **Safety Levels** | `[SAFE]`, `[CAUTION]`, `[REVIEW]` categories |
| **Archive Mode** | Move to archive instead of permanent delete |
| **AI-Powered** | Ask corey-coder about any cache or disk question |
| **MCP Integration** | Use from Claude Code or any MCP-compatible client |
| **Cross-Platform** | macOS, Linux, Windows (PowerShell) |
| **Configuration** | .env file support with multiple locations |

## File Structure

```
free-space-available/
├── src/
│   ├── __init__.py
│   ├── cleanup.sh           # Bash script (macOS/Linux) - 967 lines
│   ├── cleanup.ps1          # PowerShell script (Windows) - 580 lines
│   └── corey_integration.py # Python AI module - 500+ lines
├── mcp/
│   ├── __init__.py
│   └── server.py            # MCP server for Claude Code - 420 lines
├── .env.example             # Configuration template
├── .gitignore
├── pyproject.toml           # Python package config
└── README.md
```

## Quick Start

### macOS / Linux

```bash
# Clone the repo
git clone https://github.com/Hawaiideveloper/free-space-available.git
cd free-space-available

# Run directly
./src/cleanup.sh

# Or link to ~/bin for easy access
ln -sf "$(pwd)/src/cleanup.sh" ~/bin/cleanup-dev-caches.sh
chmod +x src/cleanup.sh
```

### Windows (PowerShell)

```powershell
# Clone the repo
git clone https://github.com/Hawaiideveloper/free-space-available.git
cd free-space-available

# Run directly
.\src\cleanup.ps1

# Or create a function in your PowerShell profile
# Add to $PROFILE:
# function cleanup { & "C:\path\to\free-space-available\src\cleanup.ps1" @args }
```

### Python Package

```bash
# Install as Python package
pip install -e .

# Use the Python API
python -c "from src.corey_integration import CoreyCleanupAdvisor; print(CoreyCleanupAdvisor().explain('node_modules'))"
```

## Configuration

Copy `.env.example` to `.env` and customize:

```bash
cp .env.example .env
```

### Configuration Locations (first found wins)

1. `<repo>/.env`
2. `~/.cleanup-dev-caches.env`
3. `~/.config/free-space-available/.env`

### All Settings

| Setting | Default | Description |
|---------|---------|-------------|
| **Scan Settings** | | |
| `SCAN_PATHS` | `~/Documents/github,~` | Default scan locations (comma-separated) |
| `SCAN_ENTIRE_MACHINE` | `false` | Scan all drives/volumes |
| `MIN_AGE_DAYS` | `0` | Only include files older than N days |
| `MIN_SIZE_KB` | `100` | Minimum size to report |
| **Archive Settings** | | |
| `ARCHIVE_MODE` | `false` | Move to archive instead of delete |
| `ARCHIVE_DIR` | `~/.cleanup-archive` | Archive storage location |
| `ARCHIVE_COMPRESS` | `true` | Compress archives (.tar.gz / .zip) |
| `ARCHIVE_RETENTION_DAYS` | `30` | Auto-delete archives older than N days |
| **AI Settings** | | |
| `AI_ENABLED` | `true` | Enable corey-coder queries |
| `COREY_ENDPOINT` | `http://corey-router...` | corey-router API endpoint |
| `COREY_MODEL` | `corey-coder:latest` | Primary model |
| `COREY_FALLBACK_MODEL` | `qwen3.8:latest` | Fallback model |
| **Safety Settings** | | |
| `SAFE_MODE_ONLY` | `false` | Only delete SAFE items |
| `REQUIRE_CONFIRMATION` | `true` | Prompt before deleting |
| `DRY_RUN_DEFAULT` | `false` | Preview-only by default |
| **Other** | | |
| `EXCLUDE_PATHS` | `**/node_modules/**/node_modules,**/.git` | Paths to skip |
| `LOG_FILE` | `~/.cleanup-dev-caches.log` | Log file location |
| `LOG_LEVEL` | `INFO` | Log verbosity |

## Usage

### Interactive Mode (default)

```bash
./src/cleanup.sh     # macOS/Linux
.\src\cleanup.ps1    # Windows
```

**Flow:**
1. Shows available drives/volumes
2. You select where to scan
3. Displays categorized results with safety levels
4. You select what to delete (or `r` for recommended)
5. Confirms and executes

### Command Line Options

| Flag | Bash | PowerShell | Description |
|------|------|------------|-------------|
| Dry run | `--dry-run` | `-DryRun` | Preview only, no changes |
| Force | `--force` | `-Force` | Skip confirmations, delete SAFE |
| Full scan | `--full` | `-Full` | Scan entire machine |
| Specific path | `--path ~/code` | `-Path "C:\code"` | Scan specific directory |
| Skip menu | `--scan` | `-Scan` | Use config paths, skip drive menu |
| Archive mode | `--archive` | `-Archive` | Move to archive |
| Show config | `--config` | `-Config` | Display current settings |
| Verbose | `--verbose` | `-Verbose` | Show all directories |
| Ask AI | `--ask "question"` | `-Ask "question"` | Ask corey-coder |
| Explain | `--explain N` | `-Explain N` | Explain item #N |

### Examples

```bash
# Preview what would be deleted
./src/cleanup.sh --dry-run

# Auto-delete all SAFE items without prompts
./src/cleanup.sh --force

# Scan entire machine
./src/cleanup.sh --full

# Archive instead of delete
./src/cleanup.sh --archive

# Ask the AI
./src/cleanup.sh --ask "Is it safe to delete Pods folders?"

# Show current config
./src/cleanup.sh --config
```

### Archive Mode

Instead of permanent deletion, move files to a timestamped archive:

```bash
# Enable via CLI
./src/cleanup.sh --archive

# Or set in .env
ARCHIVE_MODE=true
ARCHIVE_DIR=/Volumes/Backup/cleanup-archive
```

Archives are:
- Named with timestamp: `20261028_143022_node_modules.tar.gz`
- Compressed by default (`.tar.gz` on Unix, `.zip` on Windows)
- Auto-deleted after `ARCHIVE_RETENTION_DAYS`

## Python API

```python
from src.corey_integration import CoreyCleanupAdvisor, SafetyLevel

# Create advisor (reads .env automatically)
advisor = CoreyCleanupAdvisor()

# Ask questions
answer = advisor.ask("What's using the most space on a dev machine?")

# Explain cache types
explanation = advisor.explain("DerivedData")

# Get safety level
safety = advisor.get_safety("node_modules")  # SafetyLevel.SAFE

# Analyze scan results with recommendations
recommendations = advisor.analyze_scan([
    {"type": "node_modules", "size_bytes": 5_000_000_000, "path": "/code/app1"},
    {"type": ".venv", "size_bytes": 2_000_000_000, "path": "/code/app2"},
], disk_usage_percent=92.5)
```

## MCP Server (Claude Code)

Add to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "free-space-available": {
      "command": "python",
      "args": ["-m", "mcp.server"],
      "cwd": "/path/to/free-space-available"
    }
  }
}
```

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `scan_disk` | Scan for deletable caches, returns categorized findings |
| `explain_cache` | Explain what a cache type is and if it's safe |
| `ask_cleanup` | Ask corey-coder any disk cleanup question |
| `delete_caches` | Delete specified cache types (supports dry_run) |
| `get_disk_usage` | Get current disk usage for a path |
| `list_cache_types` | List all known cache types with safety levels |

## What It Scans (50+ Types)

### JavaScript/Node
`node_modules`, `.next`, `.nuxt`, `.vite`, `.turbo`, `.parcel-cache`, `storybook-static`, `.jest-cache`, `bower_components`

### Python
`__pycache__`, `.venv`, `venv`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `*.egg-info`

### iOS/macOS
`Pods`, `DerivedData`, `Carthage`, `.build`, `CoreSimulator`, `Archives`, `iOS DeviceSupport`

### Android
`.gradle`, `.cxx`, `build`

### Rust
`target`, `src-tauri/target`

### Go
`go-build`, `go/pkg/mod`

### .NET
`bin`, `obj`, `packages`, `.nuget/packages`

### Ruby
`vendor/bundle`

### System Caches (macOS)
`~/.npm`, `~/.yarn/cache`, `~/.cargo/registry`, `~/Library/Caches/Homebrew`, `~/Library/Caches/pip`, `~/Library/Caches/CocoaPods`, `~/Library/Developer/Xcode/DerivedData`, JetBrains, VS Code, Playwright, Cypress, Spotify, Discord, Teams

### System Caches (Linux)
`~/.npm`, `~/.cache/pip`, `~/.cache/go-build`, `~/.config/Code/Cache`, `~/.cache/JetBrains`, `~/.cache/chromium`, `~/.local/share/Trash`

### System Caches (Windows)
`%APPDATA%\npm-cache`, `%LOCALAPPDATA%\pip\Cache`, `%USERPROFILE%\.nuget\packages`, `%APPDATA%\Code\Cache`, `%LOCALAPPDATA%\JetBrains`, `%TEMP%`, Recycle Bin

## Requirements

### CLI Scripts
- **macOS/Linux**: Bash 3.2+, standard Unix tools (find, du, df)
- **Windows**: PowerShell 5.1+

### Python Components
- Python 3.9+
- `httpx` >= 0.24.0
- `mcp` >= 0.1.0 (for MCP server)

Install Python dependencies:
```bash
pip install -e .
# Or just:
pip install httpx
```

## Contributing

1. Add new cache types to `scan_location()` in `cleanup.sh` or `Scan-Location` in `cleanup.ps1`
2. Add knowledge to `CACHE_KNOWLEDGE` dict in `corey_integration.py`
3. Test with `--dry-run` before committing
4. Update this README if adding new features

## License

MIT

---

**Repository:** https://github.com/Hawaiideveloper/free-space-available

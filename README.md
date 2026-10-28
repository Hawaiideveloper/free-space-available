# free-space-available

Smart disk cleanup for development machines, powered by corey-coder AI.

## Features

- **Drive Selection**: Lists available volumes and quick-scan locations
- **Comprehensive Scanning**: 50+ cache types across all major languages/tools
- **Safety Levels**: `[SAFE]`, `[CAUTION]`, `[REVIEW]` categories
- **AI-Powered**: Ask corey-coder about any cache type or disk question
- **MCP Integration**: Use from Claude Code or any MCP client
- **Interactive Menu**: Select exactly what to delete

## Quick Start

```bash
# Run the cleanup tool
~/bin/cleanup-dev-caches.sh

# Or use the repo version
./src/cleanup.sh
```

## Installation

```bash
# Link to ~/bin for easy access
ln -sf ~/Documents/github/free-space-available/src/cleanup.sh ~/bin/cleanup-dev-caches.sh

# Make executable
chmod +x ~/Documents/github/free-space-available/src/cleanup.sh
```

## Usage

### Interactive Mode (default)

```bash
cleanup-dev-caches.sh
```

1. Shows available drives/volumes
2. You select where to scan
3. Displays categorized results with safety levels
4. You select what to delete (or `r` for recommended)

### Command Line Options

```bash
cleanup-dev-caches.sh --dry-run      # Preview only
cleanup-dev-caches.sh --scan         # Skip drive menu
cleanup-dev-caches.sh --path ~/code  # Scan specific path
cleanup-dev-caches.sh --force        # Delete SAFE items automatically
cleanup-dev-caches.sh --verbose      # Show all directories
```

### AI Integration

```bash
# Ask corey-coder about disk cleanup
cleanup-dev-caches.sh --ask "Is it safe to delete .venv folders?"

# Explain a specific cache type
cleanup-dev-caches.sh --explain 5   # Explain item #5 from scan
```

### Python API

```python
from src.corey_integration import CoreyCleanupAdvisor

advisor = CoreyCleanupAdvisor()

# Ask questions
answer = advisor.ask("What's using the most space on a dev machine?")

# Get safety info
safety = advisor.get_safety("node_modules")  # SafetyLevel.SAFE

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

### System Caches
- `~/.npm` - npm global cache
- `~/.cargo/registry` - Rust crates
- `~/Library/Caches/Homebrew` - Homebrew
- `~/Library/Caches/pip` - pip
- Plus many more...

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GITHUB_DIR` | `~/Documents/github` | Default scan location |
| `COREY_ENDPOINT` | Cluster internal | corey-router endpoint |
| `COREY_MODEL` | `corey-coder:latest` | Model for AI queries |

## Architecture

```
free-space-available/
├── src/
│   ├── cleanup.sh          # Main bash script
│   └── corey_integration.py # Python AI integration
├── mcp/
│   └── server.py           # MCP server for Claude
├── docs/
│   └── cache-types.md      # Detailed cache documentation
└── tests/
    └── test_cleanup.py     # Tests
```

## Contributing

1. Add new cache types to `scan_location()` in `cleanup.sh`
2. Add knowledge to `CACHE_KNOWLEDGE` in `corey_integration.py`
3. Test with `--dry-run` before committing

## License

MIT

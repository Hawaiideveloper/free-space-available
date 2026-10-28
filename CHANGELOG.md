# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-28

### Added
- **Archive Mode**: Move files to archive instead of permanent deletion
  - `--archive` flag for CLI scripts
  - `ARCHIVE_MODE`, `ARCHIVE_DIR`, `ARCHIVE_COMPRESS` config options
  - Auto-cleanup of old archives via `ARCHIVE_RETENTION_DAYS`
- **MIN_AGE_DAYS filtering**: Only include files older than N days
  - Implemented in bash, PowerShell, and MCP server
  - Set via `MIN_AGE_DAYS` in .env
- **MCP Server enhancements**:
  - Archive mode support in `delete_caches` tool
  - New `get_config` tool to show current configuration
  - Reads .env configuration files
  - Age filtering via `min_age_days` parameter
- **Tests**: Added pytest test suite for `corey_integration.py`
- **CHANGELOG.md**: This file

### Changed
- MCP server version bumped to 1.1.0
- Scan results now show age in days for each item
- Config display now shows MIN_AGE_DAYS setting

### Fixed
- MIN_AGE_DAYS was defined but not implemented in scan logic

## [1.0.0] - 2026-10-28

### Added
- Initial release
- **Cross-platform support**: macOS, Linux, Windows (PowerShell)
- **Interactive CLI**: Drive selection, scan, menu-based deletion
- **50+ cache types**: JavaScript, Python, iOS, Android, Rust, Go, .NET, Ruby
- **Safety levels**: SAFE, CAUTION, REVIEW categories
- **AI integration**: corey-coder queries via corey-router
- **MCP server**: Claude Code integration with 6 tools
- **.env configuration**: Multiple config file locations
- **Python API**: `CoreyCleanupAdvisor` class

### CLI Scripts
- `cleanup.sh` - Bash script for macOS/Linux
- `cleanup.ps1` - PowerShell script for Windows

### MCP Tools
- `scan_disk` - Scan for deletable caches
- `explain_cache` - Explain what a cache type is
- `ask_cleanup` - Ask corey-coder questions
- `delete_caches` - Delete selected cache types
- `get_disk_usage` - Check disk usage
- `list_cache_types` - List known cache types

#!/usr/bin/env python3
"""
MCP Server for free-space-available.

Exposes disk cleanup functionality as MCP tools that can be used by
Claude Code, Claude Desktop, and other MCP clients.

Tools provided:
  - scan_disk: Scan for deletable caches
  - explain_cache: Explain what a cache type is
  - ask_cleanup: Ask questions about disk cleanup
  - delete_caches: Delete or archive selected cache types
  - get_disk_usage: Get current disk usage
  - list_cache_types: List all known cache types
  - get_config: Show current configuration

Configuration:
  Reads .env files from:
  1. <repo>/.env
  2. ~/.cleanup-dev-caches.env
  3. ~/.config/free-space-available/.env

To run:
    python -m mcp.server

Or add to Claude Code settings:
    {
      "mcpServers": {
        "free-space-available": {
          "command": "python",
          "args": ["-m", "mcp.server"],
          "cwd": "/path/to/free-space-available"
        }
      }
    }
"""

import os
import sys
import json
import subprocess
import shutil
import tarfile
from pathlib import Path
from datetime import datetime
from typing import Optional, List, Dict, Any

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from mcp.server import Server, NotificationOptions
from mcp.server.models import InitializationOptions
from mcp.types import Tool, TextContent, Resource, ResourceTemplate
import mcp.server.stdio

from corey_integration import (
    CoreyCleanupAdvisor, SafetyLevel, CACHE_KNOWLEDGE,
    load_env_file, ARCHIVE_MODE, ARCHIVE_DIR
)


# Load configuration from .env
_config = load_env_file()

# Configuration with defaults
CONFIG = {
    "SCAN_PATHS": _config.get("SCAN_PATHS", "~/Documents/github,~"),
    "MIN_SIZE_KB": int(_config.get("MIN_SIZE_KB", "100")),
    "MIN_AGE_DAYS": int(_config.get("MIN_AGE_DAYS", "0")),
    "ARCHIVE_MODE": _config.get("ARCHIVE_MODE", "false").lower() == "true",
    "ARCHIVE_DIR": _config.get("ARCHIVE_DIR", str(Path.home() / ".cleanup-archive")),
    "ARCHIVE_COMPRESS": _config.get("ARCHIVE_COMPRESS", "true").lower() == "true",
}

# Initialize MCP server
server = Server("free-space-available")
advisor = CoreyCleanupAdvisor()


def archive_directory(dir_path: str) -> str:
    """Archive a directory instead of deleting it."""
    archive_base = Path(CONFIG["ARCHIVE_DIR"]).expanduser()
    archive_base.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    basename = Path(dir_path).name

    if CONFIG["ARCHIVE_COMPRESS"]:
        archive_file = archive_base / f"{timestamp}_{basename}.tar.gz"
        with tarfile.open(archive_file, "w:gz") as tar:
            tar.add(dir_path, arcname=basename)
        shutil.rmtree(dir_path)
        return str(archive_file)
    else:
        archive_dest = archive_base / f"{timestamp}_{basename}"
        shutil.move(dir_path, archive_dest)
        return str(archive_dest)


def get_file_age_days(path: str) -> int:
    """Get age of a file/directory in days."""
    try:
        mtime = os.path.getmtime(path)
        age_seconds = datetime.now().timestamp() - mtime
        return int(age_seconds / 86400)
    except:
        return 0


@server.list_tools()
async def list_tools() -> List[Tool]:
    """List available tools."""
    return [
        Tool(
            name="scan_disk",
            description="Scan a directory for deletable caches and build artifacts. Returns categorized findings with safety levels.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to scan (default: ~/Documents/github)"
                    },
                    "include_system": {
                        "type": "boolean",
                        "description": "Include system-level caches like npm, pip, Xcode (default: true)"
                    },
                    "min_age_days": {
                        "type": "integer",
                        "description": "Only include files older than N days (default: from config)"
                    }
                }
            }
        ),
        Tool(
            name="explain_cache",
            description="Explain what a cache type is, whether it's safe to delete, and how to regenerate it.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cache_type": {
                        "type": "string",
                        "description": "Cache type to explain (e.g., 'node_modules', '.venv', 'DerivedData')"
                    }
                },
                "required": ["cache_type"]
            }
        ),
        Tool(
            name="ask_cleanup",
            description="Ask corey-coder any question about disk cleanup, caches, or disk usage.",
            inputSchema={
                "type": "object",
                "properties": {
                    "question": {
                        "type": "string",
                        "description": "Question to ask"
                    }
                },
                "required": ["question"]
            }
        ),
        Tool(
            name="delete_caches",
            description="Delete or archive specific cache types. Supports archive mode to move files instead of permanent deletion.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cache_types": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "List of cache types to delete"
                    },
                    "path": {
                        "type": "string",
                        "description": "Base path to search in"
                    },
                    "dry_run": {
                        "type": "boolean",
                        "description": "If true, only show what would be deleted/archived"
                    },
                    "archive": {
                        "type": "boolean",
                        "description": "If true, archive instead of delete (default: from config)"
                    }
                },
                "required": ["cache_types"]
            }
        ),
        Tool(
            name="get_disk_usage",
            description="Get current disk usage for the home directory or a specific path.",
            inputSchema={
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Path to check (default: home directory)"
                    }
                }
            }
        ),
        Tool(
            name="list_cache_types",
            description="List all known cache types with their safety levels.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        Tool(
            name="get_config",
            description="Show current configuration from .env file.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: Dict[str, Any]) -> List[TextContent]:
    """Handle tool calls."""

    if name == "scan_disk":
        return await scan_disk(
            arguments.get("path", os.path.expanduser("~/Documents/github")),
            arguments.get("include_system", True),
            arguments.get("min_age_days", CONFIG["MIN_AGE_DAYS"])
        )

    elif name == "explain_cache":
        return await explain_cache(arguments["cache_type"])

    elif name == "ask_cleanup":
        return await ask_cleanup(arguments["question"])

    elif name == "delete_caches":
        return await delete_caches(
            arguments["cache_types"],
            arguments.get("path", os.path.expanduser("~/Documents/github")),
            arguments.get("dry_run", False),
            arguments.get("archive", CONFIG["ARCHIVE_MODE"])
        )

    elif name == "get_disk_usage":
        return await get_disk_usage(
            arguments.get("path", os.path.expanduser("~"))
        )

    elif name == "list_cache_types":
        return await list_cache_types()

    elif name == "get_config":
        return await get_config()

    else:
        return [TextContent(type="text", text=f"Unknown tool: {name}")]


async def scan_disk(path: str, include_system: bool, min_age_days: int) -> List[TextContent]:
    """Scan for deletable caches."""
    results = []
    total_size = 0

    path = os.path.expanduser(path)
    min_size_kb = CONFIG["MIN_SIZE_KB"]

    # Patterns to scan for
    patterns = [
        ("node_modules", "node_modules", SafetyLevel.SAFE),
        (".next", ".next", SafetyLevel.SAFE),
        (".nuxt", ".nuxt", SafetyLevel.SAFE),
        (".vite", ".vite", SafetyLevel.SAFE),
        (".turbo", ".turbo", SafetyLevel.SAFE),
        (".parcel-cache", ".parcel-cache", SafetyLevel.SAFE),
        ("__pycache__", "__pycache__", SafetyLevel.SAFE),
        (".pytest_cache", ".pytest_cache", SafetyLevel.SAFE),
        (".mypy_cache", ".mypy_cache", SafetyLevel.SAFE),
        ("Pods", "Pods", SafetyLevel.SAFE),
        (".gradle", ".gradle", SafetyLevel.SAFE),
        ("target", "target", SafetyLevel.SAFE),
        (".cxx", ".cxx", SafetyLevel.SAFE),
        ("bin", "bin", SafetyLevel.SAFE),
        ("obj", "obj", SafetyLevel.SAFE),
        (".venv", ".venv", SafetyLevel.REVIEW),
        ("venv", "venv", SafetyLevel.REVIEW),
    ]

    for name, pattern, safety in patterns:
        try:
            result = subprocess.run(
                ["find", path, "-name", pattern, "-type", "d", "-prune"],
                capture_output=True, text=True, timeout=60
            )
            for dir_path in result.stdout.strip().split("\n"):
                if dir_path and os.path.isdir(dir_path):
                    # Check age filter
                    if min_age_days > 0:
                        age = get_file_age_days(dir_path)
                        if age < min_age_days:
                            continue

                    try:
                        size = subprocess.run(
                            ["du", "-sk", dir_path],
                            capture_output=True, text=True, timeout=30
                        )
                        size_kb = int(size.stdout.split()[0])
                        if size_kb > min_size_kb:
                            results.append({
                                "type": name,
                                "path": dir_path,
                                "size_kb": size_kb,
                                "safety": safety.name,
                                "age_days": get_file_age_days(dir_path)
                            })
                            total_size += size_kb
                    except:
                        pass
        except:
            pass

    # System caches
    if include_system:
        system_dirs = [
            ("npm cache", os.path.expanduser("~/.npm"), SafetyLevel.SAFE),
            ("yarn cache", os.path.expanduser("~/.yarn/cache"), SafetyLevel.SAFE),
            ("pip cache", os.path.expanduser("~/Library/Caches/pip"), SafetyLevel.SAFE),
            ("pip cache", os.path.expanduser("~/.cache/pip"), SafetyLevel.SAFE),
            ("Xcode DerivedData", os.path.expanduser("~/Library/Developer/Xcode/DerivedData"), SafetyLevel.SAFE),
            ("Homebrew cache", os.path.expanduser("~/Library/Caches/Homebrew"), SafetyLevel.SAFE),
            ("CocoaPods cache", os.path.expanduser("~/Library/Caches/CocoaPods"), SafetyLevel.SAFE),
            ("Cargo registry", os.path.expanduser("~/.cargo/registry"), SafetyLevel.SAFE),
            ("Go modules", os.path.expanduser("~/go/pkg/mod"), SafetyLevel.SAFE),
            ("Gradle cache", os.path.expanduser("~/.gradle/caches"), SafetyLevel.SAFE),
        ]

        for name, dir_path, safety in system_dirs:
            if os.path.isdir(dir_path):
                # Check age filter
                if min_age_days > 0:
                    age = get_file_age_days(dir_path)
                    if age < min_age_days:
                        continue

                try:
                    size = subprocess.run(
                        ["du", "-sk", dir_path],
                        capture_output=True, text=True, timeout=30
                    )
                    size_kb = int(size.stdout.split()[0])
                    if size_kb > min_size_kb:
                        results.append({
                            "type": name,
                            "path": dir_path,
                            "size_kb": size_kb,
                            "safety": safety.name,
                            "age_days": get_file_age_days(dir_path)
                        })
                        total_size += size_kb
                except:
                    pass

    # Format output
    output = f"# Scan Results\n\n"
    output += f"**Total reclaimable:** {total_size / 1024:.1f} MB\n"
    if min_age_days > 0:
        output += f"**Filter:** Only items older than {min_age_days} days\n"
    output += f"**Mode:** {'Archive' if CONFIG['ARCHIVE_MODE'] else 'Delete'}\n\n"

    # Group by safety
    safe = [r for r in results if r["safety"] == "SAFE"]
    caution = [r for r in results if r["safety"] == "CAUTION"]
    review = [r for r in results if r["safety"] == "REVIEW"]

    if safe:
        safe_total = sum(r["size_kb"] for r in safe) / 1024
        output += f"## SAFE to delete ({safe_total:.1f} MB)\n"
        for r in sorted(safe, key=lambda x: -x["size_kb"])[:10]:
            output += f"- {r['type']}: {r['size_kb']/1024:.1f} MB ({r['age_days']}d old)\n"
        output += "\n"

    if caution:
        caution_total = sum(r["size_kb"] for r in caution) / 1024
        output += f"## CAUTION ({caution_total:.1f} MB)\n"
        for r in sorted(caution, key=lambda x: -x["size_kb"])[:5]:
            output += f"- {r['type']}: {r['size_kb']/1024:.1f} MB ({r['age_days']}d old)\n"
        output += "\n"

    if review:
        review_total = sum(r["size_kb"] for r in review) / 1024
        output += f"## REVIEW before deleting ({review_total:.1f} MB)\n"
        for r in sorted(review, key=lambda x: -x["size_kb"])[:5]:
            output += f"- {r['type']}: {r['size_kb']/1024:.1f} MB ({r['age_days']}d old)\n"

    return [TextContent(type="text", text=output)]


async def explain_cache(cache_type: str) -> List[TextContent]:
    """Explain a cache type."""
    explanation = advisor.explain(cache_type)
    return [TextContent(type="text", text=explanation)]


async def ask_cleanup(question: str) -> List[TextContent]:
    """Ask corey-coder a question."""
    answer = advisor.ask(question)
    return [TextContent(type="text", text=answer)]


async def delete_caches(
    cache_types: List[str],
    path: str,
    dry_run: bool,
    archive: bool
) -> List[TextContent]:
    """Delete or archive specified cache types."""
    path = os.path.expanduser(path)
    results = []
    total_freed = 0
    action = "archive" if archive else "delete"

    for cache_type in cache_types:
        # Find directories matching this type
        try:
            result = subprocess.run(
                ["find", path, "-name", cache_type, "-type", "d", "-prune"],
                capture_output=True, text=True, timeout=60
            )
            for dir_path in result.stdout.strip().split("\n"):
                if dir_path and os.path.isdir(dir_path):
                    try:
                        size = subprocess.run(
                            ["du", "-sk", dir_path],
                            capture_output=True, text=True, timeout=30
                        )
                        size_kb = int(size.stdout.split()[0])

                        if dry_run:
                            results.append(f"Would {action}: {dir_path} ({size_kb/1024:.1f} MB)")
                        else:
                            if archive:
                                archive_dest = archive_directory(dir_path)
                                results.append(f"Archived: {dir_path} -> {archive_dest} ({size_kb/1024:.1f} MB)")
                            else:
                                shutil.rmtree(dir_path)
                                results.append(f"Deleted: {dir_path} ({size_kb/1024:.1f} MB)")

                        total_freed += size_kb
                    except Exception as e:
                        results.append(f"Error with {dir_path}: {e}")
        except:
            pass

    output = f"# {'Archive' if archive else 'Deletion'} Results\n\n"
    if dry_run:
        output += f"**DRY RUN - No files actually {'archived' if archive else 'deleted'}**\n\n"

    output += f"**Space freed:** {total_freed/1024:.1f} MB\n"
    if archive and not dry_run:
        output += f"**Archive location:** {CONFIG['ARCHIVE_DIR']}\n"
    output += "\n"

    for item in results:
        output += f"- {item}\n"

    return [TextContent(type="text", text=output)]


async def get_disk_usage(path: str) -> List[TextContent]:
    """Get disk usage."""
    path = os.path.expanduser(path)

    try:
        result = subprocess.run(
            ["df", "-h", path],
            capture_output=True, text=True
        )
        lines = result.stdout.strip().split("\n")
        if len(lines) >= 2:
            parts = lines[1].split()
            output = f"""# Disk Usage

- **Filesystem:** {parts[0]}
- **Size:** {parts[1]}
- **Used:** {parts[2]}
- **Available:** {parts[3]}
- **Capacity:** {parts[4]}
- **Mount:** {' '.join(parts[8:]) if len(parts) > 8 else parts[-1]}
"""
            return [TextContent(type="text", text=output)]
    except:
        pass

    return [TextContent(type="text", text="Unable to get disk usage")]


async def list_cache_types() -> List[TextContent]:
    """List all known cache types."""
    output = "# Known Cache Types\n\n"

    output += "## SAFE (auto-regenerates)\n"
    for name, info in CACHE_KNOWLEDGE.items():
        if info["safety"] == SafetyLevel.SAFE:
            output += f"- **{name}**: {info['description']}\n"

    output += "\n## CAUTION (usually safe)\n"
    for name, info in CACHE_KNOWLEDGE.items():
        if info["safety"] == SafetyLevel.CAUTION:
            output += f"- **{name}**: {info['description']}\n"

    output += "\n## REVIEW (check first)\n"
    for name, info in CACHE_KNOWLEDGE.items():
        if info["safety"] == SafetyLevel.REVIEW:
            output += f"- **{name}**: {info['description']}\n"

    return [TextContent(type="text", text=output)]


async def get_config() -> List[TextContent]:
    """Show current configuration."""
    output = "# Current Configuration\n\n"
    output += "Settings loaded from .env file:\n\n"

    for key, value in CONFIG.items():
        output += f"- **{key}**: `{value}`\n"

    output += "\n## Config file locations (first found wins):\n"
    output += "1. `<repo>/.env`\n"
    output += "2. `~/.cleanup-dev-caches.env`\n"
    output += "3. `~/.config/free-space-available/.env`\n"

    return [TextContent(type="text", text=output)]


async def main():
    """Run the MCP server."""
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="free-space-available",
                server_version="1.1.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={}
                )
            )
        )


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())

#!/usr/bin/env python3
"""
MCP Server for free-space-available.

Exposes disk cleanup functionality as MCP tools that can be used by
Claude Code, Claude Desktop, and other MCP clients.

Tools provided:
  - scan_disk: Scan for deletable caches
  - explain_cache: Explain what a cache type is
  - ask_cleanup: Ask questions about disk cleanup
  - delete_caches: Delete selected cache types
  - get_disk_usage: Get current disk usage

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
from pathlib import Path
from typing import Optional, List, Dict, Any

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from mcp.server import Server, NotificationOptions
from mcp.server.models import InitializationOptions
from mcp.types import Tool, TextContent, Resource, ResourceTemplate
import mcp.server.stdio

from corey_integration import CoreyCleanupAdvisor, SafetyLevel, CACHE_KNOWLEDGE


# Initialize MCP server
server = Server("free-space-available")
advisor = CoreyCleanupAdvisor()


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
            description="Delete specific cache types. Use with caution - verify safety level first.",
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
                        "description": "If true, only show what would be deleted"
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
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: Dict[str, Any]) -> List[TextContent]:
    """Handle tool calls."""

    if name == "scan_disk":
        return await scan_disk(
            arguments.get("path", os.path.expanduser("~/Documents/github")),
            arguments.get("include_system", True)
        )

    elif name == "explain_cache":
        return await explain_cache(arguments["cache_type"])

    elif name == "ask_cleanup":
        return await ask_cleanup(arguments["question"])

    elif name == "delete_caches":
        return await delete_caches(
            arguments["cache_types"],
            arguments.get("path", os.path.expanduser("~/Documents/github")),
            arguments.get("dry_run", False)
        )

    elif name == "get_disk_usage":
        return await get_disk_usage(
            arguments.get("path", os.path.expanduser("~"))
        )

    elif name == "list_cache_types":
        return await list_cache_types()

    else:
        return [TextContent(type="text", text=f"Unknown tool: {name}")]


async def scan_disk(path: str, include_system: bool) -> List[TextContent]:
    """Scan for deletable caches."""
    results = []
    total_size = 0

    path = os.path.expanduser(path)

    # Patterns to scan for
    patterns = [
        ("node_modules", "node_modules", SafetyLevel.SAFE),
        (".next", ".next", SafetyLevel.SAFE),
        ("__pycache__", "__pycache__", SafetyLevel.SAFE),
        ("Pods", "Pods", SafetyLevel.SAFE),
        (".gradle", ".gradle", SafetyLevel.SAFE),
        ("target", "target", SafetyLevel.SAFE),
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
                    try:
                        size = subprocess.run(
                            ["du", "-sk", dir_path],
                            capture_output=True, text=True, timeout=30
                        )
                        size_kb = int(size.stdout.split()[0])
                        if size_kb > 100:  # Skip tiny dirs
                            results.append({
                                "type": name,
                                "path": dir_path,
                                "size_kb": size_kb,
                                "safety": safety.name
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
            ("pip cache", os.path.expanduser("~/Library/Caches/pip"), SafetyLevel.SAFE),
            ("Xcode DerivedData", os.path.expanduser("~/Library/Developer/Xcode/DerivedData"), SafetyLevel.SAFE),
            ("Homebrew cache", os.path.expanduser("~/Library/Caches/Homebrew"), SafetyLevel.SAFE),
        ]

        for name, dir_path, safety in system_dirs:
            if os.path.isdir(dir_path):
                try:
                    size = subprocess.run(
                        ["du", "-sk", dir_path],
                        capture_output=True, text=True, timeout=30
                    )
                    size_kb = int(size.stdout.split()[0])
                    if size_kb > 100:
                        results.append({
                            "type": name,
                            "path": dir_path,
                            "size_kb": size_kb,
                            "safety": safety.name
                        })
                        total_size += size_kb
                except:
                    pass

    # Format output
    output = f"# Scan Results\n\n"
    output += f"**Total reclaimable:** {total_size / 1024:.1f} MB\n\n"

    # Group by safety
    safe = [r for r in results if r["safety"] == "SAFE"]
    caution = [r for r in results if r["safety"] == "CAUTION"]
    review = [r for r in results if r["safety"] == "REVIEW"]

    if safe:
        safe_total = sum(r["size_kb"] for r in safe) / 1024
        output += f"## SAFE to delete ({safe_total:.1f} MB)\n"
        for r in sorted(safe, key=lambda x: -x["size_kb"])[:10]:
            output += f"- {r['type']}: {r['size_kb']/1024:.1f} MB\n"
        output += "\n"

    if caution:
        caution_total = sum(r["size_kb"] for r in caution) / 1024
        output += f"## CAUTION ({caution_total:.1f} MB)\n"
        for r in sorted(caution, key=lambda x: -x["size_kb"])[:5]:
            output += f"- {r['type']}: {r['size_kb']/1024:.1f} MB\n"
        output += "\n"

    if review:
        review_total = sum(r["size_kb"] for r in review) / 1024
        output += f"## REVIEW before deleting ({review_total:.1f} MB)\n"
        for r in sorted(review, key=lambda x: -x["size_kb"])[:5]:
            output += f"- {r['type']}: {r['size_kb']/1024:.1f} MB\n"

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
    dry_run: bool
) -> List[TextContent]:
    """Delete specified cache types."""
    path = os.path.expanduser(path)
    deleted = []
    total_freed = 0

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
                            deleted.append(f"Would delete: {dir_path} ({size_kb/1024:.1f} MB)")
                        else:
                            shutil.rmtree(dir_path)
                            deleted.append(f"Deleted: {dir_path} ({size_kb/1024:.1f} MB)")

                        total_freed += size_kb
                    except Exception as e:
                        deleted.append(f"Error with {dir_path}: {e}")
        except:
            pass

    output = "# Deletion Results\n\n"
    if dry_run:
        output += "**DRY RUN - No files actually deleted**\n\n"

    output += f"**Space freed:** {total_freed/1024:.1f} MB\n\n"
    for item in deleted:
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


async def main():
    """Run the MCP server."""
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="free-space-available",
                server_version="1.0.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={}
                )
            )
        )


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())

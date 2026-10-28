#!/usr/bin/env python3
"""
Corey-coder integration for free-space-available.

This module provides intelligent disk cleanup recommendations by querying
corey-coder (our fine-tuned LLM) for context-aware decisions.

Supports macOS, Linux, and Windows. Reads configuration from .env files.

Usage:
    from corey_integration import CoreyCleanupAdvisor

    advisor = CoreyCleanupAdvisor()

    # Ask about a specific cache type
    response = advisor.explain("node_modules")

    # Get recommendations based on scan results
    recommendations = advisor.analyze_scan(scan_results)

    # Ask a free-form question
    answer = advisor.ask("Is it safe to delete .venv folders?")

Configuration:
    Reads settings from .env files in this order:
    1. <repo>/.env
    2. ~/.cleanup-dev-caches.env
    3. ~/.config/free-space-available/.env

    Key settings:
    - COREY_ENDPOINT: corey-router API endpoint
    - COREY_MODEL: Primary model to use
    - COREY_FALLBACK_MODEL: Fallback model
    - AI_ENABLED: Enable/disable AI queries
    - ARCHIVE_MODE: Archive instead of delete
    - ARCHIVE_DIR: Where to store archives
"""

import os
import sys
import json
import subprocess
from pathlib import Path
from typing import Optional, Dict, List, Any
from dataclasses import dataclass
from enum import Enum
import httpx


def load_env_file() -> Dict[str, str]:
    """Load configuration from .env files."""
    config = {}

    # Determine script/repo directory
    script_dir = Path(__file__).parent
    repo_dir = script_dir.parent

    # Check multiple locations
    env_paths = [
        repo_dir / ".env",
        Path.home() / ".cleanup-dev-caches.env",
        Path.home() / ".config" / "free-space-available" / ".env",
    ]

    for env_path in env_paths:
        if env_path.exists():
            with open(env_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith('#'):
                        continue
                    if '=' in line:
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip().strip('"').strip("'")
                        # Expand ~ to home directory
                        if value.startswith('~'):
                            value = str(Path.home()) + value[1:]
                        config[key] = value
            break  # Use first found

    return config


# Load configuration
_ENV_CONFIG = load_env_file()

# Configuration with .env override
COREY_ENDPOINT = _ENV_CONFIG.get(
    "COREY_ENDPOINT",
    os.getenv("COREY_ENDPOINT", "http://corey-router.corey-coder.svc.cluster.local:8081")
)
COREY_MODEL = _ENV_CONFIG.get(
    "COREY_MODEL",
    os.getenv("COREY_MODEL", "corey-coder:latest")
)
FALLBACK_MODEL = _ENV_CONFIG.get(
    "COREY_FALLBACK_MODEL",
    os.getenv("COREY_FALLBACK_MODEL", "qwen3.8:latest")
)
AI_ENABLED = _ENV_CONFIG.get("AI_ENABLED", "true").lower() == "true"
ARCHIVE_MODE = _ENV_CONFIG.get("ARCHIVE_MODE", "false").lower() == "true"
ARCHIVE_DIR = _ENV_CONFIG.get("ARCHIVE_DIR", str(Path.home() / ".cleanup-archive"))


class SafetyLevel(Enum):
    SAFE = 1        # 100% safe to delete, auto-regenerates
    CAUTION = 2     # Usually safe, but verify
    REVIEW = 3      # Check before deleting


@dataclass
class CacheInfo:
    """Information about a cache type."""
    name: str
    safety: SafetyLevel
    size_bytes: int
    path: str
    description: str
    regenerate_command: Optional[str] = None


# Built-in knowledge base (used when corey-coder unavailable)
CACHE_KNOWLEDGE = {
    "node_modules": {
        "safety": SafetyLevel.SAFE,
        "description": "NPM/Yarn package dependencies",
        "regenerate": "npm install",
        "explanation": "Contains downloaded JavaScript packages. 100% safe to delete - regenerates with 'npm install' or 'yarn install'."
    },
    ".next": {
        "safety": SafetyLevel.SAFE,
        "description": "Next.js build output and cache",
        "regenerate": "npm run build",
        "explanation": "Next.js compiled output. Safe to delete - rebuilds automatically on 'npm run dev' or 'npm run build'."
    },
    "__pycache__": {
        "safety": SafetyLevel.SAFE,
        "description": "Python bytecode cache",
        "regenerate": "automatic on import",
        "explanation": "Compiled Python files (.pyc). Completely safe - Python recreates these automatically."
    },
    ".venv": {
        "safety": SafetyLevel.REVIEW,
        "description": "Python virtual environment",
        "regenerate": "python -m venv .venv && pip install -r requirements.txt",
        "explanation": "Contains installed Python packages. Usually has requirements.txt backup, but verify first. May have custom packages not in requirements."
    },
    "Pods": {
        "safety": SafetyLevel.SAFE,
        "description": "CocoaPods iOS dependencies",
        "regenerate": "pod install",
        "explanation": "iOS dependency cache. Safe to delete - regenerates with 'pod install'."
    },
    "DerivedData": {
        "safety": SafetyLevel.SAFE,
        "description": "Xcode build cache",
        "regenerate": "automatic on build",
        "explanation": "Xcode compilation artifacts. Safe to delete - Xcode rebuilds everything as needed."
    },
    ".gradle": {
        "safety": SafetyLevel.SAFE,
        "description": "Gradle build cache",
        "regenerate": "automatic on build",
        "explanation": "Android/Java build cache. Safe to delete - Gradle downloads and rebuilds automatically."
    },
    "target": {
        "safety": SafetyLevel.SAFE,
        "description": "Rust/Cargo build artifacts",
        "regenerate": "cargo build",
        "explanation": "Compiled Rust binaries and intermediate files. Safe to delete - cargo rebuilds on demand."
    },
    ".npm": {
        "safety": SafetyLevel.SAFE,
        "description": "npm global cache",
        "regenerate": "automatic on install",
        "explanation": "npm's content-addressable cache. Safe to delete - npm re-downloads packages as needed."
    },
    "Docker": {
        "safety": SafetyLevel.CAUTION,
        "description": "Docker images, containers, volumes",
        "regenerate": "docker pull / docker build",
        "explanation": "Docker data can be large. Images can be re-pulled, but volumes may contain important data. Use 'docker system prune -a' carefully."
    },
    "Downloads": {
        "safety": SafetyLevel.REVIEW,
        "description": "User downloads folder",
        "regenerate": "re-download from source",
        "explanation": "Contains user-downloaded files. Review carefully - some may be important or hard to re-download."
    },
    "Trash": {
        "safety": SafetyLevel.REVIEW,
        "description": "Deleted files",
        "regenerate": "not possible",
        "explanation": "Files you've deleted. Review before emptying - this is your last chance to recover them."
    },
    "iOS backups": {
        "safety": SafetyLevel.REVIEW,
        "description": "iPhone/iPad backups",
        "regenerate": "backup device again",
        "explanation": "Mobile device backups. May be your only copy of important data. Only delete if you have iCloud backup or don't need the data."
    },
    # Windows-specific caches
    "npm-cache": {
        "safety": SafetyLevel.SAFE,
        "description": "npm global cache (Windows)",
        "regenerate": "automatic on install",
        "explanation": "npm's Windows cache in AppData. Safe to delete - npm re-downloads packages as needed."
    },
    "NuGet": {
        "safety": SafetyLevel.SAFE,
        "description": "NuGet package cache",
        "regenerate": "dotnet restore",
        "explanation": ".NET package cache. Safe to delete - NuGet downloads packages on build/restore."
    },
    "VS Code cache": {
        "safety": SafetyLevel.SAFE,
        "description": "Visual Studio Code cache",
        "regenerate": "automatic",
        "explanation": "VS Code extension and runtime cache. Safe to delete - regenerates on startup."
    },
    "Chrome cache": {
        "safety": SafetyLevel.CAUTION,
        "description": "Chrome browser cache",
        "regenerate": "automatic on browse",
        "explanation": "Chrome's browsing cache. Usually safe, but may slow down browsing temporarily after deletion."
    },
    "Edge cache": {
        "safety": SafetyLevel.CAUTION,
        "description": "Edge browser cache",
        "regenerate": "automatic on browse",
        "explanation": "Edge's browsing cache. Usually safe, but may slow down browsing temporarily after deletion."
    },
    "Windows Temp": {
        "safety": SafetyLevel.CAUTION,
        "description": "Windows temporary files",
        "regenerate": "automatic",
        "explanation": "System and app temp files. Usually safe but some apps may be using them. Close apps first."
    },
    "Recycle Bin": {
        "safety": SafetyLevel.REVIEW,
        "description": "Windows Recycle Bin",
        "regenerate": "not possible",
        "explanation": "Deleted files waiting for permanent removal. Review before emptying - this is your last chance to recover them."
    }
}


class CoreyCleanupAdvisor:
    """
    AI-powered cleanup advisor using corey-coder.

    Provides intelligent recommendations about what's safe to delete,
    explanations of cache types, and answers to disk cleanup questions.
    """

    def __init__(
        self,
        endpoint: str = COREY_ENDPOINT,
        model: str = COREY_MODEL,
        fallback_model: str = FALLBACK_MODEL,
        timeout: float = 30.0
    ):
        self.endpoint = endpoint
        self.model = model
        self.fallback_model = fallback_model
        self.timeout = timeout
        self._client = None

    @property
    def client(self) -> httpx.Client:
        if self._client is None:
            self._client = httpx.Client(timeout=self.timeout)
        return self._client

    def _query_corey(
        self,
        prompt: str,
        system_prompt: Optional[str] = None,
        max_tokens: int = 500
    ) -> Optional[str]:
        """Query corey-coder via corey-router."""

        # Check if AI is enabled
        if not AI_ENABLED:
            return None

        if system_prompt is None:
            system_prompt = """You are a disk cleanup expert for macOS, Linux, and Windows development machines.
You help users understand what files and caches are safe to delete.
Be concise, direct, and technically accurate.
Always mention if something can be regenerated and how."""

        try:
            response = self.client.post(
                f"{self.endpoint}/v1/chat/completions",
                json={
                    "model": self.model,
                    "messages": [
                        {"role": "system", "content": system_prompt},
                        {"role": "user", "content": prompt}
                    ],
                    "max_tokens": max_tokens,
                    "temperature": 0.3
                }
            )
            response.raise_for_status()
            data = response.json()
            return data.get("choices", [{}])[0].get("message", {}).get("content")
        except Exception as e:
            # Try fallback model
            try:
                response = self.client.post(
                    f"{self.endpoint}/v1/chat/completions",
                    json={
                        "model": self.fallback_model,
                        "messages": [
                            {"role": "system", "content": system_prompt},
                            {"role": "user", "content": prompt}
                        ],
                        "max_tokens": max_tokens,
                        "temperature": 0.3
                    }
                )
                response.raise_for_status()
                data = response.json()
                return data.get("choices", [{}])[0].get("message", {}).get("content")
            except:
                return None

    def explain(self, cache_type: str) -> str:
        """
        Explain what a cache type is and whether it's safe to delete.

        Args:
            cache_type: Name of the cache (e.g., "node_modules", ".venv")

        Returns:
            Explanation string
        """
        # Try corey-coder first
        response = self._query_corey(
            f"What is '{cache_type}' on a development machine? "
            f"Is it safe to delete? How do I regenerate it? "
            f"Keep answer under 100 words."
        )

        if response:
            return response

        # Fall back to built-in knowledge
        if cache_type in CACHE_KNOWLEDGE:
            info = CACHE_KNOWLEDGE[cache_type]
            return info["explanation"]

        # Generic fallback
        return f"Unknown cache type: {cache_type}. Use caution before deleting."

    def ask(self, question: str) -> str:
        """
        Ask a free-form question about disk cleanup.

        Args:
            question: Any question about disk usage or cleanup

        Returns:
            Answer string
        """
        if not AI_ENABLED:
            return "AI is disabled. Enable with AI_ENABLED=true in .env file."

        response = self._query_corey(question)

        if response:
            return response

        return "Unable to reach corey-coder. Please check your connection to the cluster."

    def analyze_scan(
        self,
        scan_results: List[Dict[str, Any]],
        disk_usage_percent: float = 0.0
    ) -> Dict[str, Any]:
        """
        Analyze scan results and provide prioritized recommendations.

        Args:
            scan_results: List of found caches with type, size, path
            disk_usage_percent: Current disk usage (0-100)

        Returns:
            Dict with recommendations, priorities, and total reclaimable space
        """
        # Categorize by safety
        safe_items = []
        caution_items = []
        review_items = []
        total_safe = 0
        total_caution = 0
        total_review = 0

        for item in scan_results:
            cache_type = item.get("type", "unknown")
            size = item.get("size_bytes", 0)

            # Determine safety from knowledge base
            safety = SafetyLevel.CAUTION
            if cache_type in CACHE_KNOWLEDGE:
                safety = CACHE_KNOWLEDGE[cache_type]["safety"]

            if safety == SafetyLevel.SAFE:
                safe_items.append(item)
                total_safe += size
            elif safety == SafetyLevel.CAUTION:
                caution_items.append(item)
                total_caution += size
            else:
                review_items.append(item)
                total_review += size

        # Build recommendations
        recommendations = []

        if total_safe > 1_073_741_824:  # > 1GB
            recommendations.append({
                "priority": "high",
                "action": "Delete all SAFE items",
                "space": total_safe,
                "risk": "none",
                "reason": f"Free {total_safe / 1_073_741_824:.1f}GB with zero risk"
            })

        if disk_usage_percent > 90 and total_caution > 0:
            recommendations.append({
                "priority": "medium",
                "action": "Review CAUTION items",
                "space": total_caution,
                "risk": "low",
                "reason": "Disk is nearly full - consider clearing caches"
            })

        # Try to get AI-powered recommendation
        if scan_results:
            context = f"Disk {disk_usage_percent:.0f}% full. Found: "
            context += ", ".join(f"{r['type']} ({r.get('size_bytes', 0) / 1_048_576:.0f}MB)"
                                for r in scan_results[:10])

            ai_recommendation = self._query_corey(
                f"Given this scan: {context}\n"
                f"What should I delete first? Prioritize by safety and size. "
                f"One sentence recommendation.",
                max_tokens=100
            )

            if ai_recommendation:
                recommendations.append({
                    "priority": "ai",
                    "action": ai_recommendation,
                    "source": "corey-coder"
                })

        return {
            "safe": {"items": safe_items, "total_bytes": total_safe},
            "caution": {"items": caution_items, "total_bytes": total_caution},
            "review": {"items": review_items, "total_bytes": total_review},
            "total_reclaimable": total_safe + total_caution + total_review,
            "recommendations": recommendations
        }

    def get_safety(self, cache_type: str) -> SafetyLevel:
        """Get the safety level for a cache type."""
        if cache_type in CACHE_KNOWLEDGE:
            return CACHE_KNOWLEDGE[cache_type]["safety"]
        return SafetyLevel.CAUTION

    def close(self):
        """Close the HTTP client."""
        if self._client:
            self._client.close()
            self._client = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


# CLI interface
def main():
    """Command-line interface for corey-coder integration."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Ask corey-coder about disk cleanup"
    )
    parser.add_argument(
        "action",
        choices=["ask", "explain", "test"],
        help="Action to perform"
    )
    parser.add_argument(
        "query",
        nargs="?",
        default="",
        help="Question or cache type"
    )
    parser.add_argument(
        "--endpoint",
        default=COREY_ENDPOINT,
        help="Corey-router endpoint"
    )
    parser.add_argument(
        "--model",
        default=COREY_MODEL,
        help="Model to use"
    )

    args = parser.parse_args()

    advisor = CoreyCleanupAdvisor(
        endpoint=args.endpoint,
        model=args.model
    )

    try:
        if args.action == "test":
            print("Testing corey-coder connection...")
            response = advisor.ask("Say 'hello' if you can hear me")
            if response:
                print(f"Success: {response}")
            else:
                print("Failed to connect to corey-coder")

        elif args.action == "explain":
            if not args.query:
                print("Usage: corey_integration.py explain <cache_type>")
                return
            print(advisor.explain(args.query))

        elif args.action == "ask":
            if not args.query:
                print("Usage: corey_integration.py ask '<question>'")
                return
            print(advisor.ask(args.query))

    finally:
        advisor.close()


if __name__ == "__main__":
    main()

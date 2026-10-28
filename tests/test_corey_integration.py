#!/usr/bin/env python3
"""
Tests for corey_integration module.

Run with: pytest tests/test_corey_integration.py -v
"""

import pytest
import sys
from pathlib import Path

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from corey_integration import (
    CoreyCleanupAdvisor,
    SafetyLevel,
    CACHE_KNOWLEDGE,
    load_env_file,
)


class TestSafetyLevel:
    """Tests for SafetyLevel enum."""

    def test_safety_level_values(self):
        """Safety levels should have correct numeric values."""
        assert SafetyLevel.SAFE.value == 1
        assert SafetyLevel.CAUTION.value == 2
        assert SafetyLevel.REVIEW.value == 3

    def test_safety_level_names(self):
        """Safety levels should have correct names."""
        assert SafetyLevel.SAFE.name == "SAFE"
        assert SafetyLevel.CAUTION.name == "CAUTION"
        assert SafetyLevel.REVIEW.name == "REVIEW"


class TestCacheKnowledge:
    """Tests for built-in CACHE_KNOWLEDGE dictionary."""

    def test_cache_knowledge_not_empty(self):
        """CACHE_KNOWLEDGE should contain entries."""
        assert len(CACHE_KNOWLEDGE) > 0

    def test_node_modules_is_safe(self):
        """node_modules should be marked SAFE."""
        assert "node_modules" in CACHE_KNOWLEDGE
        assert CACHE_KNOWLEDGE["node_modules"]["safety"] == SafetyLevel.SAFE

    def test_venv_is_review(self):
        """Virtual environments should be marked REVIEW."""
        assert ".venv" in CACHE_KNOWLEDGE
        assert CACHE_KNOWLEDGE[".venv"]["safety"] == SafetyLevel.REVIEW

    def test_docker_is_caution(self):
        """Docker should be marked CAUTION."""
        assert "Docker" in CACHE_KNOWLEDGE
        assert CACHE_KNOWLEDGE["Docker"]["safety"] == SafetyLevel.CAUTION

    def test_all_entries_have_required_fields(self):
        """All cache entries should have required fields."""
        required_fields = ["safety", "description", "explanation"]
        for name, info in CACHE_KNOWLEDGE.items():
            for field in required_fields:
                assert field in info, f"{name} missing {field}"

    def test_all_entries_have_valid_safety(self):
        """All cache entries should have valid SafetyLevel."""
        for name, info in CACHE_KNOWLEDGE.items():
            assert isinstance(info["safety"], SafetyLevel), f"{name} has invalid safety"


class TestLoadEnvFile:
    """Tests for load_env_file function."""

    def test_load_env_returns_dict(self):
        """load_env_file should return a dictionary."""
        result = load_env_file()
        assert isinstance(result, dict)

    def test_load_env_handles_missing_file(self):
        """load_env_file should handle missing .env gracefully."""
        # Should not raise, just return empty or defaults
        result = load_env_file()
        assert isinstance(result, dict)


class TestCoreyCleanupAdvisor:
    """Tests for CoreyCleanupAdvisor class."""

    @pytest.fixture
    def advisor(self):
        """Create advisor instance for tests."""
        return CoreyCleanupAdvisor()

    def test_advisor_instantiation(self, advisor):
        """Advisor should instantiate without errors."""
        assert advisor is not None
        assert advisor.endpoint is not None
        assert advisor.model is not None

    def test_get_safety_known_type(self, advisor):
        """get_safety should return correct level for known types."""
        assert advisor.get_safety("node_modules") == SafetyLevel.SAFE
        assert advisor.get_safety(".venv") == SafetyLevel.REVIEW
        assert advisor.get_safety("Docker") == SafetyLevel.CAUTION

    def test_get_safety_unknown_type(self, advisor):
        """get_safety should return CAUTION for unknown types."""
        assert advisor.get_safety("unknown_random_cache_xyz") == SafetyLevel.CAUTION

    def test_explain_known_type_without_ai(self, advisor):
        """explain should return built-in explanation when AI unavailable."""
        # This tests the fallback behavior
        result = advisor.explain("node_modules")
        assert isinstance(result, str)
        assert len(result) > 0
        # Should contain some relevant content
        assert "node" in result.lower() or "npm" in result.lower() or "safe" in result.lower()

    def test_explain_unknown_type(self, advisor):
        """explain should handle unknown types gracefully."""
        result = advisor.explain("completely_unknown_xyz_123")
        assert isinstance(result, str)
        assert len(result) > 0

    def test_analyze_scan_empty(self, advisor):
        """analyze_scan should handle empty results."""
        result = advisor.analyze_scan([])
        assert "safe" in result
        assert "caution" in result
        assert "review" in result
        assert result["total_reclaimable"] == 0

    def test_analyze_scan_with_results(self, advisor):
        """analyze_scan should categorize results correctly."""
        scan_results = [
            {"type": "node_modules", "size_bytes": 1_000_000, "path": "/test/app1"},
            {"type": ".venv", "size_bytes": 500_000, "path": "/test/app2"},
        ]
        result = advisor.analyze_scan(scan_results)

        assert result["total_reclaimable"] == 1_500_000
        assert len(result["safe"]["items"]) == 1
        assert len(result["review"]["items"]) == 1

    def test_analyze_scan_totals(self, advisor):
        """analyze_scan should calculate totals correctly."""
        scan_results = [
            {"type": "node_modules", "size_bytes": 1_000_000, "path": "/a"},
            {"type": ".next", "size_bytes": 2_000_000, "path": "/b"},
            {"type": "Docker", "size_bytes": 3_000_000, "path": "/c"},
        ]
        result = advisor.analyze_scan(scan_results)

        # node_modules and .next are SAFE
        assert result["safe"]["total_bytes"] == 3_000_000
        # Docker is CAUTION
        assert result["caution"]["total_bytes"] == 3_000_000

    def test_context_manager(self):
        """Advisor should work as context manager."""
        with CoreyCleanupAdvisor() as advisor:
            assert advisor is not None
            safety = advisor.get_safety("node_modules")
            assert safety == SafetyLevel.SAFE


class TestCacheTypesCoverage:
    """Tests to ensure we have good coverage of cache types."""

    def test_javascript_caches_present(self):
        """JavaScript-related caches should be present."""
        js_caches = ["node_modules", ".next"]
        for cache in js_caches:
            assert cache in CACHE_KNOWLEDGE, f"Missing {cache}"

    def test_python_caches_present(self):
        """Python-related caches should be present."""
        py_caches = ["__pycache__", ".venv"]
        for cache in py_caches:
            assert cache in CACHE_KNOWLEDGE, f"Missing {cache}"

    def test_ios_caches_present(self):
        """iOS-related caches should be present."""
        ios_caches = ["Pods", "DerivedData"]
        for cache in ios_caches:
            assert cache in CACHE_KNOWLEDGE, f"Missing {cache}"

    def test_rust_caches_present(self):
        """Rust-related caches should be present."""
        assert "target" in CACHE_KNOWLEDGE

    def test_system_caches_present(self):
        """System caches should be present."""
        system_caches = [".npm", "Downloads", "Trash"]
        for cache in system_caches:
            assert cache in CACHE_KNOWLEDGE, f"Missing {cache}"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])

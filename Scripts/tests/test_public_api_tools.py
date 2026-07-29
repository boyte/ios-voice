#!/usr/bin/env python3
"""Standard-library tests for the public API graph tools."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
VALIDATE = ROOT / "Scripts" / "validate-public-api.py"
COMPARE = ROOT / "Scripts" / "compare-public-api.py"


def symbol(precise: str = "s:test") -> dict[str, Any]:
    return {
        "identifier": {"precise": precise},
        "accessLevel": "public",
        "kind": {"identifier": "swift.struct", "displayName": "Structure"},
        "pathComponents": ["Example"],
        "declarationFragments": [
            {"kind": "keyword", "spelling": "struct"},
            {"kind": "text", "spelling": " "},
            {"kind": "identifier", "spelling": "Example"},
        ],
    }


def graph(*symbols: dict[str, Any], generator: str = "Swift test") -> dict[str, Any]:
    return {
        "module": {"name": "Example", "platform": {"architecture": "arm64", "environment": "simulator"}},
        "metadata": {"formatVersion": {"major": 0, "minor": 6, "patch": 0}, "generator": generator},
        "symbols": list(symbols),
    }


def fingerprint(value: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": value["kind"]["identifier"],
        "pathComponents": value["pathComponents"],
        "declarationFragments": value["declarationFragments"],
        "availability": value.get("availability"),
    }


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


class PublicAPIToolTests(unittest.TestCase):
    def run_tool(self, script: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(script), *arguments],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_validator_accepts_legacy_baseline_without_fingerprints(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = symbol()
            write_json(root / "graph.json", graph(current))
            write_json(root / "baseline.json", {"schemaVersion": 1, "module": "Example", "symbols": [{"precise": "s:test"}]})
            (root / "docs.md").write_text("<!-- api-symbol: s:test -->\n", encoding="utf-8")
            result = self.run_tool(
                VALIDATE,
                "--symbol-graph", str(root / "graph.json"),
                "--baseline", str(root / "baseline.json"),
                "--documentation", str(root / "docs.md"),
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_validator_rejects_duplicate_documentation_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = symbol()
            write_json(root / "graph.json", graph(current))
            write_json(root / "baseline.json", {"schemaVersion": 1, "module": "Example", "symbols": [{"precise": "s:test"}]})
            (root / "docs.md").write_text(
                "<!-- api-symbol: s:test -->\n<!-- api-symbol: s:test -->\n",
                encoding="utf-8",
            )
            result = self.run_tool(
                VALIDATE,
                "--symbol-graph", str(root / "graph.json"),
                "--baseline", str(root / "baseline.json"),
                "--documentation", str(root / "docs.md"),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate documentation marker", result.stderr)

    def test_validator_rejects_declaration_fingerprint_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = symbol()
            baseline_symbol = {"precise": "s:test", "fingerprint": fingerprint(current)}
            changed = symbol()
            changed["declarationFragments"][-1]["spelling"] = "Changed"
            write_json(root / "graph.json", graph(changed))
            write_json(root / "baseline.json", {"schemaVersion": 1, "module": "Example", "symbols": [baseline_symbol]})
            (root / "docs.md").write_text("<!-- api-symbol: s:test -->\n", encoding="utf-8")
            result = self.run_tool(
                VALIDATE,
                "--symbol-graph", str(root / "graph.json"),
                "--baseline", str(root / "baseline.json"),
                "--documentation", str(root / "docs.md"),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("declaration fingerprints", result.stderr)

    def test_validator_rejects_partial_or_malformed_fingerprint_baselines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = symbol()
            write_json(root / "graph.json", graph(current))
            (root / "docs.md").write_text("<!-- api-symbol: s:test -->\n", encoding="utf-8")

            partial = {
                "schemaVersion": 1,
                "module": "Example",
                "symbols": [
                    {"precise": "s:test", "fingerprint": fingerprint(current)},
                    {"precise": "s:other"},
                ],
            }
            write_json(root / "baseline.json", partial)
            result = self.run_tool(
                VALIDATE,
                "--symbol-graph", str(root / "graph.json"),
                "--baseline", str(root / "baseline.json"),
                "--documentation", str(root / "docs.md"),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("every symbol or none", result.stderr)

            malformed = {"schemaVersion": 1, "module": "Example", "symbols": [{"precise": "s:test", "fingerprint": {"kind": "swift.struct"}}]}
            write_json(root / "baseline.json", malformed)
            result = self.run_tool(
                VALIDATE,
                "--symbol-graph", str(root / "graph.json"),
                "--baseline", str(root / "baseline.json"),
                "--documentation", str(root / "docs.md"),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing", result.stderr)

    def test_validator_rejects_malformed_and_duplicate_graph_symbols(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            duplicate = symbol()
            write_json(root / "graph.json", graph(symbol(), duplicate))
            write_json(root / "baseline.json", {"schemaVersion": 1, "module": "Example", "symbols": [{"precise": "s:test"}]})
            (root / "docs.md").write_text("<!-- api-symbol: s:test -->\n", encoding="utf-8")
            result = self.run_tool(
                VALIDATE,
                "--symbol-graph", str(root / "graph.json"),
                "--baseline", str(root / "baseline.json"),
                "--documentation", str(root / "docs.md"),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate", result.stderr)

            malformed = graph(symbol())
            malformed["symbols"][0]["declarationFragments"] = "not-an-array"
            write_json(root / "graph.json", malformed)
            result = self.run_tool(
                VALIDATE,
                "--symbol-graph", str(root / "graph.json"),
                "--baseline", str(root / "baseline.json"),
                "--documentation", str(root / "docs.md"),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("declarationFragments", result.stderr)

    def test_compare_reports_changed_symbol_details(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            previous = symbol()
            candidate = symbol()
            candidate["declarationFragments"][-1]["spelling"] = "Changed"
            write_json(root / "previous.json", graph(previous))
            write_json(root / "candidate.json", graph(candidate))
            output = root / "nested" / "report.json"
            result = self.run_tool(
                COMPARE,
                "--previous", str(root / "previous.json"),
                "--candidate", str(root / "candidate.json"),
                "--output", str(output),
            )
            self.assertNotEqual(result.returncode, 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["changed"], ["s:test"])
            self.assertEqual(report["changedDetails"]["s:test"]["previous"]["declarationFragments"][-1]["spelling"], "Example")
            self.assertEqual(report["changedDetails"]["s:test"]["candidate"]["declarationFragments"][-1]["spelling"], "Changed")

    def test_compare_detects_relationship_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            previous = graph(symbol())
            candidate = graph(symbol())
            previous["relationships"] = []
            candidate["relationships"] = [{
                "source": "s:test",
                "target": "s:protocol",
                "kind": "conformsTo",
            }]
            write_json(root / "previous.json", previous)
            write_json(root / "candidate.json", candidate)
            result = self.run_tool(
                COMPARE,
                "--previous", str(root / "previous.json"),
                "--candidate", str(root / "candidate.json"),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("s:test", result.stdout)

    def test_compare_rejects_mismatched_provenance_and_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_json(root / "previous.json", graph(symbol(), generator="Swift 6.3"))
            write_json(root / "candidate.json", graph(symbol(), generator="Swift 6.4"))
            result = self.run_tool(COMPARE, "--previous", str(root / "previous.json"), "--candidate", str(root / "candidate.json"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("provenance differs", result.stderr)

            duplicate = graph(symbol(), symbol("s:other"))
            duplicate["symbols"][1]["identifier"]["precise"] = "s:test"
            write_json(root / "candidate.json", duplicate)
            result = self.run_tool(COMPARE, "--previous", str(root / "previous.json"), "--candidate", str(root / "candidate.json"))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("duplicate", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

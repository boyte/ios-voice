#!/usr/bin/env python3
"""Generate the checked-in public API baseline from a production symbol graph.

The graph must come from a production-only compilation. Test-visible symbols
must never be copied into the release contract.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def fingerprint(symbol: dict[str, Any]) -> dict[str, Any]:
    kind = symbol["kind"].get("identifier")
    return {
        "kind": kind,
        "pathComponents": symbol.get("pathComponents"),
        "declarationFragments": symbol.get("declarationFragments"),
        "availability": symbol.get("availability"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--symbol-graph", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--module", default="AppLocalVoice")
    args = parser.parse_args()

    graph = json.loads(args.symbol_graph.read_text(encoding="utf-8"))
    if graph.get("module", {}).get("name") != args.module:
        raise SystemExit(f"symbol graph is not for {args.module}")

    symbols = []
    for symbol in graph.get("symbols", []):
        if symbol.get("accessLevel") not in {"public", "open"}:
            continue
        precise = symbol.get("identifier", {}).get("precise")
        if not isinstance(precise, str) or "::SYNTHESIZED::" in precise or precise.startswith("c:@CM@"):
            continue
        symbols.append(
            {
                "precise": precise,
                "title": symbol["names"]["title"],
                "kind": symbol["kind"]["identifier"],
                "fingerprint": fingerprint(symbol),
            }
        )

    result = {
        "schemaVersion": 1,
        "module": args.module,
        "source": "production-only SwiftPM symbol graph; generated from the pinned toolchain",
        "ignoredSymbolRules": [
            {
                "contains": "::SYNTHESIZED::",
                "reason": "Swift compiler-generated conformance and error helpers; not source API.",
            },
            {
                "prefix": "c:@CM@",
                "reason": "Objective-C delegate entry points emitted for an internal NSObject callback; not source-level API.",
            },
        ],
        "symbols": sorted(symbols, key=lambda item: item["precise"]),
    }
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Generated {len(symbols)} public symbols in {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

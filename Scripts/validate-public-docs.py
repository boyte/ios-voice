#!/usr/bin/env python3
"""Require a source documentation comment for every allowlisted symbol."""

from __future__ import annotations

import argparse
import json
import pathlib


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--symbol-graph", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", type=pathlib.Path, required=True)
    args = parser.parse_args()
    graph = {
        symbol["identifier"]["precise"]: symbol
        for symbol in json.loads(args.symbol_graph.read_text(encoding="utf-8"))["symbols"]
    }
    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))["symbols"]
    missing = [
        symbol["precise"]
        for symbol in baseline
        if not graph.get(symbol["precise"], {}).get("docComment")
    ]
    if missing:
        raise SystemExit("undocumented public symbols:\n" + "\n".join(missing))
    print(f"Public documentation OK: {len(baseline)} allowlisted symbols")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

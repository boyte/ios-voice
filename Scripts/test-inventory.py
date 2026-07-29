#!/usr/bin/env python3
"""Emit or validate the repository's XCTest inventory."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = ROOT / "Tests" / "AppLocalVoiceTests"
TEST_METHOD = re.compile(r"\bfunc\s+(test\w+)\s*\(")


def _mask_comments_and_strings(source: str) -> str:
    """Hide comments and string contents while preserving line structure.

    XCTest discovery still belongs to Swift/XCTest, but masking non-code text
    prevents a comment or fixture string containing ``func test...`` from
    inflating the checked-in inventory. Swift block comments may nest.
    """

    output: list[str] = []
    index = 0
    block_depth = 0
    state = "code"
    while index < len(source):
        if state == "line-comment":
            character = source[index]
            output.append("\n" if character == "\n" else " ")
            if character == "\n":
                state = "code"
            index += 1
            continue
        if state == "block-comment":
            if source.startswith("/*", index):
                block_depth += 1
                output.extend("  ")
                index += 2
            elif source.startswith("*/", index):
                block_depth -= 1
                output.extend("  ")
                index += 2
                if block_depth == 0:
                    state = "code"
            else:
                character = source[index]
                output.append("\n" if character == "\n" else " ")
                index += 1
            continue
        if state == "string":
            if source.startswith('"""', index):
                output.extend("   ")
                index += 3
                state = "code"
            elif source[index] == '"':
                output.append(" ")
                index += 1
                state = "code"
            elif source[index] == "\\":
                output.extend("  ")
                index += min(2, len(source) - index)
            else:
                character = source[index]
                output.append("\n" if character == "\n" else " ")
                index += 1
            continue

        if source.startswith("//", index):
            output.extend("  ")
            index += 2
            state = "line-comment"
        elif source.startswith("/*", index):
            output.extend("  ")
            index += 2
            block_depth = 1
            state = "block-comment"
        elif source.startswith('"""', index):
            output.extend("   ")
            index += 3
            state = "string"
        elif source[index] == '"':
            output.append(" ")
            index += 1
            state = "string"
        else:
            output.append(source[index])
            index += 1
    return "".join(output)


def inventory() -> dict:
    files = []
    method_count = 0
    identities = []
    swift_files = sorted(TEST_ROOT.glob("*.swift"))
    for path in swift_files:
        methods = TEST_METHOD.findall(_mask_comments_and_strings(path.read_text(encoding="utf-8")))
        duplicates = sorted({method for method in methods if methods.count(method) > 1})
        if duplicates:
            raise ValueError(f"duplicate XCTest method names in {path}: {', '.join(duplicates)}")
        if methods:
            file_name = str(path.relative_to(ROOT))
            files.append({
                "file": file_name,
                "methods": len(methods),
                "methodNames": methods,
            })
            identities.extend(f"{path.stem}.{method}" for method in methods)
            method_count += len(methods)
    if len(identities) != len(set(identities)):
        duplicates = sorted({identity for identity in identities if identities.count(identity) > 1})
        raise ValueError("duplicate XCTest identities: " + ", ".join(duplicates))
    return {
        "schemaVersion": 1,
        "testMethods": method_count,
        "testFiles": len(files),
        "swiftFiles": len(swift_files),
        "files": files,
        "testIdentities": identities,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", type=Path)
    args = parser.parse_args()
    try:
        document = inventory()
    except ValueError as error:
        raise SystemExit(f"test inventory error: {error}") from error
    rendered = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    if args.check:
        expected = args.check.read_text(encoding="utf-8")
        if expected != rendered:
            raise SystemExit(f"test inventory is stale: regenerate {args.check}")
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

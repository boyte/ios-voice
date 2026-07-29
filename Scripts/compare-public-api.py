#!/usr/bin/env python3
"""Compare two Swift symbol graphs for release compatibility.

The comparison is deliberately strict about graph provenance and shape.  A
release comparison is meaningful only when both inputs describe the same
module, platform, symbol-graph format, and compiler family.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any


FINGERPRINT_FIELDS = ("kind", "pathComponents", "declarationFragments", "availability")


def fail(message: str) -> None:
    print(f"public API comparison failed: {message}", file=sys.stderr)


def load(path: pathlib.Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]], dict[str, list[dict[str, str]]]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read JSON graph {path}: {error}") from error
    if not isinstance(document, dict):
        raise ValueError(f"graph root must be an object: {path}")
    module = document.get("module")
    if not isinstance(module, dict) or not isinstance(module.get("name"), str) or not module["name"]:
        raise ValueError(f"graph module.name must be a non-empty string: {path}")
    platform = module.get("platform")
    if not isinstance(platform, dict):
        raise ValueError(f"graph platform must be an object: {path}")
    metadata = document.get("metadata")
    if not isinstance(metadata, dict):
        raise ValueError(f"graph metadata must be an object: {path}")
    format_version = metadata.get("formatVersion")
    if not isinstance(format_version, dict):
        raise ValueError(f"graph metadata.formatVersion must be an object: {path}")
    symbols = document.get("symbols")
    if not isinstance(symbols, list) or not symbols:
        raise ValueError(f"graph symbols must be a non-empty array: {path}")

    indexed: dict[str, dict[str, Any]] = {}
    for index, symbol in enumerate(symbols):
        if not isinstance(symbol, dict):
            raise ValueError(f"graph symbol {index} must be an object: {path}")
        identifier = symbol.get("identifier")
        if not isinstance(identifier, dict) or not isinstance(identifier.get("precise"), str) or not identifier["precise"]:
            raise ValueError(f"graph symbol {index}.identifier.precise is invalid: {path}")
        precise = identifier["precise"]
        if precise in indexed:
            raise ValueError(f"duplicate graph symbol precise identifier: {precise}")
        kind = symbol.get("kind")
        if not isinstance(kind, dict) or not isinstance(kind.get("identifier"), str) or not kind["identifier"]:
            raise ValueError(f"graph symbol {precise}.kind.identifier is invalid: {path}")
        path_components = symbol.get("pathComponents")
        if not isinstance(path_components, list) or not all(isinstance(value, str) and value for value in path_components):
            raise ValueError(f"graph symbol {precise}.pathComponents is invalid: {path}")
        fragments = symbol.get("declarationFragments")
        if not isinstance(fragments, list):
            raise ValueError(f"graph symbol {precise}.declarationFragments is invalid: {path}")
        for fragment in fragments:
            if not isinstance(fragment, dict) or not isinstance(fragment.get("kind"), str) or not isinstance(fragment.get("spelling"), str):
                raise ValueError(f"graph symbol {precise}.declarationFragments contains an invalid item: {path}")
        availability = symbol.get("availability")
        if availability is not None and not isinstance(availability, list):
            raise ValueError(f"graph symbol {precise}.availability is invalid: {path}")
        indexed[precise] = symbol
    relationships = document.get("relationships", [])
    if not isinstance(relationships, list):
        raise ValueError(f"graph relationships must be an array when present: {path}")
    relationship_index: dict[str, list[dict[str, str]]] = {}
    for index, relationship in enumerate(relationships):
        if not isinstance(relationship, dict):
            raise ValueError(f"graph relationship {index} must be an object: {path}")
        source = relationship.get("source")
        target = relationship.get("target")
        kind = relationship.get("kind")
        if not all(isinstance(value, str) and value for value in (source, target, kind)):
            raise ValueError(f"graph relationship {index} has invalid source, target, or kind: {path}")
        relationship_index.setdefault(source, []).append(
            {"source": source, "target": target, "kind": kind}
        )
    for values in relationship_index.values():
        values.sort(key=lambda value: (value["kind"], value["target"]))
    return document, indexed, relationship_index


def context(document: dict[str, Any]) -> dict[str, Any]:
    metadata = document["metadata"]
    return {
        "module": document["module"]["name"],
        "platform": document["module"]["platform"],
        "formatVersion": metadata["formatVersion"],
        "generator": metadata.get("generator"),
    }


def compatibility_fingerprint(
    symbol: dict[str, Any], relationships: list[dict[str, str]]
) -> dict[str, Any]:
    return {
        "accessLevel": symbol.get("accessLevel"),
        "kind": symbol["kind"]["identifier"],
        "pathComponents": symbol["pathComponents"],
        "declarationFragments": symbol["declarationFragments"],
        "availability": symbol.get("availability"),
        "relationships": relationships,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous", type=pathlib.Path, required=True)
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()

    try:
        previous_document, previous, previous_relationships = load(args.previous)
        candidate_document, candidate, candidate_relationships = load(args.candidate)
        previous_context = context(previous_document)
        candidate_context = context(candidate_document)
        if previous_context != candidate_context:
            raise ValueError(
                "graph provenance differs; expected identical module, platform, "
                "symbol-graph format, and generator metadata\n"
                f"previous: {json.dumps(previous_context, sort_keys=True)}\n"
                f"candidate: {json.dumps(candidate_context, sort_keys=True)}"
            )
    except (OSError, ValueError) as error:
        fail(str(error))
        return 1

    removed = sorted(set(previous) - set(candidate))
    added = sorted(set(candidate) - set(previous))
    changed = sorted(
        precise
        for precise in set(previous) & set(candidate)
        if compatibility_fingerprint(previous[precise], previous_relationships.get(precise, []))
        != compatibility_fingerprint(candidate[precise], candidate_relationships.get(precise, []))
    )
    changed_details = {
        precise: {
            "previous": compatibility_fingerprint(previous[precise], previous_relationships.get(precise, [])),
            "candidate": compatibility_fingerprint(candidate[precise], candidate_relationships.get(precise, [])),
        }
        for precise in changed
    }
    report = {
        "schemaVersion": 1,
        "previousCount": len(previous),
        "candidateCount": len(candidate),
        "removed": removed,
        "added": added,
        "changed": changed,
        "changedDetails": changed_details,
        "compatible": not removed and not changed,
    }
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        try:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(rendered, encoding="utf-8")
        except OSError as error:
            fail(f"cannot write report {args.output}: {error}")
            return 1
    print(rendered, end="")
    if removed or changed:
        print("public API compatibility check failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

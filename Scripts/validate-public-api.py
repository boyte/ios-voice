#!/usr/bin/env python3
"""Validate AppLocalVoice's checked-in public symbol contract.

The validator deliberately uses symbol-graph precise identifiers rather than
display names: overloads and generic signatures must remain distinguishable.
It has no Git or network dependency, so it can run in a clean checkout and in
CI before a repository has a remote or a previous release.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


MARKER = re.compile(r"<!--\s*api-symbol:\s*(\S+)\s*-->")
FINGERPRINT_FIELDS = ("kind", "pathComponents", "declarationFragments", "availability")


def fail(messages: list[str]) -> int:
    print("Public API validation failed:", file=sys.stderr)
    for message in messages:
        print(f"- {message}", file=sys.stderr)
    return 1


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read JSON file {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"JSON root must be an object: {path}")
    return value


def _require_string(value: Any, description: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{description} must be a non-empty string")
    return value


def _validate_symbol(symbol: Any, index: int) -> dict[str, Any]:
    if not isinstance(symbol, dict):
        raise ValueError(f"symbol graph entry {index} must be an object")
    identifier = symbol.get("identifier")
    if not isinstance(identifier, dict):
        raise ValueError(f"symbol graph entry {index}.identifier must be an object")
    precise = _require_string(
        identifier.get("precise"), f"symbol graph entry {index}.identifier.precise"
    )
    kind = symbol.get("kind")
    if not isinstance(kind, dict):
        raise ValueError(f"symbol {precise}.kind must be an object")
    _require_string(kind.get("identifier"), f"symbol {precise}.kind.identifier")
    path_components = symbol.get("pathComponents")
    if not isinstance(path_components, list) or not all(
        isinstance(component, str) and component for component in path_components
    ):
        raise ValueError(f"symbol {precise}.pathComponents must be an array of non-empty strings")
    fragments = symbol.get("declarationFragments")
    if not isinstance(fragments, list):
        raise ValueError(f"symbol {precise}.declarationFragments must be an array")
    for fragment_index, fragment in enumerate(fragments):
        if not isinstance(fragment, dict):
            raise ValueError(f"symbol {precise}.declarationFragments[{fragment_index}] must be an object")
        _require_string(fragment.get("kind"), f"symbol {precise} declaration fragment kind")
        if not isinstance(fragment.get("spelling"), str):
            raise ValueError(f"symbol {precise} declaration fragment spelling must be a string")
    availability = symbol.get("availability")
    if availability is not None and not isinstance(availability, list):
        raise ValueError(f"symbol {precise}.availability must be an array or null")
    access_level = symbol.get("accessLevel")
    if access_level is not None and not isinstance(access_level, str):
        raise ValueError(f"symbol {precise}.accessLevel must be a string when present")
    return symbol


def validate_graph(graph: dict[str, Any], path: Path, expected_module: str | None = None) -> list[dict[str, Any]]:
    module = graph.get("module")
    if not isinstance(module, dict):
        raise ValueError(f"symbol graph module must be an object: {path}")
    module_name = _require_string(module.get("name"), f"symbol graph module.name: {path}")
    if not isinstance(module.get("platform"), dict):
        raise ValueError(f"symbol graph module.platform must be an object: {path}")
    metadata = graph.get("metadata")
    if not isinstance(metadata, dict) or not isinstance(metadata.get("formatVersion"), dict):
        raise ValueError(f"symbol graph metadata.formatVersion must be an object: {path}")
    if expected_module is not None and module_name != expected_module:
        raise ValueError(f"symbol graph module is not {expected_module}: {path}")
    symbols = graph.get("symbols")
    if not isinstance(symbols, list) or not symbols:
        raise ValueError(f"symbol graph symbols must be a non-empty array: {path}")
    validated: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, symbol in enumerate(symbols):
        validated_symbol = _validate_symbol(symbol, index)
        precise = validated_symbol["identifier"]["precise"]
        if precise in seen:
            raise ValueError(f"duplicate symbol graph precise identifier: {precise}")
        seen.add(precise)
        validated.append(validated_symbol)
    return validated


def compatibility_fingerprint(symbol: dict[str, Any]) -> dict[str, Any]:
    kind = symbol["kind"].get("identifier") if isinstance(symbol.get("kind"), dict) else None
    return {
        "kind": kind,
        "pathComponents": symbol.get("pathComponents"),
        "declarationFragments": symbol.get("declarationFragments"),
        "availability": symbol.get("availability"),
    }


def baseline_fingerprint(entry: dict[str, Any], precise: str) -> dict[str, Any] | None:
    value = entry.get("fingerprint")
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError(f"baseline fingerprint for {precise} must be an object")
    missing = [field for field in FINGERPRINT_FIELDS if field not in value]
    if missing:
        raise ValueError(f"baseline fingerprint for {precise} is missing: {', '.join(missing)}")
    if not isinstance(value["kind"], str) or not value["kind"]:
        raise ValueError(f"baseline fingerprint kind for {precise} must be a non-empty string")
    if not isinstance(value["pathComponents"], list) or not all(
        isinstance(component, str) and component for component in value["pathComponents"]
    ):
        raise ValueError(f"baseline fingerprint pathComponents for {precise} is invalid")
    if not isinstance(value["declarationFragments"], list):
        raise ValueError(f"baseline fingerprint declarationFragments for {precise} is invalid")
    if value["availability"] is not None and not isinstance(value["availability"], list):
        raise ValueError(f"baseline fingerprint availability for {precise} is invalid")
    return {field: value[field] for field in FINGERPRINT_FIELDS}


def graph_path(value: Path, module: str) -> Path:
    if value.is_file():
        return value
    candidates = sorted(value.glob("*.symbols.json"))
    if not candidates:
        raise ValueError(f"no *.symbols.json file found under {value}")
    matching: list[Path] = []
    for candidate in candidates:
        try:
            graph = load_json(candidate)
        except ValueError:
            continue
        module_value = graph.get("module")
        if isinstance(module_value, dict) and module_value.get("name") == module:
            matching.append(candidate)
    if len(matching) != 1:
        names = ", ".join(str(path) for path in matching or candidates)
        raise ValueError(f"expected one {module} symbol graph under {value}; found {names}")
    return matching[0]


def ignored(precise: str, rules: list[dict[str, Any]]) -> bool:
    for rule in rules:
        contains = rule.get("contains")
        if isinstance(contains, str) and contains in precise:
            return True
        prefix = rule.get("prefix")
        if isinstance(prefix, str) and precise.startswith(prefix):
            return True
    return False


def documented_symbols(paths: list[Path]) -> set[str]:
    symbols: set[str] = set()
    for path in paths:
        if not path.is_file():
            raise ValueError(f"documentation file does not exist: {path}")
        for precise in MARKER.findall(path.read_text(encoding="utf-8")):
            if precise in symbols:
                raise ValueError(f"duplicate documentation marker: {precise}")
            symbols.add(precise)
    return symbols


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--symbol-graph", type=Path, required=True)
    parser.add_argument(
        "--baseline",
        type=Path,
        default=Path("Documentation/PublicAPISymbols.json"),
    )
    parser.add_argument(
        "--documentation",
        type=Path,
        action="append",
        default=None,
        help="Markdown file containing <!-- api-symbol: PRECISE-ID --> markers",
    )
    args = parser.parse_args()

    errors: list[str] = []
    try:
        baseline = load_json(args.baseline)
        module = baseline["module"]
        if not isinstance(module, str) or not module:
            raise ValueError("baseline.module must be a non-empty string")
        if baseline.get("schemaVersion") != 1:
            raise ValueError("unsupported baseline schemaVersion; update the validator deliberately")
        graph_file = graph_path(args.symbol_graph, module)
        graph = load_json(graph_file)
        graph_symbols = validate_graph(graph, graph_file, module)

        rules = baseline.get("ignoredSymbolRules", [])
        if not isinstance(rules, list) or not all(isinstance(rule, dict) for rule in rules):
            raise ValueError("baseline.ignoredSymbolRules must be an array of objects")

        entries = baseline.get("symbols")
        if not isinstance(entries, list) or not entries:
            raise ValueError("baseline.symbols must be a non-empty array")
        expected: dict[str, dict[str, Any]] = {}
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("precise"), str):
                raise ValueError("every baseline symbol must have a precise string")
            precise = entry["precise"]
            if precise in expected:
                raise ValueError(f"duplicate baseline symbol: {precise}")
            expected[precise] = entry

        fingerprinted = [
            precise for precise, entry in expected.items() if entry.get("fingerprint") is not None
        ]
        if fingerprinted and len(fingerprinted) != len(expected):
            raise ValueError("baseline fingerprints must be present for every symbol or none")
        expected_fingerprints = {
            precise: baseline_fingerprint(entry, precise)
            for precise, entry in expected.items()
        }

        actual_entries = graph_symbols
        actual: dict[str, dict[str, Any]] = {}
        for entry in actual_entries:
            identifier = entry.get("identifier", {})
            if entry.get("accessLevel") not in ("public", "open"):
                continue
            precise = identifier.get("precise")
            if isinstance(precise, str) and not ignored(precise, rules):
                actual[precise] = entry

        if fingerprinted:
            changed = sorted(
                precise
                for precise in set(actual) & set(expected)
                if expected_fingerprints[precise] != compatibility_fingerprint(actual[precise])
            )
            if changed:
                errors.append("public symbol declaration fingerprints differ from the baseline:")
                errors.extend(f"  {symbol}" for symbol in changed)

        unexpected = sorted(set(actual) - set(expected))
        missing = sorted(set(expected) - set(actual))
        if unexpected:
            errors.append("unexpected public symbols:")
            errors.extend(f"  {symbol}" for symbol in unexpected)
        if missing:
            errors.append("baseline symbols missing from generated graph:")
            errors.extend(f"  {symbol}" for symbol in missing)

        documentation_paths = args.documentation or [Path("Documentation/PublicAPI.md")]
        documented = documented_symbols(documentation_paths)
        expected_ids = set(expected)
        missing_docs = sorted(expected_ids - documented)
        stale_docs = sorted(documented - expected_ids)
        if missing_docs:
            errors.append("public symbols missing documentation markers:")
            errors.extend(f"  {symbol}" for symbol in missing_docs)
        if stale_docs:
            errors.append("documentation markers not present in the baseline:")
            errors.extend(f"  {symbol}" for symbol in stale_docs)

        if errors:
            return fail(errors)

        ignored_count = sum(
            1
            for entry in actual_entries
            if entry.get("accessLevel") in ("public", "open")
            and isinstance(entry.get("identifier", {}).get("precise"), str)
            and ignored(entry["identifier"]["precise"], rules)
        )
        print(
            f"Public API OK: {len(actual)} allowlisted symbols, "
            f"{ignored_count} generated symbols ignored by explicit rules, "
            f"{len(documented)} documentation markers."
        )
        return 0
    except ValueError as error:
        return fail([str(error)])


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Reconcile a checked-in XCTest inventory with an executed result summary."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Iterator


class ResultValidationError(ValueError):
    """The native result summary does not satisfy the declared contract."""


DOCUMENTED_SDK_SKIP = "AudioEngineSafetyTests.testMalformedHardwareFormatsFailClosed"
DOCUMENTED_SDK_SKIP_REASONS = frozenset(
    {
        "This simulator SDK cannot construct a three-channel standard format.",
        "This simulator SDK cannot construct a nine-channel standard format.",
        "This simulator SDK cannot construct AVAudioFormat.otherFormat.",
    }
)


def load_object(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ResultValidationError(f"cannot read JSON object {path}: {error}") from error
    if not isinstance(value, dict):
        raise ResultValidationError(f"JSON root must be an object: {path}")
    return value


def integer(document: dict[str, object], key: str) -> int:
    value = document.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ResultValidationError(f"summary field {key!r} must be a non-negative integer")
    return value


def _walk_objects(value: object) -> Iterator[dict[str, object]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk_objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_objects(child)


def _is_skipped_test(node: dict[str, object]) -> bool:
    for key in ("result", "status", "testStatus"):
        value = node.get(key)
        if isinstance(value, str) and value.casefold() in {"skipped", "skip"}:
            return True
    return False


def _test_identity(node: dict[str, object]) -> str | None:
    # xcresulttool's native test tree carries the stable class-qualified
    # identity in `nodeIdentifier`. The human-readable `name` may contain
    # only the method name, so inspect it last.
    for key in (
        "nodeIdentifier",
        "nodeIdentifierURL",
        "testIdentifier",
        "identifier",
        "testName",
        "name",
    ):
        value = node.get(key)
        if isinstance(value, str) and value.strip():
            identity = value.strip().removesuffix("()")
            if key == "nodeIdentifierURL":
                marker = "/AudioEngineSafetyTests/"
                if marker not in identity:
                    continue
                identity = "AudioEngineSafetyTests/" + identity.split(marker, 1)[1]
            identity = re.sub(r"^-\[[^ ]+\s+", "", identity).removesuffix("]")
            for prefix in ("AppLocalVoiceTests.", "AppLocalVoiceTests/", "AppLocalVoiceTests:"):
                if identity.startswith(prefix):
                    identity = identity[len(prefix):]
            identity = identity.replace("/", ".").replace("::", ".")
            return identity
    return None


def _skip_reason(node: dict[str, object]) -> str | None:
    reason_keys = {"reason", "skipReason", "message", "value", "text"}
    for candidate in _walk_objects(node):
        for key, value in candidate.items():
            if key in reason_keys and isinstance(value, str) and value.strip():
                return value.strip()
            # Xcode 26's native test tree records the reason as a failure
            # message name: "Test skipped - <reason>".
            if key == "name" and isinstance(value, str) and value.startswith("Test skipped - "):
                return value.removeprefix("Test skipped - ").strip()
    return None


def _validate_named_skips(tests: dict[str, object], expected_count: int) -> None:
    skipped = [node for node in _walk_objects(tests) if _is_skipped_test(node)]
    if len(skipped) != expected_count:
        raise ResultValidationError(
            f"test result reports {expected_count} skipped tests but test details contain "
            f"{len(skipped)}"
        )
    for node in skipped:
        identity = _test_identity(node)
        reason = _skip_reason(node)
        if identity != DOCUMENTED_SDK_SKIP:
            raise ResultValidationError(
                f"undocumented skipped test identity: {identity!r}; "
                f"expected {DOCUMENTED_SDK_SKIP!r}"
            )
        if reason not in DOCUMENTED_SDK_SKIP_REASONS:
            raise ResultValidationError(f"undocumented SDK skip reason: {reason!r}")


def _test_case_identities(tests: dict[str, object]) -> list[str]:
    identities: list[str] = []
    for node in _walk_objects(tests):
        node_type = node.get("nodeType")
        if not isinstance(node_type, str) or "test case" not in node_type.casefold():
            continue
        identity = _test_identity(node)
        if identity is None:
            raise ResultValidationError("executed test case has no stable identity")
        identities.append(identity)
    if len(identities) != len(set(identities)):
        raise ResultValidationError("executed test details contain duplicate test identities")
    return identities


def validate(
    inventory_path: Path,
    summary_path: Path,
    max_skipped: int,
    tests_path: Path | None = None,
) -> dict[str, int | str]:
    inventory = load_object(inventory_path)
    summary = load_object(summary_path)
    declared = inventory.get("testMethods")
    if not isinstance(declared, int) or isinstance(declared, bool) or declared < 0:
        raise ResultValidationError("inventory testMethods must be a non-negative integer")

    result = summary.get("result")
    if result != "Passed":
        raise ResultValidationError(f"XCTest result is not Passed: {result!r}")
    total = integer(summary, "totalTestCount")
    failed = integer(summary, "failedTests")
    skipped = integer(summary, "skippedTests")
    expected_failures = integer(summary, "expectedFailures")
    if total != declared:
        raise ResultValidationError(
            f"executed test count {total} does not match inventory {declared}"
        )
    if failed != 0 or expected_failures != 0:
        raise ResultValidationError(
            f"result contains failures: failedTests={failed}, expectedFailures={expected_failures}"
        )
    if skipped > max_skipped:
        raise ResultValidationError(
            f"result skipped {skipped} tests; maximum allowed is {max_skipped}"
        )
    if skipped:
        if tests_path is None:
            raise ResultValidationError(
                "named test details are required to validate an allowed skip"
            )
        _validate_named_skips(load_object(tests_path), skipped)
    elif tests_path is not None:
        _validate_named_skips(load_object(tests_path), 0)
    expected_identities = inventory.get("testIdentities")
    if expected_identities is not None:
        if not isinstance(expected_identities, list) or not all(
            isinstance(identity, str) and identity for identity in expected_identities
        ):
            raise ResultValidationError("inventory testIdentities must be a non-empty string array")
        if len(expected_identities) != declared or len(set(expected_identities)) != declared:
            raise ResultValidationError("inventory testIdentities must be unique and match testMethods")
        if tests_path is None:
            raise ResultValidationError("test details are required for exact identity reconciliation")
        actual_identities = _test_case_identities(load_object(tests_path))
        expected = set(expected_identities)
        actual = set(actual_identities)
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        if missing or unexpected or len(actual_identities) != declared:
            details = []
            if missing:
                details.append("missing=" + ",".join(missing))
            if unexpected:
                details.append("unexpected=" + ",".join(unexpected))
            details.append(f"executedIdentityCount={len(actual_identities)}")
            raise ResultValidationError("executed test identities do not match inventory: " + "; ".join(details))
    return {
        "result": result,
        "declaredTests": declared,
        "executedTests": total,
        "failedTests": failed,
        "skippedTests": skipped,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument(
        "--tests",
        type=Path,
        help="xcresulttool test-results tests JSON, required when skips are allowed",
    )
    parser.add_argument("--max-skipped", type=int, default=0)
    args = parser.parse_args()
    if args.max_skipped < 0:
        parser.error("--max-skipped must be non-negative")
    try:
        record = validate(args.inventory, args.summary, args.max_skipped, args.tests)
    except ResultValidationError as error:
        parser.exit(1, f"test result validation failed: {error}\n")
    print(json.dumps(record, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

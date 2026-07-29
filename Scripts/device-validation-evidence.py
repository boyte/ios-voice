#!/usr/bin/env python3
"""Extract exact physical-device facts from a devicectl JSON response."""

from __future__ import annotations

import json
import sys
from typing import Any


def walk(value: Any):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def first_value(root: Any, keys: tuple[str, ...]) -> str:
    for value in walk(root):
        if not isinstance(value, dict):
            continue
        for key in keys:
            candidate = value.get(key)
            if isinstance(candidate, (str, int, float)) and str(candidate).strip():
                return str(candidate).strip()
    return ""


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: device-validation-evidence.py <devices.json> <udid>", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        print(f"unable to read devicectl device facts: {error}", file=sys.stderr)
        return 2

    identifier = sys.argv[2]
    device = next(
        (
            candidate
            for candidate in walk(document)
            if isinstance(candidate, dict)
            and any(candidate.get(key) == identifier for key in ("identifier", "udid", "deviceIdentifier"))
        ),
        None,
    )
    if device is None:
        print(f"devicectl did not return device facts for {identifier}", file=sys.stderr)
        return 2

    # Keep the output tab-delimited and single-line so the shell can safely
    # consume it without eval or generated shell code.
    facts = (
        first_value(device, ("name", "deviceName", "displayName")),
        first_value(device, ("productType", "modelIdentifier", "hardwareModel")),
        first_value(device, ("productVersion", "osVersion", "operatingSystemVersion")),
        first_value(device, ("osBuildVersion", "osBuild", "buildVersion", "operatingSystemBuild")),
    )
    if any("\t" in value or "\n" in value for value in facts):
        print("devicectl device facts contain unsafe control characters", file=sys.stderr)
        return 2
    missing = ("model/name", "model identifier", "OS version", "OS build")
    absent = [label for label, value in zip(missing, facts) if not value]
    if absent:
        print("devicectl device facts are incomplete: " + ", ".join(absent), file=sys.stderr)
        return 2
    print("\t".join(facts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Offline repository checks that catch silent drift CI would otherwise miss.

1. The Xcode simulator test host keeps an explicit source list, so a new
   Swift test file compiles under SwiftPM while silently missing from the
   host's test target. Report that drift.
2. Every third-party GitHub Action must be pinned to a full commit SHA.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ACTION_RE = re.compile(r"^\s*-?\s*uses:\s+[^\s@]+@([^\s#]+)")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def audit_xcode_test_sources(root: Path, errors: list[str]) -> None:
    test_root = root / "Tests/AppLocalVoiceTests"
    project = root / "Testing/AppLocalVoice.xcodeproj/project.pbxproj"
    if not test_root.is_dir() or not project.is_file():
        return
    text = project.read_text(encoding="utf-8")
    match = re.search(
        r"/\* Begin PBXSourcesBuildPhase section \*/(?P<section>.*?)/\* End PBXSourcesBuildPhase section \*/",
        text,
        flags=re.DOTALL,
    )
    if match is None:
        errors.append("Testing/AppLocalVoice.xcodeproj has no sources build phase")
        return
    test_sources = match.group("section")
    for source in sorted(test_root.glob("*.swift")):
        if f"/* {source.name} in Sources */" not in test_sources:
            errors.append(
                f"Testing/AppLocalVoice.xcodeproj omits test source: {source.relative_to(root)}"
            )
    for name in re.findall(r"/\* (\w+\.swift) in Sources \*/", test_sources):
        if not (test_root / name).is_file() and not (root / "Testing" / name).is_file():
            errors.append(f"Testing/AppLocalVoice.xcodeproj references a missing source: {name}")


def audit_action_pins(root: Path, errors: list[str]) -> None:
    for workflow in sorted((root / ".github/workflows").glob("*.yml")):
        for number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
            match = ACTION_RE.match(line)
            if match and not SHA_RE.fullmatch(match.group(1)):
                errors.append(
                    f"{workflow.relative_to(root)}:{number}: action is not pinned to a full commit SHA"
                )


def audit(root: Path) -> list[str]:
    errors: list[str] = []
    audit_xcode_test_sources(root, errors)
    audit_action_pins(root, errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    args = parser.parse_args()
    errors = audit(args.root.resolve())
    if errors:
        print("Repository lint failed:", file=sys.stderr)
        print("\n".join(f"- {item}" for item in errors), file=sys.stderr)
        return 1
    print("Repository lint OK: Xcode test host sources and workflow action pins checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

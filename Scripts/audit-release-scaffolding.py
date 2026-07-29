#!/usr/bin/env python3
"""Audit first-release repository scaffolding without contacting a Git host.

The default mode checks only facts that are available in a source checkout.
``--require-host`` is intentionally stricter and is for the maintainer's
promotion run after a real Git repository, remote, and owner identities exist.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


REQUIRED_FILES = (
    "README.md",
    "CONTRIBUTING.md",
    "RELEASING.md",
    "LICENSE",
    "SECURITY.md",
    "CODE_OF_CONDUCT.md",
    "CHANGELOG.md",
    ".github/CODEOWNERS",
    ".github/workflows/test.yml",
    ".github/workflows/release-validation.yml",
    "Scripts/create-source-archive.sh",
    "HARDENING_TRACKER.md",
    "Documentation/ReleaseAudit.md",
    "Documentation/ReleaseChecklist.md",
)

ACTION_RE = re.compile(r"^\s*-?\s*uses:\s+[^\s@]+@([^\s#]+)")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def git_output(root: Path, *arguments: str) -> str | None:
    try:
        return subprocess.check_output(
            ["git", *arguments], cwd=root, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def audit_xcode_test_sources(root: Path, errors: list[str]) -> None:
    """Ensure the importable Xcode host does not silently omit test files.

    The host project intentionally keeps its test source phase explicit. That
    is portable and predictable, but it also means a newly added Swift test
    can compile under SwiftPM while being absent from the Xcode demo target.
    Treat that drift as a scaffolding error instead of allowing the reference
    project to report a deceptively smaller test suite.
    """
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
        marker = f"/* {source.name} in Sources */"
        if marker not in test_sources:
            errors.append(
                f"Testing/AppLocalVoice.xcodeproj omits test source: {source.relative_to(root)}"
            )


def audit(root: Path, require_host: bool = False) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    open_items: list[str] = []

    for relative in REQUIRED_FILES:
        path = root / relative
        if not path.is_file():
            errors.append(f"missing required release file: {relative}")

    archive = root / "Scripts/create-source-archive.sh"
    if archive.is_file() and not archive.stat().st_mode & 0o111:
        errors.append("source archive helper is not executable: Scripts/create-source-archive.sh")

    audit_xcode_test_sources(root, errors)

    for workflow in sorted((root / ".github/workflows").glob("*.yml")):
        for line_number, line in enumerate(workflow.read_text(encoding="utf-8").splitlines(), 1):
            match = ACTION_RE.match(line)
            if match and not SHA_RE.fullmatch(match.group(1)):
                errors.append(f"{workflow.relative_to(root)}:{line_number}: action is not pinned to a full commit SHA")

    codeowners = root / ".github/CODEOWNERS"
    if codeowners.is_file():
        owner_lines = [
            line for line in codeowners.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        if not owner_lines:
            errors.append(".github/CODEOWNERS has no active rules")
        elif any("@maintainers" in line for line in owner_lines):
            open_items.append(".github/CODEOWNERS still uses the @maintainers placeholder")

    if not (root / ".git").exists():
        open_items.append("no local Git repository is present")
    elif not git_output(root, "remote", "get-url", "origin"):
        open_items.append("no Git remote named origin is configured")

    releasing = root / "RELEASING.md"
    if releasing.is_file():
        text = releasing.read_text(encoding="utf-8")
        for phrase in ("Git-host requirements", "physical-device", "previous release"):
            if phrase not in text:
                errors.append(f"RELEASING.md does not explicitly cover: {phrase}")

    if require_host:
        if not (root / ".git").exists():
            errors.append("host release audit requires a real Git repository")
        elif not git_output(root, "remote", "get-url", "origin"):
            errors.append("host release audit requires an origin remote")
        if codeowners.is_file() and any(
            "@maintainers" in line for line in codeowners.read_text(encoding="utf-8").splitlines()
        ):
            errors.append("host release audit requires CODEOWNERS to name real maintainers")

    return errors, open_items


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--require-host", action="store_true", help="also require Git remote and real CODEOWNERS identities")
    args = parser.parse_args()
    errors, open_items = audit(args.root.resolve(), args.require_host)
    for item in open_items:
        print(f"OPEN: {item}")
    if errors:
        print("Release scaffolding audit failed:", file=sys.stderr)
        print("\n".join(f"- {item}" for item in errors), file=sys.stderr)
        return 1
    print("Release scaffolding OK: local release files, workflows, and safeguards checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate repository-relative Markdown links offline.

This checker is intentionally offline. External URLs are syntax-checked only
as URLs and are never fetched; repository-relative destinations must resolve to
files or directories in the checkout.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse


LINK_RE = re.compile(r"!?(?P<open>\[[^\]]*\])\((?P<destination>[^)]*)\)")
REFERENCE_RE = re.compile(r"^ {0,3}\[[^\]]+\]:\s*(?P<destination><[^>]*>|\S+)", re.MULTILINE)
HEADING_RE = re.compile(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", re.MULTILINE)
FENCE_RE = re.compile(r"^ {0,3}(```+|~~~+)", re.MULTILINE)


@dataclass(frozen=True)
class Link:
    source: Path
    line: int
    destination: str


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def without_fenced_code(text: str) -> str:
    lines = text.splitlines(keepends=True)
    in_fence = False
    fence_char = ""
    result: list[str] = []
    for line in lines:
        match = re.match(r"^ {0,3}(```+|~~~+)", line)
        if match:
            marker = match.group(1)
            if not in_fence:
                in_fence, fence_char = True, marker[0]
            elif marker[0] == fence_char:
                in_fence = False
            result.append("\n" if line.endswith("\n") else "")
        elif in_fence:
            result.append("\n" if line.endswith("\n") else "")
        else:
            result.append(line)
    return "".join(result)


def links_in(path: Path) -> list[Link]:
    text = without_fenced_code(path.read_text(encoding="utf-8"))
    links = [
        Link(path, line_number(text, match.start()), match.group("destination").strip())
        for match in LINK_RE.finditer(text)
    ]
    links.extend(
        Link(path, line_number(text, match.start()), match.group("destination").strip())
        for match in REFERENCE_RE.finditer(text)
    )
    return links


def github_fragment(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value).lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return re.sub(r"\s+", "-", value.strip())


def local_destination(destination: str) -> tuple[str, str] | None:
    if not destination or destination.startswith("#"):
        return ("", destination[1:]) if destination.startswith("#") else None
    if destination.startswith("<"):
        if not destination.endswith(">"):
            return None
        destination = destination[1:-1]
    parsed = urlparse(destination)
    if parsed.scheme or parsed.netloc:
        return None
    path = unquote(parsed.path)
    if path.startswith("/"):
        return ("/" + path.lstrip("/"), parsed.fragment)
    return (path, parsed.fragment)


def validate_links(root: Path, markdown: list[Path]) -> list[str]:
    errors: list[str] = []
    for source in markdown:
        headings = {
            github_fragment(match.group(1)) for match in HEADING_RE.finditer(source.read_text(encoding="utf-8"))
        }
        for link in links_in(source):
            raw = link.destination
            if raw.startswith("<") and ">" not in raw:
                errors.append(f"{link.source.relative_to(root)}:{link.line}: malformed local link destination {raw!r}")
                continue
            parsed = urlparse(raw.strip("<>").split("#", 1)[0])
            if parsed.scheme in {"http", "https", "mailto", "tel"} or raw.startswith("//"):
                continue
            local = local_destination(raw)
            if local is None:
                errors.append(f"{link.source.relative_to(root)}:{link.line}: malformed local link {raw!r}")
                continue
            path_part, fragment = local
            target = source.parent if not path_part else (root / path_part.lstrip("/") if path_part.startswith("/") else source.parent / path_part)
            target = target.resolve()
            try:
                target.relative_to(root.resolve())
            except ValueError:
                errors.append(f"{link.source.relative_to(root)}:{link.line}: link escapes repository {raw!r}")
                continue
            if not target.exists():
                errors.append(f"{link.source.relative_to(root)}:{link.line}: missing local target {raw!r}")
                continue
            if fragment and target.is_file() and target.suffix.lower() == ".md":
                target_headings = {
                    github_fragment(match.group(1))
                    for match in HEADING_RE.finditer(target.read_text(encoding="utf-8"))
                }
                if fragment.lower() not in target_headings:
                    errors.append(f"{link.source.relative_to(root)}:{link.line}: missing fragment {fragment!r} in {target.relative_to(root)}")
            elif fragment and target == source and fragment.lower() not in headings:
                errors.append(f"{link.source.relative_to(root)}:{link.line}: missing fragment {fragment!r}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."), help="repository root (default: current directory)")
    args = parser.parse_args()
    root = args.root.resolve()
    # Repository documentation only: skip build products, package checkouts,
    # and other hidden directories.
    markdown = sorted(
        path for path in root.rglob("*.md")
        if not any(part.startswith(".") for part in path.relative_to(root).parts[:-1])
    )
    errors = validate_links(root, markdown)
    if errors:
        print("Documentation validation failed:", file=sys.stderr)
        print("\n".join(f"- {error}" for error in errors), file=sys.stderr)
        return 1
    print(f"Documentation OK: {len(markdown)} Markdown files, local links checked offline")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

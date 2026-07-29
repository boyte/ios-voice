#!/usr/bin/env python3
"""Create a deterministic, portable, hashed release-evidence manifest.

The manifest is deliberately produced by a small standard-library-only tool.
It fails closed: a successful manifest means every requested input existed,
was a regular file or directory, and contributed at least one hashed file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
from datetime import datetime, timezone


class ManifestError(ValueError):
    """A requested manifest input or metadata value is invalid."""


def run_command(arguments: list[str]) -> str | None:
    """Return trimmed command output, or ``None`` when the command is absent."""

    try:
        return subprocess.check_output(
            arguments, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def git_revision() -> str:
    return run_command(["git", "rev-parse", "HEAD"]) or "unpublished-worktree"


def git_clean() -> bool | None:
    if not shutil.which("git"):
        return None
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout == ""


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def absolute_without_following_symlinks(path: pathlib.Path) -> pathlib.Path:
    return pathlib.Path(os.path.abspath(os.fspath(path)))


def validate_root(path: pathlib.Path, label: str) -> pathlib.Path:
    """Validate an input root without following a symlink at its boundary."""

    path = absolute_without_following_symlinks(path)
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise ManifestError(f"{label} does not exist: {path}") from error
    if path.is_symlink():
        raise ManifestError(f"{label} must not be a symlink: {path}")
    if not (path.is_file() or path.is_dir()):
        raise ManifestError(f"{label} is not a regular file or directory: {path}")
    # Keep the lstat result live in this function: the explicit check above is
    # intentional, even though Path.is_file/is_dir use stat semantics.
    if mode == 0:
        raise ManifestError(f"{label} has invalid file metadata: {path}")
    return path


def files_for(path: pathlib.Path, label: str) -> list[pathlib.Path]:
    """Return regular files under an input, rejecting unsafe entries."""

    path = validate_root(path, label)
    if path.is_file():
        if path.stat().st_size == 0:
            raise ManifestError(f"{label} is empty: {path}")
        return [path]

    files: list[pathlib.Path] = []
    for child in sorted(path.rglob("*"), key=lambda item: os.fspath(item)):
        if child.is_symlink():
            raise ManifestError(f"{label} contains a symlink: {child}")
        if child.is_dir():
            continue
        if not child.is_file():
            raise ManifestError(f"{label} contains a non-regular file: {child}")
        if child.stat().st_size == 0:
            raise ManifestError(f"{label} contains an empty file: {child}")
        files.append(child)
    if not files:
        raise ManifestError(f"{label} is empty: {path}")
    return files


def portable_path(path: pathlib.Path, root: pathlib.Path) -> str:
    """Return a stable logical path without exposing the host's absolute path."""

    try:
        return pathlib.PurePosixPath(path.relative_to(root)).as_posix()
    except ValueError:
        return pathlib.PurePosixPath("external", path.name).as_posix()


def artifact_record(
    requested: pathlib.Path, child: pathlib.Path, root: pathlib.Path
) -> dict[str, int | str]:
    if requested.is_file():
        logical = portable_path(requested, root)
    else:
        try:
            suffix = child.relative_to(requested)
        except ValueError as error:
            raise ManifestError(f"artifact escaped its root: {child}") from error
        base = portable_path(requested, root)
        logical = pathlib.PurePosixPath(base, suffix.as_posix()).as_posix()
    stat = child.stat()
    return {"bytes": stat.st_size, "path": logical, "sha256": sha256(child)}


def generated_at(explicit: str | None) -> str:
    if explicit:
        try:
            parsed = datetime.fromisoformat(explicit.replace("Z", "+00:00"))
        except ValueError as error:
            raise ManifestError("--generated-at must be an ISO-8601 timestamp") from error
        if parsed.tzinfo is None:
            raise ManifestError("--generated-at must include a timezone")
        return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

    value = os.environ.get("SOURCE_DATE_EPOCH")
    if value:
        try:
            timestamp = datetime.fromtimestamp(int(value), tz=timezone.utc)
        except (ValueError, OverflowError, OSError) as error:
            raise ManifestError("SOURCE_DATE_EPOCH must be an integer Unix timestamp") from error
        return timestamp.isoformat().replace("+00:00", "Z")
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def referenced_file(path: pathlib.Path, label: str, root: pathlib.Path) -> dict[str, int | str]:
    path = validate_root(path, label)
    files = files_for(path, label)
    if len(files) != 1 or files[0] != path:
        raise ManifestError(f"{label} must be one non-empty regular file: {path}")
    stat = path.stat()
    return {
        "bytes": stat.st_size,
        "path": portable_path(path, root),
        "sha256": sha256(path),
    }


def metadata_value(explicit: str | None, fallback: str, label: str) -> str:
    """Use an explicit metadata value, rejecting empty provenance."""

    if explicit is None:
        return fallback
    value = explicit.strip()
    if not value:
        raise ManifestError(f"--{label} must not be empty")
    return value


def provenance(
    *,
    toolchain: str | None = None,
    sdk: str | None = None,
    runtime: str | None = None,
    os_build: str | None = None,
) -> dict[str, object]:
    detected_sdk = os.environ.get("SDK_VERSION")
    if not detected_sdk and shutil.which("xcrun"):
        detected_sdk = run_command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
    detected_toolchain = (
        run_command(["xcodebuild", "-version"])
        if shutil.which("xcodebuild")
        else "unknown"
    )
    return {
        "architecture": platform.machine(),
        "xcode": metadata_value(toolchain, detected_toolchain or "unknown", "toolchain"),
        "macOS": platform.mac_ver()[0] or "unknown",
        "sdk": metadata_value(sdk, detected_sdk or "unknown", "sdk"),
        "swift": run_command(["swift", "--version"]) or "unknown",
        "simulatorRuntime": metadata_value(
            runtime, os.environ.get("SIMULATOR_RUNTIME", "unknown"), "runtime"
        ),
        "simulatorOSBuild": metadata_value(
            os_build, os.environ.get("SIMULATOR_OS_BUILD", "unknown"), "os-build"
        ),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--artifact", action="append", type=pathlib.Path, default=[])
    parser.add_argument("--status", default="unknown")
    parser.add_argument("--destination", default="")
    parser.add_argument("--source-revision", help="source revision represented by the artifacts")
    parser.add_argument("--toolchain", help="exact toolchain version used to produce the artifacts")
    parser.add_argument("--sdk", help="exact SDK version used to produce the artifacts")
    parser.add_argument("--runtime", help="simulator runtime used to produce the artifacts")
    parser.add_argument("--os-build", help="simulator OS build used to produce the artifacts")
    parser.add_argument("--evidence-kind", help="kind of evidence represented by the manifest")
    parser.add_argument("--test-inventory", type=pathlib.Path)
    parser.add_argument("--api-symbol-graph", type=pathlib.Path)
    parser.add_argument(
        "--generated-at",
        help="ISO-8601 timestamp (UTC or with offset); SOURCE_DATE_EPOCH is used otherwise",
    )
    parser.add_argument(
        "--require-clean-git",
        action="store_true",
        help="fail unless the current checkout is a clean Git worktree",
    )
    return parser.parse_args()


def main() -> int:
    try:
        args = parse_args()
        output = absolute_without_following_symlinks(args.output)
        root = pathlib.Path.cwd().resolve()

        if not args.artifact:
            raise ManifestError("at least one --artifact input is required")

        artifact_roots: list[pathlib.Path] = []
        seen_roots: set[pathlib.Path] = set()
        for index, requested in enumerate(args.artifact, start=1):
            path = validate_root(requested, f"artifact #{index}")
            if path in seen_roots:
                raise ManifestError(f"duplicate artifact input: {path}")
            seen_roots.add(path)
            artifact_roots.append(path)

        for artifact_root in artifact_roots:
            if artifact_root.is_dir() and (output == artifact_root or artifact_root in output.parents):
                raise ManifestError(
                    f"output must not be inside an artifact directory: {output}"
                )
            if artifact_root.is_file() and output == artifact_root:
                raise ManifestError(f"output must not replace an artifact: {output}")

        # References are validated independently because a referenced file may
        # also intentionally be included in the artifact evidence list.
        inventory = (
            referenced_file(args.test_inventory, "test inventory", root)
            if args.test_inventory
            else None
        )
        symbol_graph = (
            referenced_file(args.api_symbol_graph, "API symbol graph", root)
            if args.api_symbol_graph
            else None
        )

        records: list[dict[str, int | str]] = []
        seen_record_paths: set[str] = set()
        for index, requested in enumerate(artifact_roots, start=1):
            for child in files_for(requested, f"artifact #{index}"):
                record = artifact_record(requested, child, root)
                logical = str(record["path"])
                if logical in seen_record_paths:
                    raise ManifestError(f"duplicate manifest path: {logical}")
                seen_record_paths.add(logical)
                records.append(record)
        records.sort(key=lambda record: str(record["path"]))

        clean = git_clean()
        if args.require_clean_git and clean is not True:
            raise ManifestError("--require-clean-git requires a clean Git worktree")

        source_revision = metadata_value(
            args.source_revision, git_revision(), "source-revision"
        )
        environment = provenance(
            toolchain=args.toolchain,
            sdk=args.sdk,
            runtime=args.runtime,
            os_build=args.os_build,
        )
        evidence_kind = metadata_value(args.evidence_kind, "unknown", "evidence-kind")
        manifest = {
            "apiSymbolGraph": symbol_graph["path"] if symbol_graph else None,
            "apiSymbolGraphBytes": symbol_graph["bytes"] if symbol_graph else None,
            "apiSymbolGraphSha256": symbol_graph["sha256"] if symbol_graph else None,
            "artifacts": records,
            "destination": args.destination,
            "generatedAt": generated_at(args.generated_at),
            "gitClean": clean,
            "schemaVersion": 2,
            "sourceRevision": source_revision,
            "status": args.status,
            "testInventory": inventory["path"] if inventory else None,
            "testInventoryBytes": inventory["bytes"] if inventory else None,
            "testInventorySha256": inventory["sha256"] if inventory else None,
            "toolchain": environment["xcode"],
            "sdk": environment["sdk"],
            "runtime": environment["simulatorRuntime"],
            "osBuild": environment["simulatorOSBuild"],
            "evidenceKind": evidence_kind,
            "provenance": environment,
        }
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"wrote artifact manifest: {output}")
        print(f"manifested files: {len(records)}")
        return 0
    except ManifestError as error:
        print(f"create-artifact-manifest: error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Deterministically sanitize a text release-evidence log.

The sanitizer is intentionally line-oriented.  It preserves diagnostic line
order, normalizes private paths and usernames, and replaces a whole line when
the line appears to contain speech payload or credentials.  It never attempts
to paraphrase, reconstruct, or partially redact those payloads.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import sys
from dataclasses import dataclass


DEFAULT_MAX_BYTES = 10 * 1024 * 1024
REDACTION = "[REDACTED: {kind}]"

_ABSOLUTE_PATH = re.compile(
    r"(?:/(?:Users|home|private|var|tmp|etc|opt|Volumes|Applications)"
    r"(?:/[A-Za-z0-9._~-]+)*|/[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)+"
    r"|[A-Za-z]:\\(?:Users|Windows|ProgramData)(?:\\[A-Za-z0-9._~-]+)+)",
    re.IGNORECASE,
)
_USERNAME = re.compile(
    r"(?<![A-Za-z0-9])(?:user(?:name)?|account|login)\s*[=:]\s*['\"]?([A-Za-z][A-Za-z0-9._-]{1,63})",
    re.IGNORECASE,
)
_SPEECH = re.compile(
    r"(?:raw\s+(?:audio|microphone)|audio\s+payload|(?:raw\s+)?transcri(?:pt|ption)|"
    r"utterance|speech\s+(?:text|content|payload)|tts\s+(?:text|content|payload)|"
    r"spoken\s+text|recognized\s+(?:text|speech)|dictation\s+(?:text|result))",
    re.IGNORECASE,
)
_CREDENTIAL = re.compile(
    r"(?:api[_ -]?key|access[_ -]?token|auth(?:orization)?\s*[:=]|bearer\s+[A-Za-z0-9._-]+|"
    r"client[_ -]?secret|cookie\s*[:=]|password\s*[:=]|private[_ -]?key|secret[_ -]?key|"
    r"session[_ -]?token|(?:token|credential|secret)\s*[:=]|-----BEGIN|"
    r"(?:sk|gh[opsu])_[A-Za-z0-9]{12,}|AKIA[0-9A-Z]{16})",
    re.IGNORECASE,
)
_DEVICE_UDID = re.compile(
    r"(?:\b(?:udid|device(?:\s+(?:udid|identifier))?)\b\s*[:=]\s*"
    r"|\bdestination\b.*?\bid\s*[:=]\s*)[A-Fa-f0-9]{40}\b",
    re.IGNORECASE,
)
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


class SanitizationError(ValueError):
    """The input is not a supported, safe text log."""


@dataclass(frozen=True)
class Summary:
    lines: int
    paths: int
    usernames: int
    speech_redactions: int
    credential_redactions: int
    device_identifier_redactions: int

    def render(self) -> str:
        return (
            "sanitized evidence log: "
            f"lines={self.lines} paths={self.paths} usernames={self.usernames} "
            f"speech_redactions={self.speech_redactions} "
            f"credential_redactions={self.credential_redactions} "
            f"device_identifier_redactions={self.device_identifier_redactions}"
        )


def _validate_text(data: bytes, max_bytes: int) -> str:
    if not data:
        raise SanitizationError("input is empty")
    if len(data) > max_bytes:
        raise SanitizationError(f"input exceeds maximum size of {max_bytes} bytes")
    if b"\x00" in data:
        raise SanitizationError("input contains NUL bytes and is not a text log")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SanitizationError(f"input is not valid UTF-8: {error}") from error
    if _CONTROL.search(text):
        raise SanitizationError("input contains binary/control bytes")
    return text


def _replace_path(match: re.Match[str]) -> str:
    value = match.group(0)
    # Keep a stable, non-private class marker.  Do not retain path components,
    # because a component can itself identify a user or checkout.
    if re.match(r"[A-Za-z]:\\", value):
        return "<PRIVATE_PATH>"
    return "<PRIVATE_PATH>"


def _sanitize_line(line: str) -> tuple[str, int, int, int, int, int]:
    speech = int(bool(_SPEECH.search(line)))
    credential = int(bool(_CREDENTIAL.search(line)))
    device_identifier = int(bool(_DEVICE_UDID.search(line)))
    if speech or credential or device_identifier:
        kinds = []
        if speech:
            kinds.append("SPEECH_CONTENT")
        if credential:
            kinds.append("CREDENTIAL")
        if device_identifier:
            kinds.append("DEVICE_IDENTIFIER")
        return REDACTION.format(kind="+".join(kinds)), 0, 0, speech, credential, device_identifier

    path_count = len(_ABSOLUTE_PATH.findall(line))
    line = _ABSOLUTE_PATH.sub(_replace_path, line)
    username_count = len(_USERNAME.findall(line))
    line = _USERNAME.sub(lambda match: match.group(0)[: match.group(0).find(match.group(1))] + "<USERNAME>", line)
    return line, path_count, username_count, 0, 0, 0


def sanitize_text(text: str) -> tuple[str, Summary]:
    """Return sanitized text and deterministic counts.

    ``splitlines(keepends=True)`` preserves line order and each original line's
    newline style.  A redacted line deliberately has no trailing diagnostic
    payload, but retains its original newline.
    """
    output: list[str] = []
    paths = usernames = speech = credentials = device_identifiers = 0
    lines = text.splitlines(keepends=True)
    for line in lines:
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        sanitized, path_count, username_count, speech_count, credential_count, device_identifier_count = _sanitize_line(body)
        output.append(sanitized + ending)
        paths += path_count
        usernames += username_count
        speech += speech_count
        credentials += credential_count
        device_identifiers += device_identifier_count
    return "".join(output), Summary(len(lines), paths, usernames, speech, credentials, device_identifiers)


def sanitize_file(input_path: pathlib.Path, output_path: pathlib.Path | None, max_bytes: int) -> Summary:
    try:
        info = input_path.lstat()
    except OSError as error:
        raise SanitizationError(f"cannot read input {input_path}: {error}") from error
    if input_path.is_symlink() or not input_path.is_file():
        raise SanitizationError("input must be a regular, non-symlink file")
    if output_path is not None and input_path.resolve() == output_path.resolve():
        raise SanitizationError("output must differ from input")
    try:
        data = input_path.read_bytes()
        text = _validate_text(data, max_bytes)
        sanitized, summary = sanitize_text(text)
        if output_path is None:
            sys.stdout.write(sanitized)
        else:
            if output_path.exists() and output_path.is_symlink():
                raise SanitizationError("output must not be a symlink")
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(sanitized.encode("utf-8"))
    except OSError as error:
        raise SanitizationError(f"cannot process log: {error}") from error
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=pathlib.Path, help="text log to sanitize")
    parser.add_argument("output_positional", nargs="?", type=pathlib.Path, help="optional sanitized output path")
    parser.add_argument("-o", "--output", type=pathlib.Path, help="write sanitized log to this path")
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    args = parser.parse_args(argv)
    if args.max_bytes <= 0:
        parser.error("--max-bytes must be positive")
    if args.output and args.output_positional:
        parser.error("provide output either positionally or with --output, not both")
    output = args.output or args.output_positional
    try:
        summary = sanitize_file(args.input, output, args.max_bytes)
    except SanitizationError as error:
        print(f"evidence log sanitization failed: {error}", file=sys.stderr)
        return 2
    print(summary.render(), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Validate the files that make the Local Echo project portable.

This intentionally uses only the Python standard library so it can run before
Xcode resolves the package graph. It checks project wiring and metadata, not a
compiled app or device behavior.
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "LocalEcho.xcodeproj" / "project.pbxproj"
SCHEME = ROOT / "LocalEcho.xcodeproj" / "xcshareddata" / "xcschemes" / "LocalEcho.xcscheme"
PLIST = ROOT / "Info.plist"
PACKAGE = ROOT.parent.parent / "Package.swift"
SOURCES = ("LocalEchoApp.swift", "LocalEchoModel.swift", "LocalEchoView.swift")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    for path in (PROJECT, SCHEME, PLIST, PACKAGE, *(ROOT / name for name in SOURCES)):
        require(path.is_file(), f"missing required file: {path}")

    project = PROJECT.read_text(encoding="utf-8")
    scheme = SCHEME.read_text(encoding="utf-8")
    view = (ROOT / "LocalEchoView.swift").read_text(encoding="utf-8")
    model = (ROOT / "LocalEchoModel.swift").read_text(encoding="utf-8")
    with PLIST.open("rb") as stream:
        info = plistlib.load(stream)

    require("relativePath = ../..;" in project, "package reference is not portable relative ../../")
    require("productName = AppLocalVoice;" in project, "AppLocalVoice product is not linked")
    require("packageProductDependencies = (" in project, "target has no package product dependencies")
    require("packageReferences = (" in project, "project has no local package reference")
    require("IPHONEOS_DEPLOYMENT_TARGET = 26.0;" in project, "project is not targeting iOS 26")
    require("SWIFT_VERSION = 6.0;" in project, "project is not using Swift 6")
    require("INFOPLIST_FILE = Info.plist;" in project, "target does not use the example Info.plist")
    require("PRODUCT_BUNDLE_IDENTIFIER = com.example.LocalEcho;" in project, "unexpected bundle identifier")

    for source in SOURCES:
        require(f"path = {source};" in project, f"{source} is not in the Xcode project")
        require(f"/* {source} in Sources */" in project, f"{source} is not in the sources build phase")

    require('BlueprintName = "LocalEcho"' in scheme, "shared scheme does not build LocalEcho")
    require("LocalEcho.app" in scheme, "shared scheme has no LocalEcho app product")
    require(info.get("NSMicrophoneUsageDescription"), "missing NSMicrophoneUsageDescription")
    require(info.get("NSSpeechRecognitionUsageDescription"), "missing NSSpeechRecognitionUsageDescription")
    for control in ("Listen", "End", "Cancel", "Speak", "Pause", "Resume", "Stop"):
        require(f'Button("{control}"' in view, f"reference UI is missing the {control} control")
    require("modelStatus" in view, "reference UI does not show on-device model status")
    require("allowModelInstallation" in model, "reference model does not demonstrate explicit model installation policy")
    require("availableVoices" in model, "reference model does not inspect the installed voice catalog")
    require(PACKAGE.read_text(encoding="utf-8").count(".library(name: \"AppLocalVoice\"") == 1,
            "package does not expose exactly one AppLocalVoice library product")

    print("Local Echo structural validation passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, plistlib.InvalidFileException, UnicodeError) as error:
        print(f"Local Echo structural validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)

#!/usr/bin/env python3
"""Validate an Apple distribution export and prepare public GitHub assets.

This deliberately rejects development/ad-hoc profiles that enumerate device IDs.
It does not sign, install, upload, or mutate the application bundles.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

EXPECTED = {
    "com.wristassistant.app": [1],
    "com.wristassistant.app.watchkitapp": [4],
    "com.wristassistant.app.watchkitapp.widgets": [4],
}


def run(*arguments: str) -> bytes:
    return subprocess.check_output(arguments, stderr=subprocess.PIPE)


def validate_bundle(app: Path, version: str, build: str) -> dict:
    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    identifier = info.get("CFBundleIdentifier")
    if identifier not in EXPECTED:
        raise ValueError(f"Unexpected application bundle: {identifier}")
    if str(info.get("CFBundleShortVersionString")) != version or str(info.get("CFBundleVersion")) != build:
        raise ValueError(f"Version/build mismatch in {identifier}")
    if info.get("UIDeviceFamily") != EXPECTED[identifier]:
        raise ValueError(f"Unexpected device family in {identifier}: {info.get('UIDeviceFamily')}")
    profile = plistlib.loads(run("security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")))
    entitlements = profile.get("Entitlements", {})
    if profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices") or entitlements.get("get-task-allow"):
        raise ValueError(f"Refusing to publish a development/ad-hoc/enterprise profile in {identifier}")
    if entitlements.get("application-identifier") != f"W6DM8CHQA7.{identifier}":
        raise ValueError(f"Unexpected profile application identity in {identifier}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    signature = subprocess.run(["codesign", "-d", "--verbose=4", str(app)], check=True,
                               capture_output=True, text=True).stderr
    team = re.search(r"^TeamIdentifier=(.+)$", signature, re.MULTILINE)
    if not team or team.group(1) != "W6DM8CHQA7":
        raise ValueError(f"Unexpected signing team in {identifier}")
    cdhash = re.search(r"^CDHash=(.+)$", signature, re.MULTILINE)
    return {"bundleIdentifier": identifier, "version": version, "build": build,
            "deviceFamily": info["UIDeviceFamily"], "signingTeam": team.group(1),
            "cdHash": cdhash.group(1) if cdhash else None,
            "profileType": "App Store distribution"}


def collect_bundles(root: Path) -> list[Path]:
    watch = root / "Watch" / "WristAssistantWatch.app"
    widget = watch / "PlugIns" / "WristAssistantWatchWidgets.appex"
    if not watch.is_dir() or not widget.is_dir():
        raise ValueError("The combined app is missing its embedded Watch app or widget")
    return [root, watch, widget]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--export", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--include-symbols", action="store_true")
    parser.add_argument("--include-archive", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.version) or not args.build.isdecimal():
        parser.error("Version and build must be numeric")
    if not re.fullmatch(r"[a-fA-F0-9]{40,64}", args.commit):
        parser.error("Supply the full committed source revision")
    ipa_files = list(args.export.glob("*.ipa"))
    if len(ipa_files) != 1:
        raise ValueError("Expected exactly one newly exported IPA")
    ipa = ipa_files[0]
    args.output.mkdir(parents=True, exist_ok=True)
    if any(args.output.iterdir()):
        raise ValueError("Refusing to mix release artifacts into a nonempty output directory")
    prefix = f"WristChatUI-{args.version}-{args.build}"
    # Documents may be managed by FileProvider, which can attach unsigned Finder
    # metadata after Xcode signs an otherwise valid app. Verify a clean copy in
    # local temporary storage, preserving every signed byte in the original.
    with tempfile.TemporaryDirectory(prefix="wristchatui-release-") as directory:
        temporary = Path(directory)
        staged_archive = temporary / args.archive.name
        subprocess.run(["ditto", "--noextattr", "--noqtn", str(args.archive), str(staged_archive)], check=True)
        subprocess.run(["/usr/bin/xattr", "-cr", str(staged_archive)], check=True)
        archive_apps = list((staged_archive / "Products" / "Applications").glob("*.app"))
        if len(archive_apps) != 1:
            raise ValueError("Expected one combined iPhone application in the archive")
        for app in collect_bundles(archive_apps[0]):
            validate_bundle(app, args.version, args.build)

        unpacked = temporary / "exported"
        unpacked.mkdir()
        with zipfile.ZipFile(ipa) as package:
            for item in package.infolist():
                if item.filename.startswith("/") or ".." in Path(item.filename).parts:
                    raise ValueError("Unsafe archive member")
        subprocess.run(["ditto", "-x", "-k", str(ipa), str(unpacked)], check=True)
        subprocess.run(["/usr/bin/xattr", "-cr", str(unpacked)], check=True)
        apps = list((unpacked / "Payload").glob("*.app"))
        if len(apps) != 1:
            raise ValueError("Expected one iPhone application in the exported IPA")
        bundles = collect_bundles(apps[0])
        metadata = [validate_bundle(app, args.version, args.build) for app in bundles]
        shutil.copyfile(ipa, args.output / f"{prefix}-iOS-with-watchOS.ipa")
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(bundles[1]),
                        str(args.output / f"{prefix}-watchOS.app.zip")], check=True)
        if args.include_symbols:
            symbols = staged_archive / "dSYMs"
            if not symbols.is_dir():
                raise ValueError("Archive has no dSYMs")
            subprocess.run(["ditto", "-c", "-k", "--keepParent", str(symbols),
                            str(args.output / f"{prefix}-dSYMs.zip")], check=True)
        if args.include_archive:
            subprocess.run(["ditto", "-c", "-k", "--keepParent", str(staged_archive),
                            str(args.output / f"{prefix}.xcarchive.zip")], check=True)
    manifest = {"product": "WristChatUI", "version": args.version, "build": args.build,
                "sourceCommit": args.commit, "distribution": "App Store distribution",
                "appBundles": metadata,
                "installation": "Distribution artifacts; not unrestricted sideload installers"}
    (args.output / "BUILD-INFO.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.output / "INSTALLATION.txt").write_text(
        "WristChatUI distribution artifacts\n\n"
        "The iOS IPA includes the paired Apple Watch application and widget.\n"
        "The standalone watchOS ZIP contains that same compiled Watch app for inspection/developer use.\n\n"
        "These are App Store-signed distribution products, not unrestricted sideload installers.\n"
        "For ordinary installation, use the App Store/TestFlight build when the publisher makes it available.\n"
        "Development installation requires your own valid Apple signing/provisioning and the paired iPhone.\n"
        "Do not uninstall an existing library to bypass a signing mismatch.\n\n"
        "BUILD-INFO.json identifies the source revision and matching bundle versions.\n"
        "SHA256SUMS.txt verifies these downloads. No development device IDs are embedded.\n"
    )
    checksums = []
    for path in sorted(args.output.iterdir()):
        if path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            checksums.append(f"{digest.hexdigest()}  {path.name}")
    (args.output / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n")
    print(f"Validated {len(EXPECTED)} matching distribution bundles; assets: {args.output}")


if __name__ == "__main__":
    main()

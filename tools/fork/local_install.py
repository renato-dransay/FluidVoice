#!/usr/bin/env python3
"""Install or restore a verified personal build, retaining a data and binary snapshot."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid

BUNDLE_ID = "com.renatobeltrao.fluidvoice.personal"
APP_NAME = "FluidVoice Personal.app"
DATA_NAME = "FluidVoice Personal"


def command(*args, check=True):
    result = subprocess.run(args, capture_output=True, check=False)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result


def verify_app(app):
    if not app.is_dir() or app.is_symlink():
        raise RuntimeError("A regular application bundle directory is required.")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise RuntimeError("Refusing to install a bundle with another application identity.")
    command("codesign", "--verify", "--deep", "--strict", str(app))
    signature = command("codesign", "--display", "--verbose=4", str(app))
    details = signature.stderr.decode(errors="replace")
    if "Authority=Apple Development:" not in details or "TeamIdentifier=" not in details:
        raise RuntimeError("A build signed with an Apple Development identity is required.")


def ensure_stopped():
    result = command("pgrep", "-x", "FluidVoice Personal", check=False)
    if result.returncode == 0:
        raise RuntimeError("Quit FluidVoice Personal before installing or restoring its data.")
    if result.returncode != 1:
        raise RuntimeError("Unable to verify that FluidVoice Personal is stopped.")


def copy_tree(source, destination):
    command("ditto", str(source), str(destination))


def replace_tree(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".fluidvoice-stage-", dir=destination.parent))
    incoming = staging / destination.name
    previous = staging / "previous"
    try:
        copy_tree(source, incoming)
        if destination.exists():
            destination.rename(previous)
        try:
            incoming.rename(destination)
        except BaseException:
            if previous.exists():
                previous.rename(destination)
            raise
    finally:
        shutil.rmtree(staging)


def snapshot(app, data, backup_root):
    backup_root.mkdir(parents=True, exist_ok=True)
    name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    backup = backup_root / name
    backup.mkdir(mode=0o700)
    if app.exists():
        verify_app(app)
        copy_tree(app, backup / APP_NAME)
    if data.exists():
        copy_tree(data, backup / "data")
    settings = command("defaults", "export", BUNDLE_ID, "-", check=False)
    has_settings = settings.returncode == 0
    if has_settings:
        (backup / "settings.plist").write_bytes(settings.stdout)
    elif (Path.home() / "Library/Preferences" / (BUNDLE_ID + ".plist")).exists():
        raise RuntimeError("Existing preferences could not be exported; installation stopped.")
    (backup / "snapshot.json").write_text(json.dumps({
        "bundle_id": BUNDLE_ID,
        "had_app": app.exists(),
        "had_data": data.exists(),
        "had_settings": has_settings,
    }, indent=2) + "\n")
    return backup


def install(source, destination, data, backup_root):
    ensure_stopped()
    verify_app(source)
    backup = snapshot(destination, data, backup_root)
    replace_tree(source, destination)
    verify_app(destination)
    return backup


def rollback(backup, destination, data, backup_root):
    ensure_stopped()
    metadata = json.loads((backup / "snapshot.json").read_text())
    if metadata.get("bundle_id") != BUNDLE_ID or not metadata.get("had_app"):
        raise RuntimeError("Choose a personal snapshot containing a previous app build.")
    source = backup / APP_NAME
    verify_app(source)
    rescue = snapshot(destination, data, backup_root)
    replace_tree(source, destination)
    if metadata["had_data"]:
        replace_tree(backup / "data", data)
    elif data.exists():
        shutil.rmtree(data)
    if metadata["had_settings"]:
        command("defaults", "import", BUNDLE_ID, str(backup / "settings.plist"))
    else:
        command("defaults", "delete", BUNDLE_ID, check=False)
    verify_app(destination)
    return rescue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--app", type=Path, default=Path(__file__).resolve().parents[2] / "DerivedData/Build/Products/Debug" / APP_NAME)
    restore_parser = commands.add_parser("rollback")
    restore_parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    application_support = Path.home() / "Library/Application Support"
    destination = Path.home() / "Applications" / APP_NAME
    data = application_support / DATA_NAME
    backup_root = application_support / "FluidVoice Personal Backups"
    if args.action == "install":
        backup = install(args.app.resolve(), destination, data, backup_root)
        print("Installed " + str(destination))
    else:
        backup = rollback(args.snapshot.resolve(), destination, data, backup_root)
        print("Restored app, data, and preferences from " + str(args.snapshot))
    print("Previous state retained at " + str(backup))
    print("Keychain credentials are retained separately and are never exported into backups.")


if __name__ == "__main__":
    main()

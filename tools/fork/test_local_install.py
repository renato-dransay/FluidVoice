import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import local_install as local


class LocalInstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.app = self.root / "Applications" / local.APP_NAME
        self.data = self.root / "data"
        self.backups = self.root / "backups"
        self.data.mkdir()
        (self.data / "history.txt").write_text("previous history")
        self.make_app(self.app, "old")
        self.source = self.root / "build" / local.APP_NAME
        self.make_app(self.source, "new")
        self.calls = []

    def tearDown(self):
        self.directory.cleanup()

    @staticmethod
    def make_app(app, version, identity=local.BUNDLE_ID):
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identity}))
        (app / "Contents/version").write_text(version)

    def command(self, *args, check=True):
        self.calls.append(args)
        if args[0] == "ditto":
            shutil.copytree(args[1], args[2], dirs_exist_ok=True, symlinks=True)
        if args[0] == "pgrep":
            return subprocess.CompletedProcess(args, 1, b"", b"")
        if args[:2] == ("defaults", "export"):
            return subprocess.CompletedProcess(args, 0, plistlib.dumps({"setting": "old"}), b"")
        return subprocess.CompletedProcess(args, 0, b"", b"Authority=Apple Development: Fixture\nTeamIdentifier=FIXTURE\n")

    def test_install_keeps_backup_and_rollback_restores_data(self):
        with patch.object(local, "command", side_effect=self.command):
            backup = local.install(self.source, self.app, self.data, self.backups)
            self.assertEqual((self.app / "Contents/version").read_text(), "new")
            self.assertEqual((backup / local.APP_NAME / "Contents/version").read_text(), "old")
            (self.data / "history.txt").write_text("new history")
            rescue = local.rollback(backup, self.app, self.data, self.backups)
        self.assertEqual((self.app / "Contents/version").read_text(), "old")
        self.assertEqual((self.data / "history.txt").read_text(), "previous history")
        self.assertEqual((rescue / "data/history.txt").read_text(), "new history")
        self.assertTrue(any(c[:2] == ("defaults", "import") for c in self.calls))

    def test_official_bundle_is_rejected_before_backup(self):
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.FluidApp.app"}))
        with patch.object(local, "command", side_effect=self.command):
            with self.assertRaisesRegex(RuntimeError, "another application identity"):
                local.install(self.source, self.app, self.data, self.backups)
        self.assertFalse(self.backups.exists())

    def test_running_app_prevents_upgrade(self):
        with patch.object(local, "command", return_value=subprocess.CompletedProcess([], 0, b"123", b"")):
            with self.assertRaisesRegex(RuntimeError, "Quit FluidVoice Personal"):
                local.install(self.source, self.app, self.data, self.backups)
        self.assertEqual((self.app / "Contents/version").read_text(), "old")

    def test_failed_swap_restores_previous_app(self):
        original_rename = Path.rename
        def failed_rename(path, target):
            if path.name == local.APP_NAME and path.parent.name.startswith(".fluidvoice-stage-"):
                raise OSError("simulated rename failure")
            return original_rename(path, target)
        with patch.object(local, "command", side_effect=self.command), patch.object(Path, "rename", failed_rename):
            with self.assertRaisesRegex(OSError, "simulated rename failure"):
                local.install(self.source, self.app, self.data, self.backups)
        self.assertEqual((self.app / "Contents/version").read_text(), "old")


if __name__ == "__main__":
    unittest.main()

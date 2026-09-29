import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import upstream_update as update


class UpstreamUpdateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.previous = Path.cwd()
        os.chdir(self.directory.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        Path("upstream.txt").write_text("baseline\n")
        self.git("add", ".")
        self.git("commit", "-qm", "baseline")
        self.baseline = self.git("rev-parse", "HEAD")
        self.git("branch", "personal")

    def tearDown(self):
        os.chdir(self.previous)
        self.directory.cleanup()

    @staticmethod
    def git(*args):
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.DEVNULL).strip()

    def commit(self, path, text):
        Path(path).write_text(text)
        self.git("add", ".")
        self.git("commit", "-qm", text)
        return self.git("rev-parse", "HEAD")

    def test_clean_merge_preserves_personal_feature(self):
        release = self.commit("upstream.txt", "upstream release\n")
        self.git("switch", "personal")
        self.commit("feature.txt", "cloud provider\n")
        self.assertEqual(update.candidate_status(self.baseline, release, "main", "personal"), "eligible")
        result = update.merge_candidate("personal", release, update.update_branch("v2.0.0"))
        self.assertTrue(update.ancestor(release, result))
        self.assertEqual(Path("feature.txt").read_text(), "cloud provider\n")

    def test_merge_conflict_aborts_without_losing_feature(self):
        release = self.commit("upstream.txt", "upstream edit\n")
        self.git("switch", "personal")
        personal = self.commit("upstream.txt", "personal edit\n")
        with self.assertRaisesRegex(RuntimeError, "manual resolution"):
            update.merge_candidate("personal", release, "update-conflict")
        self.assertEqual(self.git("rev-parse", "HEAD"), personal)
        self.assertEqual(Path("upstream.txt").read_text(), "personal edit\n")
        self.assertFalse(Path(".git/MERGE_HEAD").exists())

    def test_release_already_included_is_skipped(self):
        self.assertEqual(update.candidate_status(self.baseline, self.baseline, "main", "personal"), "included")

    def test_divergent_release_requires_review(self):
        baseline = self.commit("new-main.txt", "main change\n")
        self.git("switch", "-c", "release-line", self.baseline)
        release = self.commit("release-only.txt", "separate line\n")
        self.assertEqual(update.candidate_status(baseline, release, "main", "personal"), "divergent")

    def test_duplicate_release_pr_is_reused(self):
        branch = update.update_branch("v2.0.0")
        pull = {"headRefName": branch, "url": "https://example.invalid/pull/1"}
        self.assertEqual(update.duplicate_pull_request([pull], branch), pull)
        self.assertIsNone(update.duplicate_pull_request([pull], update.update_branch("v2.0.1")))


if __name__ == "__main__":
    unittest.main()

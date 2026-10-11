"""Exercise release archives against a temporary Git repository with private local state."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("source_release", REPO / "scripts/package-source-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
VERSION = "v0.0.0"


class SourceReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        old_repo = release.REPO
        release.REPO = self.repo
        self.addCleanup(setattr, release, "REPO", old_repo)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        for name in release.REQUIRED:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic release fixture\n")
        self.commit()
        self.output = self.root / "release"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE)

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "-qm", "Synthetic source snapshot")

    def test_only_selected_commit_is_published_and_all_assets_have_checksums(self):
        commit = self.git("rev-parse", "HEAD").decode().strip()
        (self.repo / "README.md").write_text("uncommitted change")
        (self.repo / "assistant.sqlite").write_text("private local database")
        release.package(VERSION, commit, self.output)
        metadata = json.loads((self.output / "release.json").read_text())
        self.assertEqual(metadata["commit"], commit)
        for line in (self.output / "SHA256SUMS").read_text().splitlines():
            checksum, name = line.split("  ")
            self.assertEqual(hashlib.sha256((self.output / name).read_bytes()).hexdigest(), checksum)
        prefix = f"local-proactive-assistant-{VERSION}/"
        with zipfile.ZipFile(next(self.output.glob("*.zip"))) as archive:
            self.assertEqual(archive.read(prefix + "README.md"), b"synthetic release fixture\n")
            self.assertNotIn(prefix + "assistant.sqlite", archive.namelist())
        with tarfile.open(next(self.output.glob("*.tar.gz"))) as archive:
            self.assertEqual(archive.extractfile(prefix + "README.md").read(), b"synthetic release fixture\n")

    def test_committed_private_state_or_credentials_cannot_be_published(self):
        for name, content in (("assistant.sqlite", "private database"),
                              ("accidental.txt", "ghp_" + "A" * 36),
                              ("secret.txt", "-----BEGIN PRIVATE KEY-----\n" + "A" * 64)):
            with self.subTest(name=name):
                path = self.repo / name
                path.write_text(content)
                self.commit()
                with self.assertRaises(ValueError):
                    release.package(VERSION, "HEAD", self.output)
                self.assertFalse(self.output.exists())
                path.unlink()
                self.commit()

    def test_missing_required_document_and_broken_links_fail_before_output(self):
        path = self.repo / "LICENSE"
        path.unlink()
        self.commit()
        with self.assertRaisesRegex(ValueError, "Missing release files"):
            release.package(VERSION, "HEAD", self.output)
        path.write_text("synthetic license")
        (self.repo / "README.md").write_text("[Missing](docs/missing.md)")
        self.commit()
        with self.assertRaisesRegex(ValueError, "Broken source link"):
            release.package(VERSION, "HEAD", self.output)
        self.assertFalse(self.output.exists())

    def test_existing_output_and_symlink_are_not_replaced(self):
        self.output.mkdir()
        sentinel = self.output / "sentinel"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(ValueError, "Output already exists"):
            release.package(VERSION, "HEAD", self.output)
        self.assertEqual(sentinel.read_text(), "keep")
        (self.repo / "linked").symlink_to("README.md")
        self.commit()
        with self.assertRaisesRegex(ValueError, "symlinks"):
            release.package(VERSION, "HEAD", self.root / "other-output")

    def test_contact_fixtures_reject_nonreserved_addresses_without_printing_them(self):
        path = self.repo / "Tests/contact.txt"
        path.parent.mkdir()
        # Assemble rejected values so this test's own source remains a valid fixture.
        for content in ("person@" + "fixture.invalid", "+" + "14152223333"):
            path.write_text(content)
            self.commit()
            with self.assertRaises(ValueError) as failure:
                release.package(VERSION, "HEAD", self.output)
            self.assertNotIn(content, str(failure.exception))
            self.assertIn("Tests/contact.txt", str(failure.exception))
            self.assertFalse(self.output.exists())
        path.write_text("person@example.invalid +14155550123 +442079460123")
        self.commit()
        release.package(VERSION, "HEAD", self.output)


if __name__ == "__main__":
    unittest.main()

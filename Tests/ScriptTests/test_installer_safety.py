#!/usr/bin/env python3
"""Exercise package replacement and installation gates against real temp directories."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

COMMON = Path(__file__).resolve().parents[2] / "scripts/startup-common.sh"
WORKER_SETUP = COMMON.parent / "setup-local-model.sh"
STUB = r'''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
name, args = Path(sys.argv[0]).name, sys.argv[1:]
def flag(value): return (root / value).exists()
with (root / "calls").open("a") as log: log.write(name + " " + " ".join(args) + "\n")
if name == "curl":
    if "https://ollama.com/download/Ollama-darwin.zip" not in args:
        raise RuntimeError("Unexpected download URL")
    Path(args[args.index("-o") + 1]).write_text("official-download-fixture")
elif name == "xcodebuild": print("Xcode 26.0")
elif name == "swift":
    if "--show-bin-path" in args: print(root / "build")
elif name == "ditto":
    target = Path(args[-1]) / "Ollama.app"
    binary = target / "Contents/Resources/ollama"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/bash\necho new-runtime\n")
    binary.chmod(0o755)
elif name in ("codesign", "spctl"):
    if flag("signature_failed"):
        print("Package signature could not be verified", file=sys.stderr)
        sys.exit(1)
elif name == "mv":
    source, target = map(Path, args)
    if source.name in ("Ollama.app", "LocalAssistantModel.app") \
        and target.name in ("Ollama.app", "LocalAssistantModel.app") and flag("replacement_failed"):
        print("Replacement move failed", file=sys.stderr)
        sys.exit(1)
    shutil.move(str(source), str(target))
'''


class InstallerSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("curl", "ditto", "codesign", "spctl", "mv", "xcodebuild", "swift"):
            executable = self.bin / name
            executable.write_text(STUB)
            executable.chmod(0o755)
        self.support = self.root / "home/Library/Application Support/LocalProactiveAssistant"
        self.runtime = self.support / "Runtime/Ollama.app"
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.root), HOME=str(self.root / "home"),
                        TMPDIR=str(self.root), PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        for key in ("ASSISTANT_STARTUP_LOG", "ASSISTANT_STARTUP_BANNER", "ASSISTANT_DEBUG", "ASSISTANT_VERBOSE"):
            self.env.pop(key, None)

    def old_runtime(self):
        self.runtime.mkdir(parents=True)
        (self.runtime / "old-version.txt").write_text("preserve me")

    def install(self, *flags):
        for flag in flags: (self.root / flag).touch()
        command = 'set -euo pipefail; source "$COMMON_SCRIPT"; assistant_start_session; assistant_install_staging=""; assistant_install_owned_ollama'
        result = subprocess.run(["bash", "-c", command], env=dict(self.env, COMMON_SCRIPT=str(COMMON)),
                                text=True, capture_output=True, timeout=10)
        return result

    def test_verified_package_replaces_only_private_runtime(self):
        self.old_runtime()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.runtime / "Contents/Resources/ollama").exists())
        self.assertFalse((self.runtime / "old-version.txt").exists())
        self.assertEqual(list(self.runtime.parent.glob(".ollama-download.*")), [])

    def test_failed_signature_keeps_existing_runtime_and_removes_staging(self):
        self.old_runtime()
        result = self.install("signature_failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.runtime / "old-version.txt").read_text(), "preserve me")
        self.assertEqual(list(self.runtime.parent.glob(".ollama-download.*")), [])

    def test_failed_replacement_restores_previous_runtime(self):
        self.old_runtime()
        result = self.install("replacement_failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.runtime / "old-version.txt").read_text(), "preserve me")
        self.assertIn("restored", result.stderr)
        self.assertEqual(list(self.runtime.parent.glob(".ollama-download.*")), [])

    def test_symlink_runtime_is_never_followed_or_replaced(self):
        external = self.root / "unrelated-app"
        external.mkdir()
        (external / "keep.txt").write_text("untouched")
        self.runtime.parent.mkdir(parents=True)
        self.runtime.symlink_to(external, target_is_directory=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.runtime.is_symlink())
        self.assertEqual((external / "keep.txt").read_text(), "untouched")
        self.assertFalse((self.root / "calls").exists())

    def test_unexpected_file_at_runtime_path_is_kept(self):
        self.runtime.parent.mkdir(parents=True)
        self.runtime.write_text("unrelated file")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.runtime.read_text(), "unrelated file")
        self.assertFalse((self.root / "calls").exists())

    def test_noninteractive_missing_homebrew_exits_before_download(self):
        command = 'set -euo pipefail; source "$COMMON_SCRIPT"; assistant_start_session; assistant_find_brew() { return 1; }; assistant_install_brew'
        env = dict(self.env, COMMON_SCRIPT=str(COMMON))
        env.pop("NONINTERACTIVE", None)
        result = subprocess.run(["bash", "-c", command], env=env, text=True,
                                capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Run this starter in Terminal", result.stderr)
        self.assertFalse((self.root / "calls").exists())

    def test_saving_profile_does_not_follow_directory_symlink(self):
        external = self.root / "unrelated-folder"
        external.mkdir()
        self.support.mkdir(parents=True)
        (self.support / "model-profile.txt").symlink_to(external, target_is_directory=True)
        command = 'set -euo pipefail; source "$COMMON_SCRIPT"; assistant_start_session; model_choice=apple; model_name=""; model_url=""; assistant_save_profile'
        result = subprocess.run(["bash", "-c", command], env=dict(self.env, COMMON_SCRIPT=str(COMMON)),
                                text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(external.iterdir()), [])

    def setup_worker_fixture(self):
        repo = self.root / "worker-repo"
        (repo / "scripts").mkdir(parents=True)
        import shutil
        shutil.copyfile(WORKER_SETUP, repo / "scripts/setup-local-model.sh")
        (repo / "Configuration").mkdir()
        (repo / "Configuration/ModelWorker-Info.plist").write_text("fixture plist")
        (repo / "Configuration/ModelWorker.entitlements").write_text("fixture entitlements")
        (self.root / "build").mkdir()
        binary = self.root / "build/assistant-model-worker"
        binary.write_text("new worker")
        binary.chmod(0o755)
        worker = self.support / "Models/LocalAssistantModel.app"
        worker.mkdir(parents=True)
        (worker / "old-version.txt").write_text("keep previous worker")
        return repo, worker

    def test_failed_worker_replacement_restores_old_worker(self):
        repo, worker = self.setup_worker_fixture()
        (self.root / "replacement_failed").touch()
        result = subprocess.run(["bash", str(repo / "scripts/setup-local-model.sh")],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((worker / "old-version.txt").read_text(), "keep previous worker")
        self.assertIn("previous Apple model worker was restored", result.stderr)
        self.assertEqual(list(worker.parent.glob(".install.*")), [])

    def test_failed_worker_signature_preserves_old_worker(self):
        repo, worker = self.setup_worker_fixture()
        (self.root / "signature_failed").touch()
        result = subprocess.run(["bash", str(repo / "scripts/setup-local-model.sh")],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((worker / "old-version.txt").read_text(), "keep previous worker")
        self.assertEqual(list(worker.parent.glob(".install.*")), [])

    def test_verified_worker_replacement_installs_expected_bundle_files(self):
        repo, worker = self.setup_worker_fixture()
        result = subprocess.run(["bash", str(repo / "scripts/setup-local-model.sh")],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((worker / "Contents/MacOS/assistant-model-worker").read_text(), "new worker")
        self.assertEqual((worker / "Contents/Info.plist").read_text(), "fixture plist")
        calls = (self.root / "calls").read_text()
        self.assertIn("codesign --force --sign - --entitlements", calls)
        self.assertIn("codesign --verify --strict", calls)
        self.assertFalse((worker / "old-version.txt").exists())


if __name__ == "__main__":
    unittest.main()

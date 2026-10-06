#!/usr/bin/env python3
"""Check native package boundaries and rollback against temporary install directories."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
STUB = r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "uname": print("Darwin" if "-s" in args else "arm64")
elif name == "sw_vers": print("26.0")
elif name == "swift":
    if "--show-bin-path" in args: print(root / "build")
elif name == "xcrun":
    if "--show-sdk-path" in args: print(root / "sdk")
    else:
        binary = Path(args[args.index("-o") + 1])
        binary.write_text("#!/bin/bash\nexit 0\n")
        binary.chmod(0o755)
elif name == "codesign":
    if (root / "signature-failure").exists(): sys.exit(1)
elif name == "mv":
    source, target = map(Path, args)
    if (root / "app-replacement-failure").exists() and source.name == target.name == "LocalAssistant.app":
        print("Fixture replacement failure", file=sys.stderr)
        sys.exit(1)
    if (root / "worker-replacement-failure").exists() and source.name == target.name == "LocalAssistantModel.app":
        sys.exit(1)
    shutil.move(str(source), str(target))
'''


class MacAppInstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        for folder in ("scripts", "Apps/AssistantMac", "Configuration"):
            (self.repo / folder).mkdir(parents=True)
        shutil.copyfile(REPO / "scripts/install-mac-app.sh", self.repo / "scripts/install-mac-app.sh")
        for filename in ("Info.plist", "Host.entitlements"):
            shutil.copyfile(REPO / "Apps/AssistantMac" / filename, self.repo / "Apps/AssistantMac" / filename)
        for filename in ("ModelWorker-Info.plist", "ModelWorker.entitlements"):
            shutil.copyfile(REPO / "Configuration" / filename, self.repo / "Configuration" / filename)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("uname", "sw_vers", "swift", "xcrun", "codesign", "mv", "open"):
            (self.bin / name).write_text(STUB)
            (self.bin / name).chmod(0o755)
        (self.bin / "imsg").write_text("#!/bin/bash\nexit 0\n")
        (self.bin / "imsg").chmod(0o755)
        build = self.root / "build"
        build.mkdir()
        for filename in ("assistantctl", "assistant-model-worker"):
            (build / filename).write_text("#!/bin/bash\nexit 0\n")
            (build / filename).chmod(0o755)
        (build / "fixture.bundle").mkdir()
        (build / "fixture.bundle/data.txt").write_text("runtime resource")
        self.home = self.root / "home"
        self.support = self.home / "Library/Application Support/LocalProactiveAssistant"
        self.worker = self.support / "Models/LocalAssistantModel.app"
        self.app = self.root / "applications/LocalAssistant.app"
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.root), HOME=str(self.home),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])

    def install(self, *args, output=None):
        return subprocess.run(["bash", str(self.repo / "scripts/install-mac-app.sh"),
                               "--output", str(output or self.app), "--no-open", *args],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def previous_install(self):
        self.app.mkdir(parents=True)
        (self.app / "previous.txt").write_text("old app")
        self.worker.mkdir(parents=True)
        (self.worker / "previous.txt").write_text("old worker")
        (self.support / "model-profile.txt").write_text("unchanged model selection")

    def test_build_only_bundles_runtime_without_touching_user_state(self):
        self.worker.mkdir(parents=True)
        (self.worker / "previous.txt").write_text("old worker")
        result = self.install("--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        runtime = self.app / "Contents/Resources/Runtime"
        self.assertTrue((runtime / "bin/assistantctl").is_file())
        self.assertTrue((runtime / "bin/imsg").is_file())
        self.assertEqual((runtime / "bin/fixture.bundle/data.txt").read_text(), "runtime resource")
        self.assertEqual((self.worker / "previous.txt").read_text(), "old worker")
        self.assertFalse(any(call[0] == "open" for call in self.calls()))

    def test_signs_worker_separately_without_replacing_its_sandbox(self):
        result = self.install("--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        signing = [call for call in self.calls() if call[0] == "codesign" and "--force" in call]
        worker = [call for call in signing if call[-1].endswith("LocalAssistantModel.app")]
        self.assertEqual(len(worker), 1)
        self.assertEqual(worker[0][worker[0].index("--entitlements") + 1], "Configuration/ModelWorker.entitlements")
        self.assertFalse(any("--deep" in call for call in signing))
        self.assertTrue(any(call[1:4] == ["--verify", "--deep", "--strict"] for call in self.calls()))

    def test_access_descriptions_are_in_the_installed_app(self):
        result = self.install("--build-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        with (self.app / "Contents/Info.plist").open("rb") as file:
            info = plistlib.load(file)
        self.assertEqual(info["CFBundleIdentifier"], "org.localproactiveassistant.mac")
        for key in ("NSAppleEventsUsageDescription", "NSContactsUsageDescription", "NSCalendarsFullAccessUsageDescription", "NSRemindersFullAccessUsageDescription", "NSPhotoLibraryUsageDescription"):
            self.assertTrue(info[key])

    def test_successful_install_preserves_saved_pairing_and_model(self):
        self.previous_install()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.app / "Contents/MacOS/LocalAssistant").is_file())
        self.assertTrue((self.worker / "Contents/MacOS/assistant-model-worker").is_file())
        self.assertEqual((self.support / "model-profile.txt").read_text(), "unchanged model selection")
        self.assertEqual(list(self.app.parent.glob(".native-install.*")), [])
        self.assertEqual(list(self.worker.parent.glob(".native-install.*")), [])

    def test_failed_signature_keeps_previous_app_and_worker(self):
        self.previous_install()
        (self.root / "signature-failure").touch()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "previous.txt").read_text(), "old app")
        self.assertEqual((self.worker / "previous.txt").read_text(), "old worker")

    def test_failed_app_replacement_restores_both_old_app_and_old_worker(self):
        self.previous_install()
        (self.root / "app-replacement-failure").touch()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "previous.txt").read_text(), "old app")
        self.assertEqual((self.worker / "previous.txt").read_text(), "old worker")
        self.assertIn("previous native app was restored", result.stderr)
        self.assertIn("previous Apple worker was restored", result.stderr)

    def test_failed_worker_replacement_does_not_replace_app(self):
        self.previous_install()
        (self.root / "worker-replacement-failure").touch()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "previous.txt").read_text(), "old app")
        self.assertEqual((self.worker / "previous.txt").read_text(), "old worker")

    def test_output_symlink_is_rejected_before_build(self):
        external = self.root / "unrelated"
        external.mkdir()
        self.app.parent.mkdir(parents=True)
        self.app.symlink_to(external, target_is_directory=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.app.is_symlink())
        self.assertEqual(list(external.iterdir()), [])
        self.assertFalse(any(call[0] in ("swift", "xcrun", "codesign") for call in self.calls()))

    def test_unusual_quoted_output_path_remains_a_literal_path(self):
        app = self.root / "spaces 'quotes' $(touch SENTINEL).app"
        result = self.install("--build-only", output=app)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((app / "Contents/MacOS/LocalAssistant").is_file())
        self.assertFalse((self.repo / "SENTINEL").exists())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Run first-start, resume, and configuration gates without real model downloads."""
import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
STUB = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
name, args = Path(sys.argv[0]).name, sys.argv[1:]
def log(value):
    with (root / "calls").open("a") as out: out.write(value + "\n")
if name == "uname": print("arm64" if args == ["-m"] else os.environ.get("FIXTURE_OS", "Darwin"))
elif name == "sw_vers": print(os.environ.get("FIXTURE_MACOS", "26.0"))
elif name == "sysctl": print(int(os.environ.get("FIXTURE_MEMORY", "48")) * 1024 ** 3)
elif name == "xcode-select":
    if args == ["--install"]: log("install developer tools")
    elif os.environ.get("FIXTURE_NO_TOOLS"): sys.exit(1)
    else: print("/Applications/Xcode.app/Contents/Developer")
elif name == "xcodebuild": print("Xcode " + os.environ.get("FIXTURE_XCODE", "26.0"))
elif name == "swift":
    if args == ["--version"]: print("Apple Swift version " + os.environ.get("FIXTURE_SWIFT", "6.2"))
    else: log("swift " + " ".join(args))
elif name == "brew": log("brew " + " ".join(args))
elif name == "open": log("open " + " ".join(args))
elif name == "imsg": pass
elif name == "caffeinate":
    log("keep awake")
    sys.exit(subprocess.run(args[1:]).returncode)
elif name == "assistantctl":
    log("host " + " ".join(args))
    if args[0] == "serve": (root / "serve-args.json").write_text(json.dumps(args))
    if args[0] == "doctor" and os.environ.get("FIXTURE_DENIED"): sys.exit(1)
    if args[0] == "model-status" and os.environ.get("FIXTURE_MODEL_UNAVAILABLE"): sys.exit(1)
    if args[0] == "prepare-access" and os.environ.get("FIXTURE_SOURCE_DENIED"): sys.exit(1)
    if args[0] == "pair-chat":
        config = Path(os.environ["HOME"]) / "Library/Application Support/LocalProactiveAssistant/control-chat-id.txt"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text("955\n")
'''


class GuidedStarterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / ".build/release").mkdir(parents=True)
        for name in ("start.sh", "startup-common.sh"):
            shutil.copyfile(SCRIPTS / name, self.repo / "scripts" / name)
        (self.repo / "scripts/start-open-model.sh").write_text(
            '#!/bin/bash\nprintf "open-starter %s\\n" "$ASSISTANT_OPEN_MODEL" >> "$FIXTURE_ROOT/calls"\n'
        )
        (self.repo / "scripts/setup-local-model.sh").write_text(
            '#!/bin/bash\nprintf "apple setup\\n" >> "$FIXTURE_ROOT/calls"\n'
        )
        (self.root / "bin").mkdir()
        for name in ("uname", "sw_vers", "sysctl", "xcode-select", "xcodebuild", "swift", "brew", "open", "imsg", "caffeinate"):
            target = self.root / "bin" / name
            target.write_text(STUB)
            target.chmod(0o755)
        target = self.repo / ".build/release/assistantctl"
        target.write_text(STUB)
        target.chmod(0o755)
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.root), HOME=str(self.root / "home"),
                        TMPDIR=str(self.root), PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])
        for name in ("ASSISTANT_MODEL", "ASSISTANT_MODEL_NAME", "ASSISTANT_MODEL_URL", "ASSISTANT_OPEN_MODEL", "DEVELOPER_DIR"):
            self.env.pop(name, None)
        self.profile = self.root / "home/Library/Application Support/LocalProactiveAssistant/model-profile.txt"

    def run_start(self, answers=None, args=(), **env):
        config = dict(self.env, **env)
        if answers is None:
            result = subprocess.run(["bash", str(self.repo / "scripts/start.sh"), *args],
                                    env=config, text=True, capture_output=True, timeout=10)
        else:
            primary, secondary = pty.openpty()
            try:
                os.write(primary, (answers + "n\n").encode())
                result = subprocess.run(["bash", str(self.repo / "scripts/start.sh"), *args],
                                        env=config, stdin=secondary, text=True,
                                        capture_output=True, timeout=10)
            finally:
                os.close(primary)
                os.close(secondary)
        calls = (self.root / "calls").read_text() if (self.root / "calls").exists() else ""
        return result, calls

    def write_profile(self, provider="apple", model="", url=""):
        self.profile.parent.mkdir(parents=True, exist_ok=True)
        self.profile.write_text(f"1\n{provider}\n{model}\n{url}\n")

    def test_first_run_recommends_memory_fit_and_remembers_choice(self):
        result, calls = self.run_start("\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.profile.read_text(), "1\nollama\nqwen3.8:27b-q4_K_M\n\n")
        self.assertIn("open-starter qwen3.8:27b-q4_K_M", calls)
        self.assertEqual(self.profile.stat().st_mode & 0o777, 0o600)
        result, _ = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Choose how", result.stdout)

    def test_model_menu_can_switch_existing_choice(self):
        self.write_profile("ollama", "qwen3.8:27b-q4_K_M")
        result, calls = self.run_start("2\n", args=("--choose-model",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.profile.read_text(), "1\napple\n\n\n")
        self.assertIn("apple setup", calls)
        self.assertIn("host pair-chat", calls)
        self.assertIn("keep awake", calls)
        self.assertIn("host serve --model apple", calls)

    def test_low_memory_menu_selects_small_model(self):
        result, calls = self.run_start("1\n", FIXTURE_MEMORY="8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("open-starter qwen3.5:2b", calls)

    def test_existing_chat_is_reused(self):
        self.write_profile()
        self.profile.with_name("control-chat-id.txt").write_text("955\n")
        result, calls = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("host pair-chat", calls)
        self.assertIn("host serve --model apple", calls)

    def test_byo_loopback_endpoint_is_preserved_as_data(self):
        model = "$(touch SHOULD_NOT_EXIST)"
        result, calls = self.run_start(f"4\nhttp://[::1]:12345/v1\n{model}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.repo / "SHOULD_NOT_EXIST").exists())
        self.assertIn("--model-url http://[::1]:12345/v1 --model-name " + model, calls)
        self.assertEqual(self.profile.read_text(), f"1\nlocal\n{model}\nhttp://[::1]:12345/v1\n")

    def test_remote_endpoint_is_rejected_before_build_or_serve(self):
        result, calls = self.run_start(ASSISTANT_MODEL="local", ASSISTANT_MODEL_NAME="model",
                                       ASSISTANT_MODEL_URL="https://remote.invalid/v1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("swift build", calls)
        self.assertNotIn("host serve", calls)

    def test_malformed_profile_is_never_executed(self):
        self.write_profile("$(touch SHOULD_NOT_EXIST)", "bad")
        result, _ = self.run_start("1\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.repo / "SHOULD_NOT_EXIST").exists())

    def test_denied_messages_access_opens_specific_settings(self):
        self.write_profile()
        result, calls = self.run_start(FIXTURE_DENIED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Privacy_AllFiles", calls)
        self.assertNotIn("host serve", calls)
        self.assertTrue(self.profile.exists())

    def test_missing_developer_tools_requests_macos_install(self):
        result, calls = self.run_start(FIXTURE_NO_TOOLS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("install developer tools", calls)
        self.assertNotIn("host serve", calls)

    def test_missing_imsg_is_installed_with_supported_homebrew_formula(self):
        (self.root / "bin/imsg").unlink()
        self.write_profile()
        result, calls = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("brew install steipete/tap/imsg", calls)

    def test_apple_unavailable_does_not_start_silent_command_only_host(self):
        self.write_profile()
        result, calls = self.run_start(FIXTURE_MODEL_UNAVAILABLE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--choose-model", result.stderr)
        self.assertNotIn("host serve", calls)

    def test_source_build_requires_swift_six(self):
        result, calls = self.run_start(FIXTURE_SWIFT="5.10")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Swift 6+", result.stderr)
        self.assertNotIn("swift build", calls)

    def test_source_permissions_are_prepared_once_after_success(self):
        self.write_profile()
        result, calls = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("host prepare-access", calls)
        marker = self.profile.with_name("access-prepared-v1.txt")
        self.assertEqual(marker.read_text(), "1\n")
        result, calls = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("host prepare-access"), 1)

    def test_denied_source_does_not_block_chat_or_mark_access_complete(self):
        self.write_profile()
        result, calls = self.run_start(FIXTURE_SOURCE_DENIED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("host serve", calls)
        self.assertFalse(self.profile.with_name("access-prepared-v1.txt").exists())

    def test_user_can_skip_source_setup_for_now(self):
        self.write_profile()
        result, calls = self.run_start(ASSISTANT_SKIP_ACCESS_SETUP="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("host prepare-access", calls)
        self.assertIn("host serve", calls)

    def test_custom_read_root_is_one_literal_argument(self):
        import json
        self.write_profile()
        folder = str(self.root / "Personal Docs; touch SHOULD_NOT_EXIST")
        result, _ = self.run_start(ASSISTANT_READ_ROOT=folder)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.root / "serve-args.json").read_text())
        self.assertEqual(args[-2:], ["--read-root", folder])
        self.assertFalse((self.repo / "SHOULD_NOT_EXIST").exists())


if __name__ == "__main__":
    unittest.main()

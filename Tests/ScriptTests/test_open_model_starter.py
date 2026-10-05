#!/usr/bin/env python3
"""Exercise starter recovery without downloading weights or running Messages."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

STARTER = Path(__file__).resolve().parents[2] / "scripts/start-open-model.sh"
STUB = r"""#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ["FIXTURE_ROOT"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
def log(text):
    with (root / "calls").open("a") as f:
        f.write(text + "\n")
def flag(name): return (root / name).exists()
if name == "uname":
    print("Darwin")
elif name == "sysctl":
    print(48 * 1024 ** 3)
elif name == "sw_vers":
    print("26.0")
elif name == "xcode-select": print("/Applications/Xcode.app/Contents/Developer")
elif name == "xcodebuild": print("Xcode 26.0")
elif name == "swift": print("Apple Swift version 6.2")
elif name == "imsg": pass
elif name == "brew":
    if args[:1] == ["list"]:
        sys.exit(1 if flag("app_install") else 0)
    if args[:1] == ["--prefix"]:
        print(root / "brew-prefix")
    else:
        log("brew " + " ".join(args))
        if args[:1] == ["upgrade"]: (root / "upgraded").touch()
elif name == "curl":
    url = args[-1]
    if "127.0.0.1:11435/api/version" not in url:
        raise RuntimeError("Starter used an external or stale endpoint: " + url)
    if flag("port_busy") or flag("server"):
        print(json.dumps({"version": "new" if flag("upgraded") else "old"}))
    else:
        sys.exit(7)
elif name == "lsof":
    if flag("port_busy"):
        print(999999)
    elif flag("port_race"):
        sys.exit(1)
    elif flag("server"):
        pid = (root / "server").read_text()
        if "-p" not in args or args[args.index("-p") + 1] == pid: print(pid)
        else: sys.exit(1)
    else: sys.exit(1)
elif name == "ollama":
    if os.environ.get("OLLAMA_HOST") != "127.0.0.1:11435":
        raise RuntimeError("Inherited a remote/stale Ollama endpoint")
    if os.environ.get("OLLAMA_NO_CLOUD") != "1":
        raise RuntimeError("Cloud features were not disabled")
    log("ollama " + " ".join(args))
    if args == ["serve"]:
        (root / "server").write_text(str(os.getpid()))
        if flag("port_race"):
            time.sleep(1)
            (root / "server").unlink(missing_ok=True)
            sys.exit(1)
        def stop(*_):
            (root / "server").unlink(missing_ok=True)
            sys.exit(0)
        signal.signal(signal.SIGTERM, signal.SIG_IGN if flag("ignore_term") else stop)
        while True: time.sleep(0.1)
    elif args == ["list"]:
        print("NAME ID SIZE")
        if flag("cached"): print("qwen3.8:27b-q4_K_M test 18GB")
        if flag("list_failed"):
            print("Model list failed: database unavailable", file=sys.stderr)
            sys.exit(1)
    elif args[:1] == ["pull"]:
        if flag("network_error"):
            print("Error: download connection failed", file=sys.stderr)
            sys.exit(1)
        if flag("outdated") and not flag("upgraded"):
            print("Error: pull model manifest: 412: The model requires a newer version of Ollama.", file=sys.stderr)
            sys.exit(1)
"""

class StarterTests(unittest.TestCase):
    def run_starter(self, *flags, model=None, verbose=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            (repo / "scripts").mkdir(parents=True)
            shutil.copyfile(STARTER, repo / "scripts/start-open-model.sh")
            shutil.copyfile(STARTER.parent / "startup-common.sh", repo / "scripts/startup-common.sh")
            (repo / "scripts/start.sh").write_text(
                '#!/bin/bash\nprintf "%s\\n" "$ASSISTANT_MODEL_URL" "$ASSISTANT_MODEL_NAME" > "$FIXTURE_ROOT/host"\n'
            )
            (root / "bin").mkdir()
            (root / "brew-prefix/bin").mkdir(parents=True)
            for name in ("uname", "sysctl", "sw_vers", "xcode-select", "xcodebuild", "swift", "imsg", "brew", "curl", "lsof", "ollama"):
                target = root / "bin" / name
                target.write_text(STUB)
                target.chmod(0o755)
            shutil.copyfile(root / "bin/ollama", root / "brew-prefix/bin/ollama")
            (root / "brew-prefix/bin/ollama").chmod(0o755)
            for flag in flags: (root / flag).touch()
            env = dict(os.environ, FIXTURE_ROOT=tmp, TMPDIR=tmp, HOME=str(root / "home"),
                       PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                       OLLAMA_HOST="https://remote.invalid")
            env.pop("ASSISTANT_OPEN_MODEL", None)
            for key in ("ASSISTANT_VERBOSE", "ASSISTANT_DEBUG", "ASSISTANT_STARTUP_LOG", "ASSISTANT_STARTUP_BANNER", "ASSISTANT_STARTUP_MODEL_SHOWN", "ASSISTANT_STARTUP_CHECKED", "DEVELOPER_DIR"):
                env.pop(key, None)
            if verbose: env["ASSISTANT_VERBOSE"] = "1"
            if model: env["ASSISTANT_OPEN_MODEL"] = model
            result = subprocess.run(["bash", str(repo / "scripts/start-open-model.sh")],
                                    env=env, text=True, capture_output=True, timeout=20)
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
            host = (root / "host").read_text() if (root / "host").exists() else None
            if "ignore_term" in flags and (root / "server").exists():
                with self.assertRaises(ProcessLookupError): os.kill(int((root / "server").read_text()), 0)
            else:
                self.assertFalse((root / "server").exists(), "Owned server leaked after exit")
            return result, calls, host

    def test_private_server_ignores_inherited_endpoint(self):
        result, calls, host = self.run_starter()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(host, "http://127.0.0.1:11435/v1\nqwen3.8:27b-q4_K_M\n")
        self.assertEqual(calls.count("ollama serve"), 1)

    def test_old_runtime_upgrades_and_retries_once(self):
        result, calls, host = self.run_starter("outdated")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("brew upgrade ollama"), 1)
        self.assertEqual(calls.count("ollama pull"), 2)
        self.assertEqual(calls.count("ollama serve"), 2)
        self.assertIsNotNone(host)

    def test_app_update_error_is_actionable(self):
        result, calls, host = self.run_starter("outdated", "app_install")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Restart to update", result.stderr)
        self.assertNotIn("brew upgrade", calls)
        self.assertIsNone(host)

    def test_other_download_error_does_not_upgrade(self):
        result, calls, host = self.run_starter("network_error")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls.count("ollama pull"), 1)
        self.assertNotIn("brew upgrade", calls)
        self.assertIsNone(host)

    def test_cached_weights_are_reused(self):
        result, calls, host = self.run_starter("cached")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("ollama pull", calls)
        self.assertIsNotNone(host)

    def test_occupied_private_port_does_not_reuse_or_stop_external_server(self):
        result, calls, host = self.run_starter("port_busy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Port 11435", result.stderr)
        self.assertEqual(calls, "")
        self.assertIsNone(host)

    def test_cloud_tag_is_rejected(self):
        result, calls, host = self.run_starter(model="model:cloud")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")
        self.assertIsNone(host)

    def test_normal_start_hides_raw_server_version_json(self):
        result, _, host = self.run_starter("cached")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(host)
        self.assertIn("Starting the local model...", result.stdout)
        self.assertNotIn("Local server:", result.stdout)
        self.assertNotIn('"version"', result.stdout)

    def test_verbose_start_keeps_server_version_diagnostics(self):
        result, _, host = self.run_starter("cached", verbose=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(host)
        self.assertIn("Local server:", result.stdout)
        self.assertIn('"version"', result.stdout)

    def test_server_ignoring_sigterm_is_force_stopped(self):
        result, _, host = self.run_starter("cached", "ignore_term")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(host)

    def test_list_failure_does_not_trigger_a_download_or_start_host(self):
        result, calls, host = self.run_starter("list_failed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("database unavailable", result.stderr)
        self.assertNotIn("ollama pull", calls)
        self.assertIsNone(host)

    def test_health_response_without_owned_listener_is_not_reused(self):
        result, calls, host = self.run_starter("cached", "port_race")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("ollama list", calls)
        self.assertIsNone(host)

if __name__ == "__main__":
    unittest.main()

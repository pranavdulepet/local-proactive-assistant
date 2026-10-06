#!/usr/bin/env python3
"""Exercise host startup with the built CLI; never read real Messages or model data."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

CLI = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path(".build/debug/assistantctl").resolve()
FIXTURE = """#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time

assert sys.argv[1:] == ["chats", "--limit", "100", "--json"], sys.argv
Path(os.environ["HOST_TEST_ENTERED"]).touch()
deadline = time.monotonic() + 15
while not Path(os.environ["HOST_TEST_RELEASE"]).exists():
    if time.monotonic() >= deadline:
        sys.exit("Host startup test did not release the transport")
    time.sleep(0.05)
# No matching chat: exit startup before Contacts, stores, or any personal sources.
"""


class HostStartupTests(unittest.TestCase):
    def test_startup_excludes_a_second_host_and_releases_the_lock(self):
        self.assertTrue(CLI.is_file(), "Build assistantctl before running this test.")
        with tempfile.TemporaryDirectory(prefix="assistant-host-startup-") as directory:
            root = Path(directory)
            fixture = root / "imsg"
            fixture.write_text(FIXTURE)
            fixture.chmod(0o700)
            entered, release = root / "entered", root / "release"
            env = dict(os.environ, HOST_TEST_ENTERED=str(entered), HOST_TEST_RELEASE=str(release))
            command = [str(CLI), "serve", "--control-chat-id", "1", "--imsg", str(fixture)]
            first = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while not entered.exists() and first.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not entered.exists():
                    if first.poll() is None:
                        first.terminate()
                    output, errors = first.communicate(timeout=5)
                    self.fail("The first host did not reach Messages setup: " + output + errors)

                second = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(second.returncode, 1, second.stdout + second.stderr)
                self.assertIn("Another assistant host is already running.", second.stderr)

                release.touch()
                output, errors = first.communicate(timeout=10)
                self.assertEqual(first.returncode, 1, output + errors)
                self.assertIn("Control chat must appear in the recent chats", errors)
                self.assertNotIn("already running", errors)

                # The harmless lock file remains; closing the host must allow a new start.
                entered.unlink()
                restarted = subprocess.run(command, env=env, text=True, capture_output=True, timeout=10)
                self.assertTrue(entered.exists(), restarted.stdout + restarted.stderr)
                self.assertIn("Control chat must appear in the recent chats", restarted.stderr)
                self.assertNotIn("already running", restarted.stderr)
            finally:
                release.touch()
                if first.poll() is None:
                    first.terminate()
                    first.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()

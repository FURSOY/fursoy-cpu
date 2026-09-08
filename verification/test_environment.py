"""Failure injection for the lab gate; these do not verify a CPU."""

import sys
import unittest

from tools.check_environment import probe, profile_status


class EnvironmentGateTests(unittest.TestCase):
    def test_real_process_output(self):
        result = probe([sys.executable, "-c", "print('probe-ok')"])
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["stdout"], "probe-ok")

    def test_failed_process_cannot_pass_from_success_text(self):
        result = probe([sys.executable, "-c", "print('PASS'); raise SystemExit(7)"])
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["exit_code"], 7)
        self.assertEqual(profile_status({"fake": result}, ["fake"]), "not_ready")

    def test_missing_executable_blocks_gate(self):
        result = probe(["fursoy-deliberately-missing-tool-698b85fe"])
        self.assertEqual(result["status"], "missing")
        self.assertEqual(profile_status({"fake": result}, ["fake"]), "not_ready")

    def test_hung_process_blocks_gate(self):
        result = probe([sys.executable, "-c", "import time; time.sleep(30)"], timeout=0.2)
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(profile_status({"fake": result}, ["fake"]), "not_ready")


if __name__ == "__main__":
    unittest.main()

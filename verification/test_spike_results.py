import unittest

from tools.run_spike import classify


class SpikeResultTests(unittest.TestCase):
    def setUp(self):
        self.expected = [0x465552534f593031, 1, 1, 0, 11, 0x80000040, 0, 1]
        self.text = "".join(f"{word:016x}\n" for word in self.expected)

    def test_success_requires_both_exit_and_signature(self):
        self.assertEqual(classify(0, False, self.text, self.expected), "pass")
        self.assertEqual(classify(1, False, self.text, self.expected), "reported_failure")

    def test_missing_or_truncated_signature(self):
        self.assertEqual(classify(0, False, None, self.expected), "missing_signature")
        self.assertEqual(classify(0, False, "0000", self.expected), "malformed_signature")

    def test_timeout_overrides_stale_success(self):
        self.assertEqual(classify(0, True, self.text, self.expected), "timeout")

    def test_wrong_trap_pc(self):
        wrong = self.text.replace("0000000080000040", "0000000080000044")
        self.assertEqual(classify(0, False, wrong, self.expected), "signature_mismatch")


if __name__ == "__main__":
    unittest.main()

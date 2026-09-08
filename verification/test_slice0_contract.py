import unittest

from tools.check_slice0 import validate


class Slice0ContractTests(unittest.TestCase):
    def test_checked_contract(self):
        from tools.check_slice0 import PATH
        self.assertEqual(validate(PATH.read_text(encoding="utf-8")), [])

    def test_missing_trap_rule_is_rejected(self):
        from tools.check_slice0 import PATH
        text = PATH.read_text(encoding="utf-8").replace("`mcause=2`", "", 1)
        self.assertIn("Missing slice-0 contract marker: `mcause=2`", validate(text))


if __name__ == "__main__":
    unittest.main()

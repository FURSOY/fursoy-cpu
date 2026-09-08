"""Check that a damaged requirements registry cannot silently pass."""

import unittest

from tools.check_requirements import load, validate


class RequirementsTests(unittest.TestCase):
    def setUp(self):
        self.rows, self.inventory = load()

    def test_registry(self):
        self.assertEqual(validate(self.rows, self.inventory), [])

    def test_deleted_mandatory_group(self):
        rows = [row for row in self.rows if row["id"] != "HYP-003"]
        errors = validate(rows, self.inventory)
        self.assertIn("Unmapped mandatory feature: Shgatpa", errors)

    def test_duplicate_id(self):
        self.assertTrue(any("Duplicate" in item for item in
                            validate(self.rows + [self.rows[0]], self.inventory)))

    def test_false_verification_claim(self):
        self.rows[0]["status"] = "verified"
        self.assertIn("ISA-001: verified without evidence", validate(self.rows, self.inventory))

    def test_missing_test_plan(self):
        self.rows[0]["verification"] = ""
        self.assertIn("ISA-001: empty verification", validate(self.rows, self.inventory))


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from licence_rules import clean_license


class LicenceRulesTests(unittest.TestCase):
    def test_choices_and_combined_requirements(self):
        for value in ["MIT", "MIT/Apache-2.0", "Unlicense / MIT", "MPL-2.0", "Apache-2.0 OR LGPL-2.1-or-later", "MIT AND (GPL-3.0 OR Apache-2.0)"]:
            with self.subTest(value=value):
                self.assertTrue(clean_license(value))
        for value in ["MPL-2.0 AND GPL-3.0", "(MIT OR Apache-2.0) AND GPL-3.0", "MIT AND (GPL-3.0 OR AGPL-3.0)", "GPL-2.0 WITH Classpath-exception-2.0", "", "MIT OR", "(MIT", "MIT GPL", "MIT | GPL"]:
            with self.subTest(value=value):
                self.assertFalse(clean_license(value))


if __name__ == "__main__":
    unittest.main()

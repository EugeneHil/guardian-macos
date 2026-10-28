import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_SWIFT = os.path.join(ROOT, "Project.swift")

# The Xcode target stays "GuardianApp" (bundle id, schemes, build scripts all key off it), but
# the name macOS shows the user — Finder, Activity Monitor, System Settings, notifications — is
# CFBundleDisplayName, set here to just "Guardian".


class DisplayNameTests(unittest.TestCase):
    def test_project_swift_sets_the_display_name_to_guardian(self):
        with open(PROJECT_SWIFT, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn('"CFBundleDisplayName": "Guardian"', text)


if __name__ == "__main__":
    unittest.main()

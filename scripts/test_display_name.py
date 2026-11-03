import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_SWIFT = os.path.join(ROOT, "Project.swift")

BUILD_SH = os.path.join(ROOT, "scripts", "build.sh")
SIGN_SH = os.path.join(ROOT, "scripts", "sign.sh")

# The Xcode target and scheme stay "GuardianApp" (the build scripts key off the scheme), but every
# name a person sees is just "Guardian": CFBundleDisplayName covers Activity Monitor, System
# Settings and notifications, and productName covers the bundle on disk, which is what Finder
# labels it with.


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


class DisplayNameTests(unittest.TestCase):
    def test_project_swift_sets_the_display_name_to_guardian(self):
        self.assertIn('"CFBundleDisplayName": "Guardian"', read(PROJECT_SWIFT))

    def test_project_swift_names_the_product_guardian(self):
        self.assertIn('productName: "Guardian"', read(PROJECT_SWIFT))

    def test_build_scripts_use_the_guardian_bundle_name(self):
        for path in (BUILD_SH, SIGN_SH):
            text = read(path)
            with self.subTest(script=os.path.basename(path)):
                self.assertIn("Guardian.app", text)
                self.assertNotIn("GuardianApp.app", text)


if __name__ == "__main__":
    unittest.main()

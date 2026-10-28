import json
import os
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "GuardianApp", "Resources", "Assets.xcassets", "AppIcon.appiconset")
CONTENTS = os.path.join(ICONSET, "Contents.json")
PROJECT_SWIFT = os.path.join(ROOT, "Project.swift")

# idiom "mac", size "WxH", scale "1x"/"2x" -> pixel side length Xcode expects.
REQUIRED = [
    ("16x16", "1x", 16),
    ("16x16", "2x", 32),
    ("32x32", "1x", 32),
    ("32x32", "2x", 64),
    ("128x128", "1x", 128),
    ("128x128", "2x", 256),
    ("256x256", "1x", 256),
    ("256x256", "2x", 512),
    ("512x512", "1x", 512),
    ("512x512", "2x", 1024),
]


def pixel_size(path):
    out = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True, check=True
    ).stdout
    values = {}
    for line in out.splitlines():
        line = line.strip()
        if ":" in line:
            key, _, value = line.partition(":")
            values[key.strip()] = int(value.strip())
    return values.get("pixelWidth"), values.get("pixelHeight")


class AppIconTests(unittest.TestCase):
    def test_iconset_has_every_required_mac_size(self):
        self.assertTrue(os.path.isdir(ICONSET), f"missing {ICONSET}")
        self.assertTrue(os.path.isfile(CONTENTS), f"missing {CONTENTS}")
        with open(CONTENTS, encoding="utf-8") as fh:
            manifest = json.load(fh)
        entries = {
            (image["size"], image["scale"]): image
            for image in manifest["images"]
            if image.get("idiom") == "mac"
        }
        for size, scale, expected_px in REQUIRED:
            with self.subTest(size=size, scale=scale):
                self.assertIn((size, scale), entries, f"Contents.json is missing {size} {scale}")
                filename = entries[(size, scale)]["filename"]
                path = os.path.join(ICONSET, filename)
                self.assertTrue(os.path.isfile(path), f"missing icon file {path}")
                width, height = pixel_size(path)
                self.assertEqual((width, height), (expected_px, expected_px), path)

    def test_project_swift_declares_resources(self):
        with open(PROJECT_SWIFT, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn('resources: ["GuardianApp/Resources/**"]', text)


if __name__ == "__main__":
    unittest.main()

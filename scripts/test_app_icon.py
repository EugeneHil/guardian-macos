import json
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON = os.path.join(ROOT, "GuardianApp", "Resources", "AppIcon.icon")
MANIFEST = os.path.join(ICON, "icon.json")
PROJECT_SWIFT = os.path.join(ROOT, "Project.swift")

# Liquid Glass (Icon Composer) format: icon.json's "fill" layer covers the full squircle shape
# with no margin, which a flat appiconset image cannot do (the system reserves a safe-zone
# margin around any flat image it has to mask and shadow itself). Layers sit on top of the fill.


class AppIconTests(unittest.TestCase):
    def test_icon_bundle_exists_with_an_opaque_fill_and_a_glyph_layer(self):
        self.assertTrue(os.path.isdir(ICON), f"missing {ICON}")
        self.assertTrue(os.path.isfile(MANIFEST), f"missing {MANIFEST}")
        with open(MANIFEST, encoding="utf-8") as fh:
            manifest = json.load(fh)

        fill = manifest.get("fill", {})
        self.assertIn("solid", fill, "fill should be an opaque solid color, not a gradient or absent")
        # srgb:R,G,B,A — the 4th component is alpha; must be fully opaque so no backdrop shows
        # through (a transparent/translucent fill let macOS composite its own backdrop behind
        # it, which was white in some contexts and made the white glyph invisible).
        alpha = float(fill["solid"].split(":", 1)[1].split(",")[3])
        self.assertEqual(alpha, 1.0, "fill must be fully opaque")

        groups = manifest.get("groups", [])
        self.assertTrue(groups, "icon.json has no layer groups: the glyph was never added")
        layers = [layer for group in groups for layer in group.get("layers", [])]
        self.assertTrue(layers, "icon.json has no layers inside its groups")
        for layer in layers:
            with self.subTest(layer=layer.get("name")):
                image_name = layer["image-name"]
                path = os.path.join(ICON, "Assets", image_name)
                self.assertTrue(os.path.isfile(path), f"missing layer image {path}")
                self.assertFalse(layer.get("hidden", False), f"layer {image_name} is hidden")

        platforms = manifest.get("supported-platforms", {}).get("squares", [])
        self.assertIn("macOS", platforms)

    def test_project_swift_declares_resources_and_the_icon_name(self):
        with open(PROJECT_SWIFT, encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn('resources: ["GuardianApp/Resources/**"]', text)
        self.assertIn('"ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"', text)


if __name__ == "__main__":
    unittest.main()

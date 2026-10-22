import contextlib
import io
import json
import os
import tempfile
import unittest

import coverage_gate


def report(files):
    """Build a minimal xccov JSON report from {path: (covered, executable)}."""
    return {
        "targets": [
            {
                "name": "T.xctest",
                "files": [
                    {"path": p, "coveredLines": c, "executableLines": e}
                    for p, (c, e) in files.items()
                ],
            }
        ]
    }


class CoverageGateTests(unittest.TestCase):
    def run_gate(self, data, *extra):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "r.json")
            with open(path, "w") as f:
                json.dump(data, f)
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                code = coverage_gate.main(["--min", "80", *extra, path])
            return code, out.getvalue()

    def test_passes_at_threshold(self):
        code, out = self.run_gate(report({"/a/Logic/X.swift": (80, 100)}))
        self.assertEqual(code, 0, out)
        self.assertIn("80.0", out)

    def test_fails_below_threshold(self):
        code, _ = self.run_gate(report({"/a/Logic/X.swift": (79, 100)}))
        self.assertEqual(code, 1)

    def test_excluded_files_are_ignored(self):
        data = report({"/a/Logic/X.swift": (90, 100), "/a/Views/V.swift": (0, 1000), "/a/Tests/T.swift": (0, 50)})
        code, out = self.run_gate(data)
        self.assertEqual(code, 0, out)
        code, _ = self.run_gate(data, "--exclude", "Logic")
        self.assertEqual(code, 1)

    def test_empty_report_fails(self):
        code, _ = self.run_gate({"targets": []})
        self.assertEqual(code, 1)

    def test_files_are_merged_across_targets(self):
        data = {"targets": [
            {"files": [{"path": "/a/Logic/X.swift", "coveredLines": 0, "executableLines": 10}]},
            {"files": [{"path": "/a/Logic/X.swift", "coveredLines": 10, "executableLines": 10}]},
        ]}
        code, _ = self.run_gate(data)
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()

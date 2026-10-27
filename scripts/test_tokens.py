import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "tokens.py")
SWIFT = os.path.join(ROOT, "GuardianApp", "Sources", "DesignSystem", "Tokens.swift")
CORE = os.path.join(ROOT, "external", "guardian-core")


def run(*args):
    return subprocess.run([sys.executable, "-I", "-B", SCRIPT, *args], capture_output=True, text=True)


def core_status():
    return subprocess.run(
        ["git", "-C", CORE, "status", "--porcelain"], capture_output=True, text=True, check=True
    ).stdout


class TokensTests(unittest.TestCase):
    def setUp(self):
        self.original = None
        if os.path.exists(SWIFT):
            with open(SWIFT, "rb") as fh:
                self.original = fh.read()

    def tearDown(self):
        if self.original is None:
            if os.path.exists(SWIFT):
                os.unlink(SWIFT)
        else:
            with open(SWIFT, "wb") as fh:
                fh.write(self.original)

    def test_check_fails_when_file_missing(self):
        if os.path.exists(SWIFT):
            os.unlink(SWIFT)
        result = run("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing", result.stderr)

    def test_check_fails_when_file_stale(self):
        os.makedirs(os.path.dirname(SWIFT), exist_ok=True)
        with open(SWIFT, "w") as fh:
            fh.write("// stale\n")
        result = run("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("stale", result.stderr)

    def test_check_passes_after_generation(self):
        self.assertEqual(run().returncode, 0)
        self.assertEqual(run("--check").returncode, 0)

    def test_generation_leaves_submodule_clean(self):
        before = core_status()
        self.assertEqual(run().returncode, 0)
        self.assertEqual(run("--check").returncode, 0)
        self.assertEqual(core_status(), before)


if __name__ == "__main__":
    unittest.main()

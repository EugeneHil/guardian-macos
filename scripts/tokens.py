#!/usr/bin/env python3
"""Generate WardenApp/Sources/DesignSystem/Tokens.swift from the warden-core design tokens.

Usage: python3 -I -B scripts/tokens.py [--check]

Without arguments, regenerates Tokens.swift. With --check, generates into a temporary directory
and exits 1 when Tokens.swift is missing or differs. warden-core's generator also writes a CSS
file; it is sent to a temporary directory so the submodule stays clean.
"""
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR = os.path.join(ROOT, "external", "warden-core", "design-tokens", "generate.py")
SWIFT_PATH = os.path.join(ROOT, "WardenApp", "Sources", "DesignSystem", "Tokens.swift")


def generate(css_out, swift_out):
    result = subprocess.run(
        [sys.executable, "-I", "-B", GENERATOR, "--css", css_out, "--swift", swift_out],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr or result.stdout)
        sys.stderr.write("tokens: generator failed\n")
        return False
    return True


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="exit 1 if Tokens.swift is stale")
    args = parser.parse_args(argv)

    with tempfile.TemporaryDirectory() as tmp:
        css = os.path.join(tmp, "tokens.css")
        fresh = os.path.join(tmp, "Tokens.swift")
        if not generate(css, fresh):
            return 1
        with open(fresh, "rb") as fh:
            expected = fh.read()
        if not args.check:
            os.makedirs(os.path.dirname(SWIFT_PATH), exist_ok=True)
            # Stage next to the target so os.replace is atomic on the same filesystem.
            fd, partial = tempfile.mkstemp(dir=os.path.dirname(SWIFT_PATH), suffix=".tmp")
            try:
                with os.fdopen(fd, "wb") as out:
                    out.write(expected)
                os.replace(partial, SWIFT_PATH)
            except BaseException:
                if os.path.exists(partial):
                    os.unlink(partial)
                raise
            return 0
        try:
            with open(SWIFT_PATH, "rb") as fh:
                current = fh.read()
        except FileNotFoundError:
            sys.stderr.write("tokens: Tokens.swift is missing; run scripts/tokens.py\n")
            return 1
        if current != expected:
            sys.stderr.write("tokens: Tokens.swift is stale; run scripts/tokens.py\n")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

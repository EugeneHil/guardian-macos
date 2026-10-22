#!/usr/bin/env python3
"""Line-coverage gate for `xcrun xccov view --report --json` output (stdlib only, Python 3.9+)."""
import argparse
import json
import re
import sys

DEFAULT_EXCLUDES = [r"/Views/", r"/Entry/", r"/DesignSystem/", r"/ES/", r"Keychain", r"/Tests/"]


def collect(report, excludes):
    """Return {path: (covered, executable)}; a file compiled into several targets keeps its best entry."""
    files = {}
    for target in report.get("targets", []):
        for f in target.get("files", []):
            path = f.get("path", "")
            if any(e.search(path) for e in excludes):
                continue
            entry = (int(f.get("coveredLines", 0)), int(f.get("executableLines", 0)))
            if path not in files or entry[0] > files[path][0]:
                files[path] = entry
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min", type=float, default=80.0, help="minimum line coverage in percent")
    parser.add_argument("--exclude", action="append", default=None, help="path regex to ignore (repeatable)")
    parser.add_argument("reports", nargs="+", help="xccov JSON report(s)")
    args = parser.parse_args(argv)

    patterns = DEFAULT_EXCLUDES + (args.exclude or [])
    excludes = [re.compile(p) for p in patterns]

    files = {}
    for path in args.reports:
        with open(path, encoding="utf-8") as fh:
            for k, v in collect(json.load(fh), excludes).items():
                if k not in files or v[0] > files[k][0]:
                    files[k] = v

    covered = sum(c for c, _ in files.values())
    total = sum(e for _, e in files.values())
    if total == 0:
        print("coverage gate: no executable lines in the report", file=sys.stderr)
        return 1
    pct = 100.0 * covered / total
    print("coverage gate: %.1f%% (%d/%d lines, %d files), minimum %.1f%%" % (pct, covered, total, len(files), args.min))
    if pct < args.min:
        for p, (c, e) in sorted(files.items(), key=lambda kv: kv[1][0] - kv[1][1]):
            if e:
                print("  %6.1f%%  %s" % (100.0 * c / e, p), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

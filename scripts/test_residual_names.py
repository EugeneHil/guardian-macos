"""Guards against leftovers of the former product name (Warden -> Guardian).

Each group pairs the pattern with the set of files it covers and a flag that says
whether it is enforced yet. Groups are switched on as the rename lands.
`all` covers every tracked file; `identity` covers every tracked file but only matches
the identifier literals (bundle ids, paths, keys) that must change together with the code.
Run: python3 -I -B -m unittest discover -s scripts
"""
import fnmatch
import os
import re
import subprocess
import unittest
from collections import namedtuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

Group = namedtuple("Group", "pattern paths enforced")

PATTERN = re.compile(r"warden|wdn(?!_)", re.IGNORECASE)

# Literals that identify the product at run time (bundle ids and the log subsystem, the
# application-support directory, the userInfo key of the XPC validation errors).
IDENTITY_PATTERN = re.compile(
    r"io\.github\.eugenehil\.warden|Application Support/Warden|WardenValidationErrors",
    re.IGNORECASE,
)

SWIFT_GLOBS = (
    "*.swift",
    "Tuist/*",
    "*.plist",
    "*.entitlements",
    ".swiftlint.yml",
    ".swiftformat",
    "*.xcconfig",
)
SCRIPT_GLOBS = ("scripts/*", ".github/*", "tooling/*", ".claude/*")
SCRIPT_FILES = (".gitignore", ".gitleaks.toml")


def matches_any(path, globs):
    return any(fnmatch.fnmatchcase(path, glob) for glob in globs)


def is_submodule_path(path):
    return path == ".gitmodules" or path.startswith("external/")


def is_docs_path(path):
    return path.endswith(".md")


def is_swift_path(path):
    return matches_any(path, SWIFT_GLOBS)


def is_swift_name_path(path):
    # Path names (not contents) outside docs/ and scripts/ must be renamed with the code.
    return not path.startswith(("docs/", "scripts/"))


def is_scripts_path(path):
    return path in SCRIPT_FILES or matches_any(path, SCRIPT_GLOBS)


GROUPS = {
    "submodule": Group(PATTERN, is_submodule_path, False),
    "docs": Group(PATTERN, is_docs_path, True),
    "swift": Group(PATTERN, is_swift_path, False),
    "scripts": Group(PATTERN, is_scripts_path, False),
    "identity": Group(IDENTITY_PATTERN, lambda path: True, False),
    "all": Group(PATTERN, lambda path: True, False),
}

# Groups whose path names are checked for a wider set of files than their contents.
NAME_PATHS = {"swift": is_swift_name_path}

# Groups in which a line matching the identity patterns is exempt (the `identity` group owns it).
IDENTITY_LINES_EXEMPT = {"swift"}

# Files exempt from a group because they must spell the old name.
SELF = "scripts/test_residual_names.py"
RENAME_SPEC = "docs/superpowers/specs/2026-10-26-guardian-rename-design.md"
RENAME_PLAN = "docs/superpowers/plans/2026-10-26-guardian-rename.md"
ALLOW = {name: {SELF} for name in GROUPS}
# The rename's own spec and plan describe the old names by definition.
for _group in ("docs", "identity", "all"):
    ALLOW[_group] |= {RENAME_SPEC, RENAME_PLAN}

# A line that is exactly this note is the "formerly" marker under a title; it is exempt everywhere.
FORMER_NAME_NOTE = "> Formerly Warden."


def is_exempt_line(line):
    return line.strip() == FORMER_NAME_NOTE


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
    ).stdout
    return [p for p in out.decode("utf-8").split("\0") if p]


def read_text(path):
    try:
        with open(os.path.join(ROOT, path), "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def offenders(group_name):
    group = GROUPS[group_name]
    allowed = ALLOW[group_name]
    name_paths = NAME_PATHS.get(group_name, group.paths)
    found = []
    for path in tracked_files():
        if path in allowed:
            continue
        if name_paths(path) and group.pattern.search(path):
            found.append(f"{path}: path name")
        if not group.paths(path):
            continue
        text = read_text(path)
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if not group.pattern.search(line) or is_exempt_line(line):
                continue
            if group_name in IDENTITY_LINES_EXEMPT and IDENTITY_PATTERN.search(line):
                continue
            found.append(f"{path}:{number}: {line.strip()}")
    return found


LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
DOCS_MENTION = re.compile(r"(docs/[A-Za-z0-9_./-]+\.md)")
# Links into sibling repositories and external sites are out of scope.
EXTERNAL = ("http://", "https://", "mailto:", "#", "guardian-core/", "guardian-server/")


def broken_references():
    tracked = set(tracked_files())
    broken = []
    for path in sorted(tracked):
        if not path.endswith(".md") or path.startswith("external/"):
            continue
        text = read_text(path)
        if text is None:
            continue
        base = os.path.dirname(path)
        for number, line in enumerate(text.splitlines(), 1):
            for target in LINK.findall(line):
                if target.startswith(EXTERNAL):
                    continue
                target = target.split("#", 1)[0]
                if not target:
                    continue
                resolved = os.path.normpath(os.path.join(base, target))
                is_dir = any(t.startswith(resolved + "/") for t in tracked)
                if resolved not in tracked and not is_dir:
                    broken.append(f"{path}:{number}: link {target}")
            if path in ("CLAUDE.md", "README.md"):
                for mention in DOCS_MENTION.findall(line):
                    if mention not in tracked:
                        broken.append(f"{path}:{number}: path {mention}")
    return broken


class ExemptLine(unittest.TestCase):
    def test_only_the_exact_note_is_exempt(self):
        self.assertTrue(is_exempt_line("> Formerly Warden."))
        self.assertTrue(is_exempt_line("> Formerly Warden.  \n"))
        self.assertFalse(is_exempt_line("> Formerly Warden. See the old docs."))
        self.assertFalse(is_exempt_line("Formerly Warden."))
        self.assertFalse(is_exempt_line("> Formerly Warden server."))
        self.assertFalse(is_exempt_line("Warden"))


class CrossReferences(unittest.TestCase):
    def test_cross_references_resolve(self):
        broken = broken_references()
        self.assertEqual(broken, [], "unresolved references:\n" + "\n".join(broken))


class ResidualNames(unittest.TestCase):
    def _check(self, name):
        if not GROUPS[name].enforced:
            self.skipTest(f"group {name!r} is not enforced yet")
        found = offenders(name)
        self.assertEqual(found, [], f"residual names in group {name!r}:\n" + "\n".join(found))

    def test_group_submodule(self):
        self._check("submodule")

    def test_group_docs(self):
        self._check("docs")

    def test_group_swift(self):
        self._check("swift")

    def test_group_scripts(self):
        self._check("scripts")

    def test_group_identity(self):
        self._check("identity")

    def test_group_all(self):
        self._check("all")


if __name__ == "__main__":
    unittest.main()

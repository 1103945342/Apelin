#!/usr/bin/env python3
"""Fail when the app still reaches for Fila or iGhostVT, or depends on them.

Both used to be how Apelin showed a folder: the chat menu opened
`ighostvt://new?directory=…` and `fila://open?path=…&tab=new`, Settings ▸ SDKs
and Toolchains revealed a folder with `fila://reveal`, and the package made
both apps mandatory. The terminal and the file browser are the app's own now
(`TerminalPresenter`, `FileBrowserPresenter`), so a runtime reference to
either app is a leftover: a page that still opens a URL instead of the
built-in one, a query at launch, or a dependency that would install an app
nobody needs.

What counts as a runtime reference, and what does not:

- A URL scheme — `fila://`, `ighostvt://`, or a `scheme` assigned one of the
  two names — in any source root, `Tests/` and `build/` left out.
- A bundle identifier — `wiki.qaq.fila`, `wiki.qaq.ighostvt` — written into a
  source file (a fixture belongs under `Tests/`) or called for by the
  package's `Depends`/`Pre-Depends`.
- A `LSApplicationQueriesSchemes` entry naming either scheme, which is a
  launch-time query for the app.

Attribution is not a reference: a comment that says a module was ported from
Fila, or a design token taken from iGhostVT, names no URL, no bundle
identifier and no dependency, and passes. Test fixtures under `Tests/` and
the sample crash reports under `Packages/ApelinDiagnostics/Tests/` are data,
not the app reaching for anything.

Usage: check-retired-apps.py [<root>]
       check-retired-apps.py .            (the repository root)

Exit 0 clean, 64 on a bad command line, 65 on a reference, 66 when a root is
missing.
"""

import os
import re
import sys

# Roots whose sources the app, the daemon and the extensions are built from.
SOURCE_ROOTS = ["Apelin", "Apelind", "Shared", "Widgets", "Extensions", "Workers", "Packages"]
SOURCE_SUFFIXES = (".swift", ".m", ".mm", ".h", ".c", ".cpp")
PLIST_SUFFIX = ".plist"
SKIP_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedFiles", "DerivedData", "node_modules"}

RETIRED = ("fila", "ighostvt")
BUNDLE_IDS = ("wiki.qaq.fila", "wiki.qaq.ighostvt")

SCHEME_URL = re.compile(r"\b(fila|ighostvt)://", re.IGNORECASE)
SCHEME_ASSIGNMENT = re.compile(r"""\bscheme\s*[:=]\s*"(fila|ighostvt)\"""", re.IGNORECASE)
BUNDLE_ID = re.compile(r"\bwiki\.qaq\.(?:fila|ighostvt)\b")
QUERY_ENTRY = re.compile(r"<string>\s*(fila|ighostvt)\s*</string>", re.IGNORECASE)
CONTROL_DEPENDENCY = re.compile(
    r"^(?:Pre-Depends|Depends):.*\bwiki\.qaq\.(?:fila|ighostvt)\b",
    re.IGNORECASE | re.MULTILINE,
)


def walk(root, suffixes):
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = [name for name in subdirs if name not in SKIP_DIRS]
        for name in files:
            if name.endswith(suffixes):
                yield os.path.join(directory, name)


def skipped(path):
    """Test fixtures and build output are data, and an agent's scratch is not source."""
    parts = path.split(os.sep)
    return "Tests" in parts


def scan(root):
    problems = []
    for path in walk(root, SOURCE_SUFFIXES):
        if skipped(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            for number, line in enumerate(handle, 1):
                for pattern in (SCHEME_URL, SCHEME_ASSIGNMENT, BUNDLE_ID):
                    if pattern.search(line):
                        problems.append(f"{path}:{number}: {line.strip()}")
                        break
    for path in walk(root, (PLIST_SUFFIX,)):
        if skipped(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        if "LSApplicationQueriesSchemes" not in text:
            continue
        for match in QUERY_ENTRY.finditer(text):
            problems.append(f"{path}: LSApplicationQueriesSchemes names '{match.group(1)}'")
    control = os.path.join(root, "Packaging", "DEBIAN", "control")
    if os.path.isfile(control):
        with open(control, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        for match in CONTROL_DEPENDENCY.finditer(text):
            problems.append(f"{control}: {match.group(0).strip()}")
    return problems


def main(arguments):
    if len(arguments) > 1:
        print(__doc__, file=sys.stderr)
        return 64
    root = arguments[0] if arguments else "."
    missing = [name for name in SOURCE_ROOTS if not os.path.isdir(os.path.join(root, name))]
    if missing:
        print(f"error: no such root(s) under {root}: {', '.join(missing)}", file=sys.stderr)
        return 66
    problems = scan(root)
    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        print(
            "error: Fila and iGhostVT are no longer reached or depended on — use "
            "TerminalPresenter and FileBrowserPresenter",
            file=sys.stderr,
        )
        return 65
    print("ok: no runtime reference to Fila or iGhostVT, and no dependency on either")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Fail when a conversation reaches the page or the sidebar on its own.

The bug this guards: tapping a conversation link moved the sidebar's highlight
and left the page showing the previous conversation, so what the reader read
and what the app said was picked were two different conversations. It came
from a second way in — `SidebarController.select(_:)` called directly, with
nothing putting that conversation on the page.

There is one way in now: `RootInterfaceController.open(_:picked:)`, which
moves the highlight (`sidebar.highlight(_:)`) and then the page
(`chatController.use(_:)`) together. Every other caller — a row, New Chat, the
launch, a fork, an `apelin://` link, a delete, a recovery — goes through it.
So both calls must be inside that one function, and the sidebar's own
`select` must not be reachable from outside the sidebar.

Usage: check-chat-pairing.py <root>

Exit 0 clean, 65 when a conversation is reached some other way.
"""

import os
import re
import sys

SKIP_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "node_modules", ".claude", "Vendor", "__pycache__"}
SKIP_PATHS = ("Packages/Runestone/",)
SOURCE_ROOTS = ("Apelin", "Apelind", "Workers", "Shared", "Widgets", "Extensions", "Packages")

ROOT_FILE = "Apelin/Interface/Root/RootInterfaceController.swift"
PAIRED = ("sidebar.highlight(", "chatController.use(")
# The sidebar's own picking, which the root must never do by itself.
UNPAIRED = "sidebar.select("


def code_only(text):
    """The file with its strings emptied and its comments blanked, line for line."""
    text = re.sub(r'""".*?"""', lambda match: "\n" * match.group().count("\n"), text, flags=re.S)
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    text = re.sub(r"/\*.*?\*/", lambda match: "\n" * match.group().count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def line_of(text, index):
    return text.count("\n", 0, index) + 1


def bodies(text, name, wants=None):
    """Every function called `name`, as (signature start, body start, body end).
    `wants`, when given, keeps only the signatures that contain it."""
    found = []
    for match in re.finditer(r"\bfunc\s+" + re.escape(name) + r"\s*\(", text):
        depth = 0
        index = match.end() - 1
        while index < len(text):
            character = text[index]
            if character in "([":
                depth += 1
            elif character in ")]":
                depth -= 1
            elif character == "{" and depth == 0:
                break
            index += 1
        if index >= len(text):
            continue
        signature = text[match.end():index]
        if wants is not None and wants not in signature:
            continue
        depth = 0
        end = index
        while end < len(text):
            character = text[end]
            if character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    end += 1
                    break
            end += 1
        found.append((match.start(), index, end))
    return found


def check_pairing(root):
    path = os.path.join(root, ROOT_FILE)
    if not os.path.isfile(path):
        return [f"{ROOT_FILE} is missing"]
    with open(path, encoding="utf-8") as handle:
        text = code_only(handle.read())
    entries = bodies(text, "open", wants="picked:")
    if len(entries) != 1:
        return [f"{ROOT_FILE}: expected one `open(_:picked:)`, found {len(entries)}"]
    _, start, end = entries[0]
    problems = []
    for call in PAIRED:
        if call not in text[start:end]:
            problems.append(
                f"{ROOT_FILE}:{line_of(text, start)}: `open(_:picked:)` never calls `{call}`, "
                "so one of the two moves without the other",
            )
        for match in re.finditer(re.escape(call), text):
            if not start <= match.start() < end:
                problems.append(
                    f"{ROOT_FILE}:{line_of(text, match.start())}: `{call}` outside "
                    "`open(_:picked:)`, which is the one place that moves the page and "
                    "the sidebar's highlight together",
                )
    for match in re.finditer(re.escape(UNPAIRED), text):
        problems.append(
            f"{ROOT_FILE}:{line_of(text, match.start())}: `{UNPAIRED}` moves the "
            "sidebar alone; call `open(_:picked:)` instead",
        )
    return problems


def check_sources(root):
    problems = []
    for source in SOURCE_ROOTS:
        folder_root = os.path.join(root, source)
        if not os.path.isdir(folder_root):
            continue
        for folder, directories, files in os.walk(folder_root):
            directories[:] = [name for name in directories if name not in SKIP_DIRS]
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(folder, name)
                relative = os.path.relpath(path, root)
                if relative.startswith(SKIP_PATHS) or relative == ROOT_FILE:
                    continue
                with open(path, encoding="utf-8") as handle:
                    text = code_only(handle.read())
                for call in PAIRED + (UNPAIRED,):
                    for match in re.finditer(re.escape(call), text):
                        problems.append(
                            f"{relative}:{line_of(text, match.start())}: `{call}` reaches a "
                            "conversation from outside `RootInterfaceController.open(_:picked:)`",
                        )
    return problems


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 64
    root = sys.argv[1]
    problems = check_pairing(root) + check_sources(root)
    if problems:
        print("error: the conversation page and the sidebar's highlight move apart from here:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main())

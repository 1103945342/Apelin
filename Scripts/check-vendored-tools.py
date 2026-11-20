#!/usr/bin/env python3
"""Fail when the tools Luros carries beside it drift from what says so.

`Vendor/` holds the `icli` and the two Irisin binaries the package no longer
depends on: the daemon and the helper it runs to install anything. Three things
have to agree with it, and a change to one that leaves the others behind is the
bug this checks for:

- `Vendor/README.md` names each file's version and SHA-256, and the file on
  disk matches its digest and carries an execute bit.
- `Scripts/package-deb.sh` stages each into `Luros.app/Vendor/` and proves
  the packaged deb holds them.
- `Packaging/DEBIAN/control` depends on neither package, and the maintainer
  scripts register the bundled daemon under Luros's own label, put its helper
  at the path it looks for, and remove both, never Irisin's.

Usage: check-vendored-tools.py <root>

Exit 0 clean, 65 when something does not agree.
"""

import hashlib
import os
import re
import sys

# path in the bundle -> the package the binary came from
TOOLS = {
    "bin/icli": "com.icli.icli",
    "libexec/irisind": "wiki.qaq.irisin",
    "libexec/irisin-install": "wiki.qaq.irisin",
}
LABEL = "com.fluoxetine.luros.irisind"


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    problems = []

    readme_path = os.path.join(root, "Vendor", "README.md")
    if not os.path.isfile(readme_path):
        print("error: Vendor/README.md is missing", file=sys.stderr)
        return 65
    readme = read(readme_path)

    for relative in TOOLS:
        path = os.path.join(root, "Vendor", relative)
        if not os.path.isfile(path):
            problems.append(f"Vendor/{relative} is missing")
            continue
        if not os.stat(path).st_mode & 0o111:
            problems.append(f"Vendor/{relative} is not executable")
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        row = re.search(
            r"^\|\s*`" + re.escape(relative) + r"`\s*\|[^|]*\|[^|]*\|\s*`([0-9a-f]{64})`\s*\|$",
            readme,
            re.M,
        )
        if not row:
            problems.append(f"Vendor/README.md has no digest row for {relative}")
        elif row.group(1) != digest:
            problems.append(
                f"Vendor/{relative} is {digest}, but README.md records {row.group(1)}: "
                "update the table when the binary changes",
            )

    control = read(os.path.join(root, "Packaging", "DEBIAN", "control"))
    depends = [line for line in control.splitlines() if line.startswith(("Depends:", "Pre-Depends:"))]
    for package in TOOLS.values():
        if any(package in line for line in depends):
            problems.append(f"control depends on {package}, which the bundle carries")

    packaging = read(os.path.join(root, "Scripts", "package-deb.sh"))
    for relative in TOOLS:
        if f"Vendor/{relative}" not in packaging:
            problems.append(f"package-deb.sh never stages Vendor/{relative}")

    postinst = read(os.path.join(root, "Packaging", "DEBIAN", "postinst"))
    if LABEL not in postinst or "wiki.qaq.irisin.service" not in postinst:
        problems.append("postinst does not register the bundled daemon under " + LABEL)
    if "Vendor/libexec/irisind" not in postinst:
        problems.append("postinst does not launch the bundled irisind")
    if "Vendor/libexec/irisin-install" not in postinst or "@PREFIX@/usr/libexec/irisin-install" not in postinst:
        problems.append("postinst does not put Irisin's install helper beside the bundled daemon")
    if "wiki.qaq.irisind.plist" not in postinst:
        problems.append("postinst registers the bundled daemon without checking for Irisin's own")

    for script in ("prerm", "postrm"):
        text = read(os.path.join(root, "Packaging", "DEBIAN", script))
        if LABEL not in text:
            problems.append(f"{script} never stops {LABEL}")
        if "wiki.qaq.irisind.plist" in text or "system/wiki.qaq.irisind" in text:
            problems.append(f"{script} names Irisin's own job, which Luros does not own")
    if f'rm -f "${{iris_plist:?}}"' not in read(os.path.join(root, "Packaging", "DEBIAN", "postrm")):
        problems.append("postrm does not remove the job file Luros wrote")

    for problem in problems:
        print("error: " + problem, file=sys.stderr)
    return 65 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

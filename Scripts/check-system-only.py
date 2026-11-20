#!/usr/bin/env python3
"""Fail when anything but system code can reach a root process.

lurosd (the proxy and its session host) and luros-log-reader run as root
and link nothing third-party. They link LurosCore and LurosProtocol from
Packages/LurosKit, so those two targets may depend on each other and on
nothing else — no package dependency, no other target.

The session host also runs agent tool extensions through LurosToolHost
(Packages/LurosToolHost), whose LurosToolHost and LurosToolCore targets
are held to the same rule: no package dependency, and no target but each
other. Its other products (the extension side, the test double) never link
into a root process.

luros-log-reader also links LurosLogReaderWorker from
Packages/LurosDiagnostics, whose closure may hold only LurosLogReader, its
Objective-C shim and the shared request types, plus LurosCore and
LurosProtocol — never icli.

In the Xcode project, the Lurosd target may link those products and no
other; WorkerLogReader links LurosCore, LurosProtocol and
LurosLogReaderWorker only. The vendored
IrisinExternalClient is source compiled into lurosd, not a package, and
imports system modules only (checked below).

Usage: check-system-only.py <LurosKit> [--scratch-path <dir>]
           [--toolhost-scratch-path <dir>] [--diagnostics-scratch-path <dir>]
"""

import argparse
import json
import os
import re
import subprocess
import sys

KIT_SYSTEM_ONLY = {"LurosCore", "LurosProtocol"}
TOOLHOST_SYSTEM_ONLY = {"LurosToolCore", "LurosToolHost"}
ROOT_XCODE_TARGETS = {
    "Lurosd": KIT_SYSTEM_ONLY | TOOLHOST_SYSTEM_ONLY,
    "WorkerLogReader": KIT_SYSTEM_ONLY | {"LurosLogReaderWorker"},
}
# Packages/LurosDiagnostics: what LurosLogReaderWorker may reach.
LOG_READER_ROOT = "LurosLogReaderWorker"
LOG_READER_CLOSURE = {"LurosLogReaderWorker", "LurosLogReader", "LurosLogReaderSPI", "LurosDiagnosticsCore"}
VENDORED_SOURCES = ["Lurosd/Vendor/IrisinExternalClient"]
SYSTEM_MODULES = {"CIrisinExternalXPC", "CryptoKit", "Darwin", "Dispatch", "Foundation", "XPC"}


def fail(message):
    print(f"error: check-system-only: {message}", file=sys.stderr)
    sys.exit(1)


def dependency_names(dependency):
    # dump-package spells a dependency {"byName": [name, null]},
    # {"target": [name, null]} or {"product": [name, package, …]}.
    for kind, value in dependency.items():
        name = value[0] if isinstance(value, list) and value else value
        package = value[1] if isinstance(value, list) and len(value) > 1 else None
        yield kind, name, package


def dump_package(package_path, scratch_path):
    command = ["swift", "package", "dump-package", "--package-path", package_path]
    if scratch_path:
        command += ["--scratch-path", scratch_path]
    return json.loads(subprocess.run(command, check=True, capture_output=True, text=True).stdout)


def check_package(package_path, scratch_path, system_only):
    manifest = dump_package(package_path, scratch_path)
    for target in manifest["targets"]:
        if target["name"] not in system_only:
            continue
        for dependency in target.get("dependencies", []):
            for kind, name, _ in dependency_names(dependency):
                if kind == "product" or name not in system_only:
                    fail(f"{target['name']} depends on {name}: it links into a root process, which takes system code only")


def check_log_reader(package_path, scratch_path):
    """Walks LurosLogReaderWorker's dependencies inside its package."""
    manifest = dump_package(package_path, scratch_path)
    targets = {target["name"]: target for target in manifest["targets"]}
    if LOG_READER_ROOT not in targets:
        fail(f"no {LOG_READER_ROOT} target in {package_path}")
    pending, seen = [LOG_READER_ROOT], set()
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        if name not in LOG_READER_CLOSURE:
            fail(f"{LOG_READER_ROOT} reaches {name}: luros-log-reader runs as root and takes system code only")
        for dependency in targets[name].get("dependencies", []):
            for kind, dependency_name, package in dependency_names(dependency):
                if kind == "product":
                    if package != "LurosKit" or dependency_name not in KIT_SYSTEM_ONLY:
                        fail(f"{name} depends on product {dependency_name}: luros-log-reader takes system code only")
                else:
                    pending.append(dependency_name)


def check_project(project):
    text = open(os.path.join(project, "project.pbxproj"), encoding="utf-8").read()
    for name, allowed in ROOT_XCODE_TARGETS.items():
        match = re.search(r"/\* " + name + r" \*/ = \{\s*isa = PBXNativeTarget;(.*?)\n\t\t\};", text, re.S)
        if not match:
            fail(f"no {name} target in the project")
        products = re.search(r"packageProductDependencies = \((.*?)\);", match.group(1), re.S)
        linked = set(re.findall(r"/\* (\w+) \*/", products.group(1))) if products else set()
        extra = linked - allowed
        if extra:
            fail(f"{name} links {', '.join(sorted(extra))}; it may link {', '.join(sorted(allowed))} only")


def check_vendored(repository):
    for relative in VENDORED_SOURCES:
        directory = os.path.join(repository, relative)
        if not os.path.isfile(os.path.join(directory, "LICENSE")):
            fail(f"{relative} has no LICENSE beside it")
        for root, _, files in os.walk(directory):
            for name in files:
                if not name.endswith(".swift"):
                    continue
                source = open(os.path.join(root, name), encoding="utf-8").read()
                for module in re.findall(r"^\s*(?:@\w+\s+)*import\s+(\w+)", source, re.M):
                    if module not in SYSTEM_MODULES:
                        fail(f"{relative}/{name} imports {module}; vendored code in lurosd takes system modules only")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("package")
    parser.add_argument("--scratch-path")
    parser.add_argument("--toolhost-scratch-path")
    parser.add_argument("--diagnostics-scratch-path")
    arguments = parser.parse_args()
    packages = os.path.dirname(os.path.abspath(arguments.package))
    repository = os.path.dirname(packages)
    check_package(arguments.package, arguments.scratch_path, KIT_SYSTEM_ONLY)
    check_package(os.path.join(packages, "LurosToolHost"), arguments.toolhost_scratch_path, TOOLHOST_SYSTEM_ONLY)
    check_log_reader(os.path.join(packages, "LurosDiagnostics"), arguments.diagnostics_scratch_path)
    check_project(os.path.join(repository, "Luros.xcodeproj"))
    check_vendored(repository)
    print("ok: lurosd and luros-log-reader link system code only")


if __name__ == "__main__":
    main()

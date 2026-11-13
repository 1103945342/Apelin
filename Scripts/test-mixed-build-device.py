#!/usr/bin/env python3
"""Exercise BuildPipeline's real compile/link methods with the on-device CLT.

Run in the repository: python3 Scripts/test-mixed-build-device.py
Requires Apelin's APELIN_PROJECT_ROOT, APELIN_TOOLCHAIN_BIN, SDKROOT and ldid.
All generated files stay in .build/mixed-device; no app/package is installed.
This is a compile/link/runtime smoke test, NOT a substitute for make check or
BuildService/Mach-O verification/packaging tests. Full XCTest runs on CI.
"""
import json
import os
from pathlib import Path
import re
import subprocess

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / ".build/mixed-device"
KIT = REPO / "Packages/ApelinKit/Sources"
ENTITLEMENTS = "Extensions/Development/wiki.qaq.apelin.dev.cli/templates/c/Packaging/Tool.entitlements"


def write(relative, text):
    path = OUT / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def run(argv, cwd=REPO):
    result = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError("{} exited {}\n{}".format(argv[0], result.returncode, result.stdout))
    return result.stdout


def source(path):
    text = (KIT / path).read_text()
    return re.sub(r"^import Apelin\w+\n", "", text, flags=re.M)


def prepare_harness():
    # Compile exact repository implementations, only flattening module imports
    # and Swift 6 trailing argument commas for this device's Swift 5.10 parser.
    document = source("ApelinProject/Project/ProjectDocument.swift")
    start = document.index("    /// Decodes a document that already passed validation.")
    end = document.index("\n}", start)
    document = document[:start] + document[end:]
    files = source("ApelinProject/Project/ApprovalDigests.swift").split("/// The two descriptions Confirm mode")[0]
    pipeline = (KIT / "ApelinBuild/Pipeline/BuildPipeline.swift").read_text()
    target = pipeline[pipeline.index("    private func targetFlags("):pipeline.index("    // MARK: Swift modules")]
    methods = pipeline[pipeline.index("    // MARK: Swift modules"):pipeline.index("    /// An arm64e slice linked")]
    harness = (REPO / "Tests/MixedBuildDevice/Harness.swift").read_text()
    harness = harness.replace("    // INSERT_PIPELINE_METHODS", target + methods)
    text = "\n".join([
        source("ApelinCore/CanonicalPath.swift"), document,
        source("ApelinProject/Project/SourceLanguage.swift"), files,
        source("ApelinProject/Project/ProjectGlob.swift"),
        source("ApelinBuild/Process/ToolRunner.swift"),
        source("ApelinBuild/Pipeline/ProductSourcePlan.swift"), harness,
    ])
    text = re.sub(r",(\s*[)\]])", r"\1", text)
    write("Harness.swift", text)
    run(["swiftc", "-target", "arm64-apple-ios16.0", "-parse-as-library",
         "-nonlib-dependency-scanner", "-module-cache-path", ".build/mixed-device/cache",
         ".build/mixed-device/Harness.swift", "-o", ".build/mixed-device/check"])
    run(["ldid", "-S" + ENTITLEMENTS, ".build/mixed-device/check"])


def project(sources, bridge=None, standard=None, extra=False):
    product = {"id": "tool", "type": "executable", "name": "Mixed", "sources": sources,
               "objcARC": True, "frameworks": ["Foundation"], "headerSearchPaths": ["Include Space"]}
    if bridge:
        product["bridgingHeader"] = bridge
    if standard:
        product["cxxStandard"] = standard
    if extra:
        product.update(librarySearchPaths=["Vendor Lib"], libraries=["extra"],
                       frameworkSearchPaths=["Framework Space"], weakFrameworks=["UIKit"])
    config = {"optimization": "0", "debugInfo": True, "defines": {"SHARED_VALUE": "5"},
              "cxxFlags": ["-DCXX_ONLY=1"], "cFlags": ["-Werror"]}
    return {"schemaVersion": 1, "projectID": "00000000-0000-0000-0000-000000000001",
            "kind": "cli", "language": "c",  # Deliberately NOT swift.
            "template": {"extensionID": "test", "templateID": "test", "version": "1", "digest": "test"},
            "environment": {"toolchain": {"id": "test", "digest": "test"}, "sdk": {"id": "test", "digest": "test"}},
            "deploymentTarget": "16.0", "architectures": {"rootless": ["arm64"], "roothide": ["arm64e"]},
            "configurations": {"Debug": config, "Release": config}, "products": [product], "build": {"steps": []},
            "package": {"id": "test.mixed", "name": "test", "version": "1", "description": "test",
                        "author": "test", "section": "Development", "layout": []}}


def fixtures():
    shared_header = '''#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int c_value(void);
int cpp_value(void);
int objc_value(void);
int objcpp_value(void);
int extra_value(void);
#ifdef __cplusplus
}
#endif
'''
    cases = {}
    cases["mixed"] = ({
        "Include Space/Bridge.h": '#include "API.h"\n#if SHARED_VALUE != 5\n#error importer lost defines\n#endif\n',
        "Include Space/API.h": shared_header,
        "Sources/main.swift": '''import Foundation
let values = [c_value(), cpp_value(), objc_value(), objcpp_value(), extra_value()]
precondition(values == [5, 14, 8, 21, 9], "wrong mixed ABI result: \\(values)")
print("PASS mixed: \\(values)")
''',
        "Sources/Logic.swift": '''import Foundation
@objc public class SwiftValue: NSObject {
    @objc public static func answer() -> Int32 { 8 }
}
''',
        "Sources/core.c": '''#include "API.h"
#ifdef CXX_ONLY
#error C++ flags leaked into C
#endif
int c_value(void) { return SHARED_VALUE; }
''',
        "Sources/core.cpp": '''#include "API.h"
#include <vector>
#include <numeric>
#ifndef CXX_ONLY
#error C++ flags missing
#endif
static_assert(__cplusplus >= 202002L);
int cpp_value(void) { std::vector<int> v{1,4,9}; return std::accumulate(v.begin(),v.end(),0); }
''',
        "Sources/core.m": '''#import <Foundation/Foundation.h>
#import "API.h"
#import "Mixed-Swift.h"
#ifdef CXX_ONLY
#error C++ flags leaked into Objective-C
#endif
int objc_value(void) { return [SwiftValue answer]; }
''',
        "Sources/core.mm": '''#import <Foundation/Foundation.h>
#import "API.h"
#include <vector>
#ifndef CXX_ONLY
#error ObjC++ flags missing
#endif
static_assert(__cplusplus >= 202002L);
int objcpp_value(void) { std::vector<int> v{7,14}; return v[0]+v[1]; }
''',
        "Extra.c": "int extra_value(void) { return 9; }\n",
    }, project(["Sources/*.swift", "Sources/*.c", "Sources/*.cpp", "Sources/*.m", "Sources/*.mm"],
               "Include Space/Bridge.h", "c++20", extra=True))
    cases["native-main"] = ({
        "Sources/entry.m": '''#import <Foundation/Foundation.h>
#import "Mixed-Swift.h"
int main(void) { @autoreleasepool { if ([SwiftValue answer] != 8) return 1; puts("PASS native-main"); } return 0; }
''', "Sources/Logic.swift": cases["mixed"][0]["Sources/Logic.swift"],
    }, project(["Sources/*.m", "Sources/*.swift"]))
    cases["swift-main"] = ({
        "Include Space/Bridge.h": "int c_value(void);\n",
        "Sources/Entry.swift": '''@main struct Entry { static func main() { precondition(c_value() == 5); print("PASS swift-main") } }
''', "Sources/core.c": "int c_value(void) { return 5; }\n",
    }, project(["Sources/*.swift", "Sources/*.c"], "Include Space/Bridge.h"))
    cases["cpp-only"] = ({
        "Sources/main.cpp": '''#include <vector>
#include <cstdio>
static_assert(__cplusplus >= 202002L);
#ifndef CXX_ONLY
#error C++ flags missing
#endif
int main() { std::vector<int> v{3,4}; if(v[0]+v[1]!=7) return 1; puts("PASS cpp-only"); }
''',
    }, project(["Sources/*.cpp"], standard="c++20"))
    cases["pure-c"] = ({
        "Sources/main.c": '#include <stdio.h>\nint main(void) { puts("PASS pure-c"); return 0; }\n',
    }, project(["Sources/*.c"]))
    cases["pure-swift"] = ({"Sources/main.swift": 'print("PASS pure-swift")\n'}, project(["Sources/*.swift"]))
    cases["object-collision"] = ({
        "Sources/a/b.c": "int first(void) { return 3; }\n",
        "Sources/a__b.c": "int second(void) { return 4; }\n",
        "Sources/main.c": '#include <stdio.h>\nint first(void); int second(void);\nint main(void) { if(first()+second()!=7) return 1; puts("PASS object-collision"); return 0; }\n',
    }, project(["Sources/**/*.c"]))
    for name, (files, manifest) in cases.items():
        for path, contents in files.items():
            write(name + "/" + path, contents)
        for directory in ["Include Space", "Vendor Lib", "Framework Space"]:
            (OUT / name / directory).mkdir(parents=True, exist_ok=True)
        write(name + "/project.json", json.dumps(manifest, indent=2))
    return cases


def main():
    for key in ["APELIN_PROJECT_ROOT", "APELIN_TOOLCHAIN_BIN", "SDKROOT"]:
        if not os.environ.get(key):
            raise SystemExit("missing environment: " + key)
    OUT.mkdir(parents=True, exist_ok=True)
    prepare_harness()
    cases = fixtures()
    count = 0
    for name in cases:
        for bootstrap, arch in [("rootless", "arm64"), ("roothide", "arm64e")]:
            directory = OUT / name
            if name == "mixed":
                run(["clang", "-target", arch + "-apple-ios16.0", "-c", "Extra.c", "-o", "Vendor Lib/extra.o"], cwd=directory)
                run(["libtool", "-static", "-o", "Vendor Lib/libextra.a", "Vendor Lib/extra.o"], cwd=directory)
            relative = ".build/mixed-device/" + name
            log = run([str(OUT / "check"), relative, bootstrap])
            write(name + "/" + bootstrap + ".log", log)
            binary = relative + "/out-" + bootstrap + "/link/tool/" + arch + "/Mixed"
            run(["ldid", "-S" + ENTITLEMENTS, binary])
            result = run([str(REPO / binary)])
            if "PASS " + name not in result:
                raise AssertionError(result)
            print(bootstrap + "/" + arch + ": " + result.strip(), flush=True)
            count += 1
    print("PASS: {} compile/link/runtime cases; packaging and host integration not exercised".format(count))


if __name__ == "__main__":
    main()

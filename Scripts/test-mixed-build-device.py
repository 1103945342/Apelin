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
        source("ApelinProject/Project/SourceLanguage.swift"),
        source("ApelinProject/Project/CXXInteropSettings.swift"), files,
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
    # No extern "C", @_silgen_name or ObjC wrapper: Swift constructs a C++
    # class and calls its out-of-line method. Its module map is project input.
    cpp_header = '''#pragma once
    #if SHARED_VALUE != 5 || !defined(CXX_ONLY) || BASE_FLAG != 7
    #error C++ importer lost the native preprocessor settings
    #endif
    static_assert(__cplusplus >= 201703L);
    class Counter {
        int value;
    public:
        Counter(int v): value(v) {}
        int add(int x) const;
        int heapValue() const { int *p = new int(value); int n = *p; delete p; return n; }
    };
    '''
    cpp_module = 'module CxxCounter { requires cplusplus header "Counter.hpp" export * }\n'
    cpp_files = {
        "Include Space/module.modulemap": cpp_module,
        "Include Space/Counter.hpp": cpp_header,
        "Sources/Counter.cpp": '#include "Counter.hpp"\nint Counter::add(int x) const { return value + x; }\n',
        "Sources/main.swift": '''import CxxCounter
let counter = Counter(40)
precondition(counter.add(2) == 42)
precondition(counter.heapValue() == 40)
print("PASS cxx-direct")
''',
    }
    manifest = project(["Sources/*.swift", "Sources/*.cpp"])
    manifest["products"][0]["cxxInterop"] = True
    cases["cxx-direct"] = (cpp_files, manifest)

    # C declarations reach Swift through a module map, not a bridging header:
    # Swift's importer drops the bridging header while C++ interop is on.
    manifest = project(["Sources/*.swift", "Sources/*.cpp", "Sources/*.c"])
    manifest["products"][0]["cxxInterop"] = True
    cases["cxx-c-module"] = ({
        "Include Space/module.modulemap": ('module CAPI [extern_c] { header "API.h" export * }\n'
                                           'module CxxCounter { requires cplusplus header "Counter.hpp" export * }\n'),
        "Include Space/API.h": '#pragma once\nint c_value(void);\n',
        "Include Space/Counter.hpp": cpp_header,
        "Sources/Counter.cpp": cpp_files["Sources/Counter.cpp"],
        "Sources/core.c": '#include "API.h"\nint c_value(void) { return SHARED_VALUE; }\n',
        "Sources/main.swift": '''import CAPI
import CxxCounter
precondition(c_value() == 5)
precondition(Counter(40).add(c_value()) == 45)
print("PASS cxx-c-module")
''',
    }, manifest)

    manifest = project(["Sources/*.swift"])
    manifest["products"][0]["cxxInterop"] = True
    cases["cxx-header-only"] = ({
        "Include Space/module.modulemap": cpp_module,
        "Include Space/Counter.hpp": cpp_header,
        "Sources/main.swift": '''import CxxCounter
precondition(Counter(42).heapValue() == 42)
print("PASS cxx-header-only")
''',
    }, manifest)

    manifest = project(["Sources/*.swift", "Sources/*.cpp"])
    # The product deliberately has neither cxxInterop nor a header path:
    # both come from Leaf through Middle, as does the C++20 standard.
    manifest["products"][0].pop("headerSearchPaths")
    manifest["products"][0]["swiftModules"] = ["Middle"]
    manifest["swiftModules"] = [
        {"name": "Leaf", "sources": ["Modules/Leaf.swift"], "cxxInterop": True,
         "headerSearchPaths": ["Include Space"], "cxxStandard": "c++20"},
        {"name": "Middle", "sources": ["Modules/Middle.swift"], "dependencies": ["Leaf"]},
    ]
    cases["cxx-module-chain"] = ({
        "Include Space/module.modulemap": cpp_module,
        "Include Space/Counter.hpp": cpp_header.replace("201703L", "202002L"),
        "Sources/Counter.cpp": cpp_files["Sources/Counter.cpp"],
        "Modules/Leaf.swift": 'import CxxCounter\npublic func makeCounter() -> Counter { Counter(40) }\n',
        "Modules/Middle.swift": 'import Leaf\npublic func answer() -> Int32 { makeCounter().add(2) }\n',
        "Sources/main.swift": 'import Middle\nprecondition(answer() == 42)\nprint("PASS cxx-module-chain")\n',
    }, manifest)

    for name, (files, manifest) in cases.items():
        if name.startswith("cxx-"):
            for config in manifest["configurations"].values():
                # Debug and Release share the same dict in this fixture.
                config["cFlags"] = ["-Werror", "-DBASE_FLAG=7"]
        for path, contents in files.items():
            write(name + "/" + path, contents)
        for directory in ["Include Space", "Vendor Lib", "Framework Space"]:
            (OUT / name / directory).mkdir(parents=True, exist_ok=True)
        write(name + "/project.json", json.dumps(manifest, indent=2))
    return cases


def check_importer_macros(name, log):
    """Clang keys its module cache on the preprocessor state, so a macro that
    changes rebuilds every imported standard library module. The importer must
    not see the identity strings (build ID, package, version) while native
    compilation still does."""
    lines = [line for line in log.splitlines() if line.startswith("$ ")]
    swift = [line for line in lines if "/swiftc " in line]
    native = [line for line in lines if "/clang " in line]
    identity = ("APELIN_BUILD_ID", "APELIN_PACKAGE_ID", "APELIN_VERSION")
    for line in swift:
        for macro in identity:
            if "-Xcc -D" + macro in line:
                raise AssertionError(name + ": the C++ importer saw " + macro + ", so its module cache "
                                     "would be rebuilt by every build\n" + line)
    if native:
        for macro in identity:
            if not any("-D" + macro + "=" in line for line in native):
                raise AssertionError(name + ": native compilation lost " + macro + "\n" + "\n".join(native[:2]))


def refusals():
    """Builds the pipeline must turn down: one fixture per refusal, with the
    phrase its message has to carry."""
    manifest = project(["Sources/*.swift", "Sources/*.cpp"], bridge="Include Space/Bridge.h")
    manifest["products"][0]["cxxInterop"] = True
    return {
        "refuse-bridge-and-interop": ({
            "Include Space/module.modulemap": 'module CxxCounter { requires cplusplus header "Counter.hpp" export * }\n',
            "Include Space/Counter.hpp": '#pragma once\nclass Counter { public: int v; Counter(int x): v(x) {} int add(int x) const; };\n',
            "Include Space/Bridge.h": "int c_value(void);\n",
            "Sources/Counter.cpp": '#include "Counter.hpp"\nint Counter::add(int x) const { return v + x; }\n',
            "Sources/main.swift": "import CxxCounter\nlet counter = Counter(1)\nprint(counter.add(2))\n",
        }, manifest, "bridgingHeader cannot be combined with C++ interop"),
    }


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
            if name.startswith("cxx-"):
                check_importer_macros(name, log)
            binary = relative + "/out-" + bootstrap + "/link/tool/" + arch + "/Mixed"
            run(["ldid", "-S" + ENTITLEMENTS, binary])
            result = run([str(REPO / binary)])
            if "PASS " + name not in result:
                raise AssertionError(result)
            print(bootstrap + "/" + arch + ": " + result.strip(), flush=True)
            count += 1
    refused = 0
    for name, (files, manifest, expected) in refusals().items():
        for path, contents in files.items():
            write(name + "/" + path, contents)
        (OUT / name / "Include Space").mkdir(parents=True, exist_ok=True)
        write(name + "/project.json", json.dumps(manifest, indent=2))
        result = subprocess.run(
            [str(OUT / "check"), ".build/mixed-device/" + name, "rootless"],
            cwd=REPO, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        write(name + "/rootless.log", result.stdout)
        if result.returncode == 0:
            raise AssertionError(name + ": the build was accepted\n" + result.stdout)
        if expected not in result.stdout:
            raise AssertionError(name + ": refused for another reason\n" + result.stdout)
        print("refused: " + name, flush=True)
        refused += 1
    print("PASS: {} compile/link/runtime cases and {} refusals; packaging and host integration not exercised"
          .format(count, refused))


if __name__ == "__main__":
    main()

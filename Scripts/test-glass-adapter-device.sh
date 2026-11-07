#!/bin/sh
# No installation, window or screen access. Run from the prepared device shell.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/GlassAdapter

swiftc -parse-as-library -swift-version 5 -target arm64-apple-ios16.0 \
    Apelin/Interface/Root/GlassSurfaceStyle.swift \
    Tests/GlassAdapter/PolicyChecks.swift \
    -o build/GlassAdapter/policy-checks
ldid -STests/GlassAdapter/Tool.entitlements build/GlassAdapter/policy-checks
./build/GlassAdapter/policy-checks

# Module-only stand-in: it is never linked into or run as the real library.
swiftc -emit-module -swift-version 5 -target arm64-apple-ios16.0 \
    -D APELIN_GLASS_ADAPTER_TESTS -module-name LiquidGlassKit \
    Tests/GlassAdapter/LiquidGlassKitAPIStub.swift \
    -emit-module-path build/GlassAdapter/LiquidGlassKit.swiftmodule
swiftc -typecheck -swift-version 5 -strict-concurrency=complete \
    -target arm64-apple-ios16.0 -D APELIN_GLASS_ADAPTER_TESTS \
    -I build/GlassAdapter \
    Tests/GlassAdapter/LegacySDKStub.swift \
    Apelin/Interface/Root/GlassSurfaceStyle.swift \
    Apelin/Interface/Root/GlassSurfaceView.swift
printf '%s\n' 'PASS: adapter typecheck against API/SDK stubs, NOT a LiquidGlassKit or app build'

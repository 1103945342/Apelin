#!/bin/bash
# The session host's macOS-runnable tests (Tests/SessionHost/main.swift),
# compiled with the Apelind sources they exercise against the ApelinCore and
# ApelinProtocol that `swift build` left in <modules>. Run by `make harness`.
#
# usage: test-session-host.sh <modules-dir> [<apelin-environment-harness>]
#        test-session-host.sh --device [<tool.entitlements>]
#
# With the second argument (built by `swift build --product
# apelin-environment-harness` in the same scratch path), the toolchain setup
# runs end to end: the real environment worker in its own process against
# this host's install bridge and a fake irisind.
#
# `--device` runs the half that needs no xcrun and no macOS: the report outbox
# (Apelind/Session/Agent/AgentReportOutbox.swift) against the two protocol
# files it reads, on the device's own toolchain.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"

if [[ "${1:-}" == --device ]]; then
    shift
    entitlements="${1:-build/Tool.entitlements}"
    [[ -f "$entitlements" ]] || { echo "error: no such entitlements file: $entitlements" >&2; exit 64; }
    # Written through the relative path and handed over by its real one, as
    # Scripts/test-file-browser.sh does: the bootstrap's shell and the program
    # it runs do not see a path the same way.
    mkdir -p build
    work="$(mktemp -d build/report-checks.XXXXXX)"
    trap 'rm -rf -- "${work:?}"' EXIT
    mkdir -p "$work/tmp"
    export TMPDIR="${APELIN_PROJECT_ROOT:-$root}/$work/tmp"

    # The two files are the device toolchain's: it predates trailing commas in
    # calls, so the copies it reads are the repository's with those removed.
    python3 - "$work" \
        Packages/ApelinKit/Sources/ApelinCore/JSON.swift \
        Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentTurnReport.swift <<'PYTHON'
import re, sys
work = sys.argv[1]
for source in sys.argv[2:]:
    text = open(source).read()
    text = re.sub(r",(\s*)\)", r"\1)", text)
    text = re.sub(r",(\s*)\]", r"\1]", text)
    open(work + "/" + source.rsplit("/", 1)[-1], "w").write(text)
PYTHON
    core="$work/JSON.swift"
    report="$work/AgentTurnReport.swift"
    # The two modules the outbox reads, each built from the one file it needs,
    # as Scripts/test-file-browser.sh builds ApelinCore for CanonicalPath.
    swiftc -swift-version 5 -target arm64-apple-ios16.0 -parse-as-library -module-name ApelinCore \
        -emit-module -emit-module-path "$work/ApelinCore.swiftmodule" "$core"
    swiftc -swift-version 5 -target arm64-apple-ios16.0 -parse-as-library -module-name ApelinCore \
        -c -o "$work/ApelinCore.o" "$core"
    swiftc -swift-version 5 -target arm64-apple-ios16.0 -parse-as-library -module-name ApelinProtocol \
        -emit-module -emit-module-path "$work/ApelinProtocol.swiftmodule" "$report"
    swiftc -swift-version 5 -target arm64-apple-ios16.0 -parse-as-library -module-name ApelinProtocol \
        -c -o "$work/ApelinProtocol.o" "$report"

    cat > "$work/main.swift" <<'SWIFT'
import Darwin
import Foundation

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(what) (line \(line))")
    }
}

let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("apelin-report-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
await agentReportChecks(scratch: scratch)
try? FileManager.default.removeItem(at: scratch)
print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
SWIFT

    swiftc -swift-version 5 -target arm64-apple-ios16.0 -I "$work" \
        Apelind/Session/Agent/AgentReportOutbox.swift \
        Tests/SessionHost/AgentReportChecks.swift \
        "$work/main.swift" \
        "$work/ApelinCore.o" "$work/ApelinProtocol.o" \
        -o "$work/report-checks"
    ldid "-S$entitlements" "$work/report-checks"
    "$work/report-checks"
    exit $?
fi

modules="$1"
harness="${2:-}"
work="$(mktemp -d /private/tmp/apelin-session-host.XXXXXX)"
trap 'rm -rf -- "${work:?}"' EXIT

sources=(
    "$root/Apelind/System.swift"
    "$root/Apelind/Spawn.swift"
    "$root/Apelind/Session/CallerPolicy.swift"
    "$root/Apelind/Session/TaskRegistry.swift"
    "$root/Apelind/Session/TaskResume.swift"
    "$root/Apelind/Session/Approval/ApprovalLedger.swift"
    "$root/Apelind/Session/Install/ArtifactRegistry.swift"
    "$root/Apelind/Session/Install/DebControlPeek.swift"
    "$root/Apelind/Session/Install/InstallBridge.swift"
    "$root/Apelind/Session/Install/InstallConflicts.swift"
    "$root/Apelind/Session/Install/AppBundle.swift"
    "$root/Apelind/Session/Install/AppPlacement.swift"
    "$root/Apelind/Session/Install/ApplicationInstall.swift"
    "$root/Apelind/Session/Install/ApplicationCensus.swift"
    "$root/Apelind/Session/Install/ZipExtractor.swift"
    "$root/Apelind/Session/Install/InstallService.swift"
    "$root/Apelind/Session/Install/InstallationStore.swift"
    "$root/Apelind/Session/Install/ManagedPackagePolicy.swift"
    "$root/Apelind/Session/Install/ToolchainTreePruner.swift"
    "$root/Apelind/Session/Files/AtomicReplace.swift"
    "$root/Apelind/Session/Files/FileScopes.swift"
    "$root/Apelind/Session/Files/ProtectedEditPolicy.swift"
    "$root/Apelind/Session/Files/ProtectedEditor.swift"
    "$root/Apelind/Session/Terminal/TerminalSession.swift"
    "$root/Apelind/Session/Terminal/TerminalHost.swift"
    "$root/Apelind/Session/ToolHost/AttachmentCopies.swift"
    "$root/Apelind/Session/Agent/AgentProjects.swift"
    "$root/Apelind/Session/Agent/AgentRunCode.swift"
    "$root/Apelind/Session/Agent/AgentRunCodePresets.swift"
    "$root/Apelind/Session/Agent/AgentApprovals.swift"
    "$root/Apelind/Session/Agent/AgentOpenTurns.swift"
    "$root/Apelind/Session/Agent/AgentHostRun.swift"
    "$root/Apelind/Session/Agent/AgentConversationRules.swift"
    "$root/Apelind/Session/Agent/AgentReportOutbox.swift"
    "$root/Apelind/Session/Agent/AgentConversationList.swift"
    "$root/Apelind/Session/Agent/AgentEnvironmentRules.swift"
    "$root/Apelind/Session/Agent/AgentExternalBuildRules.swift"
    "$root/Apelind/Session/Agent/AgentProjectRenameRules.swift"
    "$root/Apelind/Session/Agent/AgentProjectDeleteRules.swift"
    "$root/Apelind/Session/Agent/AgentUIActionRules.swift"
    "$root/Apelind/Session/Agent/AgentScreenRules.swift"
    "$root/Apelind/Session/Agent/AgentFeedbackRules.swift"
    "$root/Apelind/Session/Agent/AgentRepositoryCreateRules.swift"
    "$root/Apelind/Session/Agent/AgentIssueCreateRules.swift"
    "$root/Apelind/Session/Agent/AgentForcePushRules.swift"
    "$root/Apelind/Session/Agent/AgentSquashRules.swift"
    "$root/Apelind/Session/Agent/AgentGitBranchRules.swift"
    "$root/Apelind/Session/Agent/AgentResetToRemoteRules.swift"
    "$root/Apelind/Session/Agent/AgentPublishRules.swift"
    "$root/Apelind/Session/Notice/AgentNotices.swift"
    "$root/Apelind/Session/Patience.swift"
    "$root/Tests/SessionHost/AgentNoticeChecks.swift"
    "$root/Tests/SessionHost/AgentOpenChecks.swift"
    "$root/Tests/SessionHost/AgentHostRunChecks.swift"
    "$root/Tests/SessionHost/PatienceChecks.swift"
    "$root/Tests/SessionHost/RootRunChecks.swift"
    "$root/Tests/SessionHost/ScreenConsentChecks.swift"
    "$root/Tests/SessionHost/ResetToRemoteChecks.swift"
    "$root/Tests/SessionHost/GitBranchChecks.swift"
    "$root/Tests/SessionHost/AppPlacementChecks.swift"
    "$root/Tests/SessionHost/ToolchainEndToEnd.swift"
    "$root/Tests/SessionHost/ToolchainPruneChecks.swift"
    "$root/Tests/SessionHost/TerminalChecks.swift"
    "$root/Tests/SessionHost/main.swift"
)

# The objects: one per module (the new build system) or one per source file.
objects=()
for module in ApelinCore ApelinProtocol; do
    if [[ -f "$modules/$module.o" ]]; then
        objects+=("$modules/$module.o")
    else
        while IFS= read -r object; do objects+=("$object"); done < <(find "$modules/.." "$modules" -maxdepth 2 -path "*/$module.build/*.o" | sort -u)
    fi
done
[[ ${#objects[@]} -ge 2 ]] || { echo "error: no ApelinCore/ApelinProtocol objects near $modules" >&2; exit 1; }

xcrun --sdk macosx swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -I "$root/Shared/XPCShim" -I "$modules" \
    "${objects[@]}" "${sources[@]}" -o "$work/session-host"
APELIN_REPOSITORY="$root" APELIN_ENVIRONMENT_HARNESS="$harness" "$work/session-host"

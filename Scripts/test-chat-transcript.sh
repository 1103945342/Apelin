#!/bin/bash
# Compile the app's event-to-transcript reducer, how it reads past a reopened
# session's replay and takes from it the approvals its stopped task left,
# how it adopts the conversations agents open, how far it
# follows a turn, how the trace sheet lists a summary's steps, how dropped
# messages go back to the composer, which conversations a deleted project
# takes with it, what a rootless app's data container gives back, which
# tool results are builds the star prompt counts and
# how often it asks, the order the sidebar lists conversations in, which
# projects the project menu lists at its top, which conversations offer
# Delete and when it asks first, which replies leave a conversation
# unread, what a forced push's, a squash's and a question's approval cards
# show, how a sign-in page says it is finished from another device, which
# typed text the Web capture takes for an address, and which version of a
# linked package the app shows, against the harness modules.
# Usage: test-chat-transcript.sh <ApelinKit modules directory>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
modules="$1"
work="$(mktemp -d -t luros-chat-transcript)"
trap 'rm -rf -- "${work:?}"' EXIT

sources=(
    "$root/Luros/Interface/Chats/ChatSummary.swift"
    "$root/Luros/Interface/Chats/ChatUnread.swift"
    "$root/Luros/Interface/Chats/Composer/ComposerDraft.swift"
    "$root/Luros/Interface/Chats/Composer/ComposerMode.swift"
    "$root/Luros/Interface/Chats/Messages/ChatMessage.swift"
    "$root/Luros/Interface/Chats/Messages/ChatFailure.swift"
    "$root/Luros/Interface/Chats/Messages/ApprovalCardText.swift"
    "$root/Luros/Interface/Chats/Messages/ToolCallBanner.swift"
    "$root/Luros/Interface/Chats/Messages/ToolCallDetail.swift"
    "$root/Luros/Interface/Chats/Messages/TraceStep.swift"
    "$root/Luros/Interface/Chats/Messages/ChatStreamPacing.swift"
    "$root/Luros/Interface/Chats/ChatTranscript.swift"
    "$root/Luros/Interface/Chats/ChatProcessPresentation.swift"
    "$root/Luros/Interface/Chats/Messages/ChatHeaderLayout.swift"
    "$root/Luros/Interface/Chats/Messages/ChatActivityLayout.swift"
    "$root/Luros/Interface/Chats/Messages/ToolCallSections.swift"
    "$root/Luros/Interface/Git/GitUntrackedGroup.swift"
    "$root/Luros/Interface/Chats/ChatTranscriptCache.swift"
    "$root/Luros/Interface/Chats/ModelSwitchFit.swift"
    "$root/Luros/Interface/Chats/ChatStore.swift"
    "$root/Luros/Interface/Chats/ChatEventsFile.swift"
    "$root/Luros/Interface/Chats/ChatFork.swift"
    "$root/Luros/Interface/Chats/ChatAdoption.swift"
    "$root/Luros/Interface/Chats/DroppedMessages.swift"
    "$root/Luros/Interface/Chats/DeletedProjects.swift"
    "$root/Luros/Application/ContainerDataFolder.swift"
    "$root/Luros/Interface/Chats/ChatDeletion.swift"
    "$root/Luros/Interface/Chats/TurnFollowing.swift"
    "$root/Luros/Interface/Root/SidebarOrder.swift"
    "$root/Luros/Interface/Root/SidebarTree.swift"
    "$root/Luros/Interface/Root/ProjectMenuOrder.swift"
    "$root/Luros/Interface/Root/ChatRowAction.swift"
    "$root/Luros/Interface/Feedback/CompletedBuilds.swift"
    "$root/Luros/Interface/Feedback/StarPromptState.swift"
    "$root/Luros/Interface/Settings/Accounts/SignInProgress.swift"
    "$root/Luros/Interface/Chats/Composer/WebAddress.swift"
    "$root/Luros/Interface/Settings/LinkedPackage.swift"
    "$root/Tests/ChatTranscript/TranscriptFold.swift"
    "$root/Tests/ChatTranscript/ToolCallDetailCheck.swift"
    "$root/Tests/ChatTranscript/TraceStepCheck.swift"
    "$root/Tests/ChatTranscript/ProcessPresentationCheck.swift"
    "$root/Tests/ChatTranscript/StreamPresentationCheck.swift"
    "$root/Tests/ChatTranscript/PendingQueueCheck.swift"
    "$root/Tests/ChatTranscript/ToolCallSectionsCheck.swift"
    "$root/Tests/ChatTranscript/GitUntrackedGroupCheck.swift"
    "$root/Tests/ChatTranscript/ReplayEndCheck.swift"
    "$root/Tests/ChatTranscript/AbandonedApprovalCheck.swift"
    "$root/Tests/ChatTranscript/DroppedMessagesCheck.swift"
    "$root/Tests/ChatTranscript/DeletedProjectsCheck.swift"
    "$root/Tests/ChatTranscript/ContainerDataFolderCheck.swift"
    "$root/Tests/ChatTranscript/CompletedBuildsCheck.swift"
    "$root/Tests/ChatTranscript/StarPromptStateCheck.swift"
    "$root/Tests/ChatTranscript/SidebarOrderCheck.swift"
    "$root/Tests/ChatTranscript/SidebarTreeCheck.swift"
    "$root/Tests/ChatTranscript/ChatLineageCheck.swift"
    "$root/Tests/ChatTranscript/ProjectMenuOrderCheck.swift"
    "$root/Tests/ChatTranscript/ChatDeletionCheck.swift"
    "$root/Tests/ChatTranscript/ChatUnreadCheck.swift"
    "$root/Tests/ChatTranscript/ChatForkCheck.swift"
    "$root/Tests/ChatTranscript/ConversationSourceCheck.swift"
    "$root/Tests/ChatTranscript/CooperationTurnCheck.swift"
    "$root/Tests/ChatTranscript/StreamPacingCheck.swift"
    "$root/Tests/ChatTranscript/ForcePushCardCheck.swift"
    "$root/Tests/ChatTranscript/SquashCardCheck.swift"
    "$root/Tests/ChatTranscript/QuestionCardCheck.swift"
    "$root/Tests/ChatTranscript/SignInElsewhereCheck.swift"
    "$root/Tests/ChatTranscript/ModelSwitchFitCheck.swift"
    "$root/Tests/ChatTranscript/WebAddressCheck.swift"
    "$root/Tests/ChatTranscript/LinkedPackageCheck.swift"
    "$root/Tests/ChatTranscript/main.swift"
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
    "${objects[@]}" "${sources[@]}" -o "$work/chat-transcript"
"$work/chat-transcript"

# The model picker shares its first read with the automatic selection check.
# This harness needs Foundation alone and also runs on-device with swiftc.
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
    "$root/Luros/Service/SharedModelLoad.swift" \
    "$root/Tests/ModelPicker/SharedModelLoadCheck.swift" -o "$work/model-picker"
"$work/model-picker"

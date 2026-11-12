import AlertController
import ApelinProtocol
import SPIndicator
import UIKit

/// The chat page's `…` menu: Rename… and Compact… for the conversation,
/// then its project's actions (`ProjectActions`). General Chat has no
/// project, so after them come Open in iGhostVT and Open in Fila for the
/// conversation's own working folder, `Temporary/<conversation>/`. Last,
/// in a group of its own, Delete Conversation…, which `onDelete` asks
/// about and carries out as the sidebar's Delete does (`ChatDeletion`).
@MainActor
enum ChatActions {
    static func menu(
        for chat: ChatSummary,
        runtime: ChatRuntime,
        from presenter: UIViewController,
        anchor: UIBarButtonItem,
        onPrepareDistribution: @escaping (String) -> Void,
        onDelete: @escaping (UUID) -> Void,
        completion: @escaping ([UIMenuElement]) -> Void,
    ) {
        let chatActions = [
            renameAction(for: chat.id, runtime: runtime, from: presenter),
            compactAction(for: chat.id, runtime: runtime, from: presenter),
        ]
        let deletion = UIMenu(options: .displayInline, children: [deleteAction(for: chat.id, onDelete: onDelete)])
        guard let projectName = chat.projectName else {
            let folders = ProjectActions.folderActions(from: presenter, failureTitle: "Unable to Open Folder") {
                try ProjectActions.temporaryDirectory(of: chat.id)
            }
            completion([
                UIMenu(options: .displayInline, children: chatActions),
                UIMenu(options: .displayInline, children: folders),
                deletion,
            ])
            return
        }
        // Distribute… is read off the project's own manifest each time: one
        // with no build description or script has nothing to package
        Task { [weak presenter, weak anchor] in
            let project = try? await ProjectSummary.load().first { $0.name == projectName }
            guard let presenter, let anchor else {
                completion([])
                return
            }
            let projectActions = ProjectActions.menu(
                projectName: projectName,
                from: presenter,
                anchor: anchor,
                distributionBlocker: (project?.buildMethod ?? .missingDescription).shortBlocker,
                chatActions: chatActions,
                onPrepareDistribution: onPrepareDistribution,
            )
            completion(projectActions.children + [deletion])
        }
    }

    /// Asked about first, whatever state the conversation is in when it is
    /// picked: one still working is stopped before it goes.
    private static func deleteAction(for id: UUID, onDelete: @escaping (UUID) -> Void) -> UIKit.UIAction {
        UIKit.UIAction(
            title: String(localized: "Delete Conversation…"),
            image: UIImage(systemName: "trash"),
            attributes: .destructive,
        ) { _ in onDelete(id) }
    }

    /// The conversation's name, typed into the alert Rename Project… uses.
    /// It is kept for good: the agent's titles no longer replace it
    /// (`ChatRuntime.rename`).
    static func renameAction(
        for id: UUID,
        runtime: ChatRuntime,
        from presenter: UIViewController,
    ) -> UIKit.UIAction {
        UIKit.UIAction(
            title: String(localized: "Rename…"),
            image: UIImage(systemName: "character.cursor.ibeam"),
            attributes: inheritsParentTitle(id, runtime: runtime) ? .disabled : [],
        ) { [weak presenter, weak runtime] _ in
            guard let presenter, let runtime, let chat = runtime.summary(id) else { return }
            presenter.present(AlertInputViewController(
                title: "Rename Chat",
                message: "Choose a name for this chat. Your agent will no longer rename it.",
                placeholder: "Chat Name",
                text: chat.displayTitle,
                doneButtonText: "Rename",
                onConfirm: { [weak runtime] name in runtime?.rename(id, to: name) },
            ), animated: true)
        }
    }

    private static func inheritsParentTitle(_ id: UUID, runtime: ChatRuntime) -> Bool {
        guard let chat = runtime.summary(id), chat.relationship == .branch,
              let parentID = chat.parentChatID, let parent = runtime.summary(parentID)
        else { return false }
        return parent.projectName == chat.projectName
    }

    /// The agent reads a summary of the earlier messages from then on; the
    /// chat still shows them all. Only between runs (`ChatRuntime.canCompact`).
    private static func compactAction(
        for id: UUID,
        runtime: ChatRuntime,
        from presenter: UIViewController,
    ) -> UIKit.UIAction {
        UIKit.UIAction(
            title: String(localized: "Compact Context…"),
            image: UIImage(systemName: "doc.text"),
            attributes: runtime.canCompact(id) ? [] : .disabled,
        ) { [weak presenter, weak runtime] _ in
            guard let presenter, let runtime else { return }
            askToCompact(for: id, runtime: runtime, from: presenter)
        }
    }

    /// The same ask, from the context ring beside the composer: what the
    /// menu's Compact Context… puts up, offered where the figure is.
    static func askToCompact(for id: UUID, runtime: ChatRuntime, from presenter: UIViewController) {
        presenter.presentConfirmation(
            title: "Compact Context?",
            message: """
            Your agent will continue from a summary of the earlier messages, which frees room for new work. \
            The messages stay in this chat.
            """,
            confirmTitle: "Compact Context",
        ) { [weak presenter, weak runtime] in
            guard let presenter, let runtime else { return }
            Task { await compact(id, runtime: runtime, from: presenter) }
        }
    }

    private static func compact(_ id: UUID, runtime: ChatRuntime, from presenter: UIViewController) async {
        let result: AgentCompactionResult
        do {
            result = try await ProgressCard.run(
                title: String(localized: "Compacting Chat"),
                message: String(localized: "Summarizing the earlier messages…"),
                cancellable: true,
                from: presenter,
            ) { _ in try await runtime.compact(id) }
        } catch is CancellationError {
            return
        } catch {
            ConversationJournal.compactFailed(error, session: runtime.records[id]?.sessionID)
            presenter.presentNotice(title: "Unable to Compact Chat", message: error.readableMessage)
            return
        }
        switch result.outcome {
        case .compacted:
            SPIndicator.present(title: String(localized: "Compacted"), preset: .done, haptic: .success)
        case .tooShort:
            presenter.presentNotice(
                title: "Nothing to Compact",
                message: "This chat is still short enough for your agent to read in full.",
            )
        case .failed:
            presenter.presentNotice(
                title: "Unable to Compact Chat",
                message: result.message ?? String(localized: "Something went wrong. Try again."),
            )
        case .cancelled:
            break
        }
    }

    // MARK: Another model

    /// The reader picked another model in the composer's row. One that holds
    /// less than the chat already takes is not switched to on the spot: the
    /// chat is compacted, with the model it is on, and only then does the pick
    /// go through. A cancel anywhere leaves the chat on the model it had.
    static func switchModel(
        to selection: ComposerModelSelection,
        named name: String,
        catalogWindow: Int?,
        for id: UUID,
        runtime: ChatRuntime,
        from presenter: UIViewController,
    ) {
        let used = runtime.transcript(id).contextUsage?.tokens
        switch ModelSwitchFit.evaluate(used: used, candidateWindow: catalogWindow) {
        case .fits, .unknown:
            apply(selection, to: id, runtime: runtime)
        case let .over(used, window):
            // Compacting runs between turns only: a reply going waits for it.
            guard runtime.canCompact(id) else {
                presenter.presentNotice(
                    title: "Not Switched Yet",
                    message: "A reply is still going. Wait for it to end, then pick this model again.",
                )
                return
            }
            presenter.presentConfirmation(
                title: "This Model Holds Less Than the Chat",
                message: """
                This chat already takes \(used.formatted()) tokens, and \(name) holds \(window.formatted()). \
                Compact the chat with the model you are on first, then switch to \(name)?
                """,
                confirmTitle: "Compact and Switch",
            ) { [weak presenter, weak runtime] in
                guard let presenter, let runtime else { return }
                Task {
                    await compactThenSwitch(
                        selection,
                        named: name,
                        fitting: window,
                        for: id,
                        runtime: runtime,
                        from: presenter,
                    )
                }
            }
        }
    }

    /// The pick goes through: kept for the chat, and told to the session, which
    /// records the total the new model reads — that record is what the ring and
    /// the panel draw. A run going takes the choice with the next prompt.
    private static func apply(
        _ selection: ComposerModelSelection,
        to id: UUID,
        runtime: ChatRuntime,
    ) {
        ComposerModelSelection.choose(selection, for: id)
        Task { await runtime.configureModel(id, selection: selection) }
    }

    private static func compactThenSwitch(
        _ selection: ComposerModelSelection,
        named name: String,
        fitting window: Int,
        for id: UUID,
        runtime: ChatRuntime,
        from presenter: UIViewController,
    ) async {
        let before = runtime.transcript(id).contextUsage?.tokens
        let result: AgentCompactionResult
        do {
            result = try await ProgressCard.run(
                title: String(localized: "Compacting Chat"),
                message: String(localized: "Summarizing the earlier messages…"),
                cancellable: true,
                from: presenter,
            ) { _ in try await runtime.compact(id) }
        } catch is CancellationError {
            return
        } catch {
            ConversationJournal.compactFailed(error, session: runtime.records[id]?.sessionID)
            presenter.presentNotice(title: "Unable to Compact Chat", message: error.readableMessage)
            return
        }
        switch result.outcome {
        case .compacted:
            break
        case .tooShort:
            presenter.presentNotice(
                title: "Not Switched",
                message: "This chat has too little to summarise, so it was not compacted, and \(name) was not switched to.",
            )
            return
        case .failed:
            presenter.presentNotice(
                title: "Unable to Compact Chat",
                message: result.message ?? String(localized: "Something went wrong. Try again."),
            )
            return
        case .cancelled:
            return
        }
        // The figure is written right after the outcome, in the same log, and
        // may arrive a moment later: a compaction can leave more than a small
        // model holds, and that is not a switch to make.
        let used = await usageAfterCompaction(in: id, runtime: runtime, differingFrom: before)
        guard let used, used <= window else {
            presenter.presentNotice(
                title: "Not Switched",
                message: "The chat was compacted, but it still takes more tokens than \(name) holds, so it was not switched to.",
            )
            return
        }
        apply(selection, to: id, runtime: runtime)
    }

    /// What the chat takes once the compaction's own record has landed.
    private static func usageAfterCompaction(
        in id: UUID,
        runtime: ChatRuntime,
        differingFrom before: Int?,
    ) async -> Int? {
        for _ in 0 ..< 40 {
            if let now = runtime.transcript(id).contextUsage?.tokens, now != before {
                return now
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return runtime.transcript(id).contextUsage?.tokens
    }
}

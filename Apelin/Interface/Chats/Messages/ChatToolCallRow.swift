import ApelinProtocol
import SnapKit
import UIKit

/// One call inside a summary's steps: a line naming it — the tool's symbol,
/// what the call is called, the reason the agent gave it — and, once the
/// reader opens it, what the call was told and what it answered
/// (`ToolCallDetail`, drawn as the trace's own page draws it). aimini's chat
/// lists a run this way: every call on one line, its instruction and its
/// result folded under it, one call at a time.
final class ChatToolCallRow: UIView {
    /// The call was folded or unfolded: the row holding this has to measure
    /// itself again.
    @objc dynamic var onToggle: (() -> Void)?
    let stepID: UUID

    private var step: ChatMessage
    private let line = UIControl()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let reasonLabel = UILabel()
    private let chevron = UIImageView()
    private let body = UIStackView()
    private var showsBody = false
    /// What this row was last given, without its strings.
    private var shownShape: ChatMessageShape?

    /// What the line and the folded sections are drawn with.
    private enum Style {
        /// The line is never shorter than a touch target's worth of room.
        static let lineHeight: CGFloat = 28
        static let iconSize: CGFloat = 15
        static let chevronSize: CGFloat = 11
        /// Between the symbol, the name, the reason and the arrow.
        static let spacing: CGFloat = 6
        /// Between the line and the sections under it.
        static let bodySpacing: CGFloat = 8
        static let sectionSpacing: CGFloat = 12
        /// The tallest a call's instruction is drawn: a command is a line or
        /// two, and a box the size of a result's would take the page.
        static let commandHeightLimit: CGFloat = 120
        /// The tallest a call's result is drawn: past it the text scrolls
        /// inside its panel, as aimini's do.
        static let blockHeightLimit: CGFloat = 180

        static var titleFont: UIFont {
            UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: .systemFont(ofSize: 14, weight: .medium),
            )
        }

        static var reasonFont: UIFont {
            UIFont.preferredFont(forTextStyle: .footnote)
        }
    }

    init(step: ChatMessage) {
        stepID = step.id
        self.step = step
        super.init(frame: .zero)

        line.isAccessibilityElement = false
        line.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        addSubview(line)

        icon.contentMode = .scaleAspectFit
        icon.tintColor = .secondaryLabel
        icon.isAccessibilityElement = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addSubview(icon)

        titleLabel.font = Style.titleFont
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addSubview(titleLabel)

        reasonLabel.font = Style.reasonFont
        reasonLabel.adjustsFontForContentSizeCategory = true
        reasonLabel.textColor = .secondaryLabel
        reasonLabel.numberOfLines = 1
        reasonLabel.lineBreakMode = .byTruncatingTail
        reasonLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.addSubview(reasonLabel)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Style.chevronSize, weight: .semibold),
        )
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.isAccessibilityElement = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addSubview(chevron)

        body.axis = .vertical
        body.spacing = Style.sectionSpacing
        body.isHidden = true
        addSubview(body)

        line.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.greaterThanOrEqualTo(Style.lineHeight)
        }
        body.snp.makeConstraints { make in
            make.top.equalTo(line.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
        icon.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
            make.size.equalTo(Style.iconSize)
        }
        chevron.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
            make.size.equalTo(Style.chevronSize + 4)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(icon.snp.trailing).offset(Style.spacing)
            make.centerY.equalToSuperview()
        }
        reasonLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel.snp.trailing).offset(Style.spacing)
            make.trailing.equalTo(chevron.snp.leading).offset(-Style.spacing)
            make.centerY.equalToSuperview()
        }

        configure(step)
        updateChevron(animated: false)
        shownShape = ChatMessageShape(step)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(step:)")
    }

    /// The same call with more of its result, or a new one: what the line
    /// says changes in place, and a call the reader opened stays open.
    func show(_ step: ChatMessage) {
        let shape = ChatMessageShape(step)
        guard shape != shownShape else { return }
        shownShape = shape
        self.step = step
        configure(step)
        updateChevron(animated: false)
    }

    /// The reader folded or unfolded this call since its step last changed:
    /// the row follows that, leaving a step that has not changed alone.
    /// Answers whether anything changed.
    @discardableResult
    func applyExpansion() -> Bool {
        guard ChatTraceExpansion.isExpanded(call: stepID) != showsBody else { return false }
        configure(step)
        updateChevron(animated: false)
        return true
    }

    private func configure(_ step: ChatMessage, animated: Bool = false) {
        icon.image = UIImage(systemName: ToolSymbol.name(for: step.tool))
            ?? UIImage(systemName: "wrench.and.screwdriver")
        titleLabel.text = step.text
        let reason = (step.banner?.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let showsReason = !reason.isEmpty && reason != step.text
        reasonLabel.text = showsReason ? reason : nil
        reasonLabel.isHidden = !showsReason
        showsBody = ChatTraceExpansion.isExpanded(call: step.id)
        rebuildBody(step)
        if animated {
            animateBody()
        }
        updateAccessibility()
    }

    /// The sections under the line: each argument by name, then the result.
    /// A call not opened has none, so it measures as its line alone.
    private func rebuildBody(_ step: ChatMessage) {
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        body.layer.removeAllAnimations()
        body.alpha = 1
        body.transform = .identity
        if showsBody {
            for section in Self.sections(of: step) {
                // aimini caps a tool's instruction and result and scrolls the
                // rest inside the panel; a command's box is much shorter than
                // a result's, which is what the reader came to read.
                body.addArrangedSubview(ToolCallSectionView(
                    section: section,
                    maximumBlockHeight: section.kind == .command
                        ? Style.commandHeightLimit
                        : Style.blockHeightLimit,
                ))
            }
        }
        body.isHidden = body.arrangedSubviews.isEmpty
        body.snp.updateConstraints { make in
            make.top.equalTo(line.snp.bottom).offset(body.isHidden ? 0 : Style.bodySpacing)
        }
    }

    /// What a call's row opens into, by the tool it is:
    ///
    /// - a file tool that writes one is shown as the diff it answered with,
    ///   under the file's own name: its arguments are the file itself, and
    ///   aimini draws a file edit as its diff and nothing else;
    /// - a file read is shown as what it read, under the file's name;
    /// - anything else shows its arguments and its result.
    ///
    /// The reason is never among them: the line above already says why the
    /// call was made, and repeating it under the line only pushes the answer
    /// down.
    private static func sections(of step: ChatMessage) -> [ToolCallDetail.Section] {
        let detail = ToolCallDetail(detail: step.detail, title: step.text)
        let file = detail.path.map { ($0 as NSString).lastPathComponent } ?? ""
        func named(_ value: String) -> ToolCallDetail.Section {
            ToolCallDetail.Section(name: file.isEmpty ? nil : file, value: value, isResult: true)
        }
        guard let tool = step.tool.flatMap(AgentToolName.canonical) else {
            return detail.sections.filter { $0.name != "reason" }
        }
        if ToolCallBanner.fileTools.contains(tool) {
            // "Patched Tweak.x (1 replacement, +3 -1)", then the diff.
            guard let result = detail.result, let diff = afterFirstLine(result) else { return [] }
            return [named(diff)]
        }
        if tool == .fileRead {
            guard let result = detail.result, !result.isEmpty else { return [] }
            return [named(withoutLineNumbers(result))]
        }
        return detail.sections.filter { $0.name != "reason" }
    }

    /// What a call answered past the line that counts it: a file tool's
    /// result opens with "Patched Tweak.x (1 replacement, +3 -1)" and the
    /// diff follows.
    private static func afterFirstLine(_ result: String) -> String? {
        guard let line = result.firstIndex(of: "\n") else { return nil }
        let rest = String(result[result.index(after: line)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// A file's text without the line numbers `file_read` puts in front of
    /// every line: what the reader wants of it is the file.
    private static func withoutLineNumbers(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let tab = line.firstIndex(of: "\t"), tab > line.startIndex,
                  line[..<tab].allSatisfy(\.isNumber)
            else { return String(line) }
            return String(line[tab...].dropFirst())
        }.joined(separator: "\n")
    }

    /// The sections arriving, as aimini unfolds them: they fade in and
    /// settle down into place. The list gives the row its new height in one
    /// step, so growing it here is not ours to animate.
    private func animateBody() {
        guard showsBody, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        body.alpha = 0
        body.transform = CGAffineTransform(translationX: 0, y: -6)
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.body.alpha = 1
            self.body.transform = .identity
        }
    }

    private func updateChevron(animated: Bool) {
        let turn = CGAffineTransform(rotationAngle: showsBody ? .pi / 2 : 0)
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            chevron.transform = turn
            return
        }
        UIView.animate(withDuration: 0.2) { self.chevron.transform = turn }
    }

    /// Folded, the row is one stop that opens the call; open, the row is a
    /// container so every section under it is read on its own.
    private func updateAccessibility() {
        let value = reasonLabel.isHidden ? nil : reasonLabel.text
        if showsBody {
            isAccessibilityElement = false
            line.isAccessibilityElement = true
            line.accessibilityLabel = step.text
            line.accessibilityValue = value
            line.accessibilityTraits = .button
            line.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Collapse")) { [weak self] _ in
                    self?.toggle()
                    return true
                },
            ]
        } else {
            isAccessibilityElement = true
            accessibilityLabel = step.text
            accessibilityValue = value
            accessibilityTraits = .button
            accessibilityCustomActions = nil
            line.isAccessibilityElement = false
        }
    }

    override func accessibilityActivate() -> Bool {
        guard !showsBody else { return false }
        toggle()
        return true
    }

    @objc dynamic private func toggle() {
        ChatTraceExpansion.setExpanded(call: step.id, !showsBody)
        configure(step, animated: true)
        updateChevron(animated: true)
        onToggle?()
    }
}

/// The symbol a call is drawn with, by the tool it names: one per family, so
/// a run reads as what it did rather than as a list of names, as aimini's
/// call rows do.
enum ToolSymbol {
    /// The SF Symbol a call is drawn with: a branch for the operations that
    /// move refs, and the bin for the one that deletes one.
    static func name(for tool: String?) -> String {
        guard let tool, let name = AgentToolName.canonical(tool) else { return fallback }
        return switch name {
        case .gitBranchDelete:
            "trash"
        case .gitTag:
            "tag"
        case .gitStash:
            "archivebox"
        case .gitRestore:
            "arrow.uturn.backward"
        case .gitClean:
            "trash.slash"
        case .fileRead, .fileList, .fileGrep, .fileFind, .fileShow:
            "doc.text.magnifyingglass"
        case .fileWrite, .fileEdit, .fileCreate:
            "square.and.pencil"
        case .shellRun:
            "terminal"
        case .gitStatus, .gitDiff, .gitLog, .gitCommitDetail, .gitBranches, .gitRemoteList,
             .gitStage, .gitUnstage, .gitCommit, .gitInit, .gitBranchCreate, .gitBranchCheckout,
             .gitBranchRename, .gitMerge, .gitMergeAbort, .gitFetch, .gitPull, .gitPush, .gitClone,
             .gitSquash, .gitRemoteSet, .gitRemoteRemove, .gitResetToRemote, .gitReadSettings,
             .gitSetAuthor, .gitSaveCredential, .gitRemoveCredential, .gitCreateRepository,
             .gitCreateIssue:
            "arrow.triangle.branch"
        case .projectBuild, .toolchainSelfTest:
            "hammer"
        case .packageInstall, .packageRemove, .packageList, .packagePublish, .packageConfirmLoaded:
            "shippingbox"
        case .screenCapture, .screenReadTree, .screenInteract, .deviceRespring:
            "iphone"
        case .logRead:
            "text.alignleft"
        case .crashList, .crashRead, .crashSymbolicate:
            "exclamationmark.triangle"
        case .memoryList, .memorySave, .memoryDelete:
            "externaldrive"
        case .skillList, .skillRead, .skillSave, .skillRemove:
            "book"
        case .conversationCreate, .conversationSend, .conversationList, .conversationRead,
             .conversationStop:
            "bubble.left.and.bubble.right"
        case .webSearch, .webFetch:
            "globe"
        case .todoList, .todoWrite:
            "checklist"
        case .notificationSend:
            "bell"
        case .questionAsk:
            "questionmark.bubble"
        case .runMode:
            "slider.horizontal.3"
        case .feedbackSend, .feedbackRead, .feedbackEdit:
            "exclamationmark.bubble"
        case .templateList, .projectList, .projectCreate, .projectRename, .projectDelete,
             .projectCheckDistribution, .projectSetEnvironment:
            "square.grid.2x2"
        case .toolchainList, .sdkList, .toolchainSetup, .sdkImport, .sdkAnalyzeFramework,
             .sdkReadHeader:
            "gearshape.2"
        }
    }

    /// A tool this build does not know, such as an MCP server's.
    private static let fallback = "wrench.and.screwdriver"
}

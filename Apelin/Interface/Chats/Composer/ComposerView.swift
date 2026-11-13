// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import ApelinProtocol
import Combine
import UIKit

/// The composer at the foot of a conversation: its bands stacked top to
/// bottom on one rounded ground, the whole as tall as they want. Attachments
/// sit above the text band; FlowDown's import panel expands below it. Files
/// dropped on the ground are attached (`ComposerView+Drop`).
class ComposerView: ComposerSectionView {
    required init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    let inputEditor = ComposerInputView()
    let approvalSection = ComposerApprovalSection()
    let attachmentsBar = ComposerAttachmentsBar()
    let controlPanel = ComposerControlPanel()
    let modelBar = ComposerModelBar()
    /// What the context has left, opened from the ring on the model row. It
    /// sits above the card, like the request panels, and closes on a second
    /// tap of the ring.
    let contextPanel = ComposerContextPanel()
    /// The two menus the draft opens: a leading slash names a command, an `@`
    /// names a file. Both sit above the card and never at once.
    let commandMenu = ComposerCommandMenu()
    let mentionMenu = ComposerMentionMenu()
    /// What the menus list, filled by the conversation once it knows which
    /// project it is in.
    let commands = ComposerCommandCatalog(
        actions: [CompactCommand(), UsageCommand(), InitProjectCommand()],
    )
    /// The project's file paths, relative to its root; nil until read.
    private var projectFiles: [String]?
    /// The project's folder, when this conversation has one.
    var projectRoot: URL?
    /// The messages waiting their turn, folded above the card. The session
    /// holds the queue; this only shows it.
    let queuePanel = ComposerQueuePanel()
    /// Says a rewrite happened, with the words it replaced. Above the card,
    /// where it can be reached before the next Send.
    let rewriteBar = ComposerRewriteBar()
    /// The conversation's todo list, read from the store the agent writes.
    let todoPanel = ComposerTodoPanel()
    private var currentDraft = ComposerDraft()
    private var panelHost = ComposerPanelHost()

    let shadowContainer = UIView()
    private var glassEffectView: UIVisualEffectView?
    /// Over the ground and everything on it, taking only drags; its colour
    /// shows while one is over it.
    let dropContainer = ComposerDropView()
    let dropColorView = UIView()

    lazy var sectionSubviews: [ComposerSectionView] = [
        approvalSection,
        attachmentsBar,
        inputEditor,
        modelBar,
        controlPanel,
    ]

    /// What the context panel's button asks for.
    var onCompactContext: (() -> Void)?
    /// Told when the mode pill changes, with the mode it took.
    var onModeChanged: ((ComposerMode) -> Void)?
    /// A command that the app runs itself was chosen.
    var onRunCommand: ((ComposerActionCommand, String) -> Void)?
    /// A skill was chosen: its name, and the arguments typed after the slash.
    var onRunSkill: ((AgentSkill, String) -> Void)?

    let spacing: CGFloat = 10

    weak var delegate: Delegate?
    private var submissionID: UUID?
    var fittingHeightConstraint: NSLayoutConstraint = .init()

    /// The card the bands sit on, before iOS 26's glass. At night it is a
    /// solid deep grey: a 10% grey let the conversation behind show through
    /// the text being typed into it, which made the card unreadable.
    private let handlerColor: UIColor = .init {
        switch $0.userInterfaceStyle {
        case .light:
            .white
        default:
            UIColor(white: 0.13, alpha: 1)
        }
    }

    override func initializeViews() {
        super.initializeViews()

        shadowContainer.layer.cornerRadius = 16
        shadowContainer.layer.cornerCurve = .continuous
        shadowContainer.clipsToBounds = false
        addSubview(shadowContainer)

        if #available(iOS 26, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            let effectView = UIVisualEffectView(effect: glass)
            effectView.layer.cornerRadius = shadowContainer.layer.cornerRadius
            effectView.layer.cornerCurve = .continuous
            effectView.clipsToBounds = true
            addSubview(effectView)
            glassEffectView = effectView
        }

        applyShadowStyle()
        approvalSection.horizontalAdjustment = -ChatMarkdownView.blockSpacing

        dropContainer.clipsToBounds = true
        dropContainer.layer.cornerRadius = shadowContainer.layer.cornerRadius
        dropContainer.layer.cornerCurve = .continuous
        addSubview(dropContainer)
        dropColorView.alpha = 0
        dropColorView.backgroundColor = tintColor.withAlphaComponent(0.05)
        dropContainer.addSubview(dropColorView)
        dropContainer.addInteraction(UIDropInteraction(delegate: self))
        defer { bringSubviewToFront(dropContainer) }

        for subview in sectionSubviews {
            addSubview(subview)
        }

        inputEditor.delegate = self
        controlPanel.cameraButton.actionBlock = { [weak self] in self?.delegate?.onComposerCameraTapped() }
        controlPanel.photoButton.actionBlock = { [weak self] in self?.delegate?.onComposerPhotoTapped() }
        controlPanel.fileButton.actionBlock = { [weak self] in self?.delegate?.onComposerFileTapped() }
        controlPanel.webButton.actionBlock = { [weak self] in self?.delegate?.onComposerWebTapped() }
        controlPanel.isPanelOpen.removeDuplicates().sink { [weak self] open in
            self?.inputEditor.showPanelState(open)
            self?.modelBar.setPanelOpen(open)
            self?.updateModelBarVisibility()
        }.store(in: &cancellables)
        attachmentsBar.onRemove = { [weak self] id in
            guard let self else { return }
            currentDraft.attachments.removeAll { $0.id == id }
            attachmentsBar.show(currentDraft.attachments)
            publishNewEditorStatus()
        }
        attachmentsBar.onPreview = { [weak self] item in self?.delegate?.onComposerPreviewAttachment(item) }

        addSubview(contextPanel)
        panelHost.add(contextPanel)
        panelHost.add(queuePanel)
        addSubview(queuePanel)
        panelHost.add(todoPanel)
        addSubview(todoPanel)
        panelHost.onHeightChanged = { [weak self] in
            self?.setNeedsLayout()
            self?.layoutIfNeeded()
        }
        contextPanel.onCompact = { [weak self] in self?.onCompactContext?() }
        modelBar.onContextTapped = { [weak self] in self?.toggleContextPanel() }
        modelBar.onModeChanged = { [weak self] mode in self?.onModeChanged?(mode) }
        modelBar.onAddTapped = { [weak self] in
            guard let self else { return }
            controlPanel.setPanelOpen(!controlPanel.isPanelOpen.value)
        }
        modelBar.onSendTapped = { [weak self] in self?.delegate?.onComposerSendTapped() }
        modelBar.onStopTapped = { [weak self] in self?.delegate?.onComposerStopTapped() }
        modelBar.onModelTapped = { [weak self] in self?.delegate?.onComposerModelPickerTapped() }

        addSubview(commandMenu)
        addSubview(mentionMenu)
        for menu in [commandMenu as UIView, mentionMenu] {
            menu.isHidden = true
        }
        commandMenu.onPick = { [weak self] command in self?.pick(command) }
        mentionMenu.onPick = { [weak self] path in self?.pick(path) }

        addSubview(rewriteBar)
        rewriteBar.isHidden = true

        // Last, so it sees touches that no control above it took.
        installFocusTap()

        heightPublisher
            .removeDuplicates()
            .ensureMainThread()
            .sink { [weak self] output in
                self?.updateHeightConstraint(output)
            }
            .store(in: &cancellables)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let presentingRequest = approvalSection.isPresentingRequest
        // A pending request covers these. They keep their own heights while
        // they fade, so nothing inside them is squeezed as the card changes.
        for band in [attachmentsBar, inputEditor, controlPanel] {
            band.alpha = presentingRequest ? 0 : 1
            band.isUserInteractionEnabled = !presentingRequest
            band.accessibilityElementsHidden = presentingRequest
        }

        let inputTop = place(attachmentsBar, at: spacing)
        // The panels and the two draft menus sit above the card, in the bands'
        // own column, and push it down rather than covering what is typed. That
        // is as true of the card a request turns into: it starts under them,
        // never at the top of the composer, where they would be drawn over it.
        var bandsTop = placePanel(todoPanel, at: presentingRequest ? spacing : inputTop)
        bandsTop = placePanel(queuePanel, at: bandsTop)
        if !rewriteBar.isHidden {
            let height = max(20, UIFont.preferredFont(forTextStyle: .caption1).lineHeight)
            rewriteBar.frame = CGRect(
                x: spacing,
                y: bandsTop,
                width: bounds.width - spacing * 2,
                height: height,
            )
            bandsTop = rewriteBar.frame.maxY + spacing
        }
        bandsTop = placePanel(contextPanel, at: bandsTop)
        bandsTop = placeMenu(commandMenu, at: bandsTop)
        bandsTop = placeMenu(mentionMenu, at: bandsTop)
        place(inputEditor, at: bandsTop)
        // the attachments bar, once it is here, shares the input's ground
        var inputFrame = attachmentsBar.heightPublisher.value > 0
            ? attachmentsBar.frame.union(inputEditor.frame) : inputEditor.frame
        // The model row is on the input's ground, not below it: the model,
        // the effort, the speed and the context ring are part of what is
        // typed. It takes the room the band keeps under its own row.
        let modelHeight = modelBar.heightPublisher.value
        if modelHeight > 0 {
            modelBar.frame = CGRect(
                x: inputEditor.frame.minX + inputEditor.inset.left,
                y: inputFrame.maxY - inputEditor.inset.bottom,
                width: inputEditor.frame.width - inputEditor.inset.left - inputEditor.inset.right,
                height: modelHeight,
            )
            inputFrame.size.height += modelHeight
        }

        // One card morphs between the input and the request: the request's
        // band is cut off at the card's edge, shown or fading, never
        // collapsed to nothing. Shown, it takes the place the input would
        // have had, under the panels — not the top of the composer.
        place(
            approvalSection,
            at: presentingRequest ? bandsTop : spacing,
            height: presentingRequest ? approvalSection.heightPublisher.value : inputFrame.height,
        )
        shadowContainer.frame = presentingRequest
            ? approvalSection.frame.insetBy(dx: approvalSection.horizontalAdjustment, dy: 0)
            : inputFrame
        updateShadowGeometry()
        dropContainer.frame = shadowContainer.frame
        dropColorView.frame = dropContainer.bounds

        var finalHeight = shadowContainer.frame.maxY
        // The import panel opens below the box, off its ground. Folded, it is
        // hidden rather than faded: a view that is only transparent still
        // takes the taps meant for whatever has moved under the frame it kept,
        // and this one is drawn over the row of controls inside the box.
        if controlPanel.heightPublisher.value > 0 {
            controlPanel.isHidden = false
            place(controlPanel, at: finalHeight + spacing)
            finalHeight = controlPanel.frame.maxY
        } else {
            controlPanel.isHidden = true
        }

        heightPublisher.send(finalHeight)
    }

    /// Lays a panel out across the composer at `y`, and answers where the next
    /// band starts: the panel's own height plus the composer's spacing, or `y`
    /// when it is folded away.
    @discardableResult
    private func placePanel(_ panel: ComposerPanel, at y: CGFloat) -> CGFloat {
        let height = panel.heightPublisher.value
        guard height > 0 else {
            panel.isHidden = true
            return y
        }
        panel.isHidden = false
        panel.frame = CGRect(
            x: spacing,
            y: y,
            width: bounds.width - spacing * 2,
            height: height,
        )
        return panel.frame.maxY + spacing
    }

    /// Lays a draft menu out above the card, and answers where the next band
    /// starts: the menu's own height plus the composer's spacing, or `y` when
    /// it is not showing.
    @discardableResult
    private func placeMenu(_ menu: UIView, at y: CGFloat) -> CGFloat {
        let height: CGFloat = if let menu = menu as? ComposerCommandMenu {
            menu.preferredHeight
        } else if let menu = menu as? ComposerMentionMenu {
            menu.preferredHeight
        } else {
            0
        }
        guard height > 0 else {
            menu.isHidden = true
            return y
        }
        menu.isHidden = false
        menu.frame = CGRect(
            x: spacing,
            y: y,
            width: bounds.width - spacing * 2,
            height: height,
        )
        return menu.frame.maxY + spacing
    }

    /// Lays `band` out across the composer at `y`, as tall as it asks unless
    /// told otherwise, and answers where the next band starts.
    @discardableResult
    private func place(_ band: ComposerSectionView, at y: CGFloat, height: CGFloat? = nil) -> CGFloat {
        let height = height ?? band.heightPublisher.value
        let horizontalAdjustment = band.horizontalAdjustment
        band.frame = CGRect(
            x: spacing - horizontalAdjustment,
            y: y,
            width: bounds.width - spacing * 2 + horizontalAdjustment * 2,
            height: height,
        )
        return height > 0 ? band.frame.maxY + spacing : y
    }

    func updateHeightConstraint(_ height: CGFloat) {
        guard fittingHeightConstraint.constant != height else { return }
        fittingHeightConstraint.isActive = false
        fittingHeightConstraint = heightAnchor.constraint(equalToConstant: height)
        fittingHeightConstraint.priority = .defaultHigh
        fittingHeightConstraint.isActive = true
        hostingViewController?.view.layoutIfNeeded()
        setNeedsLayout()
    }

    /// The controller whose view holds the composer, which lays out again
    /// as the composer's height changes. Not SwifterSwift's
    /// `parentViewController`: importing SwifterSwift anywhere makes its
    /// `UIScrollView.scrollToBottom(animated:)` ambiguous with ListView's
    /// across the whole target, and Litext keeps an internal one by that
    /// name too.
    private var hostingViewController: UIViewController? {
        var responder = next
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    /// The rewrite button's state, held by whoever owns the request: the
    /// composer only draws it.
    func setRewriting(_ rewriting: Bool) {
        inputEditor.rewriteButton.isRewriting = rewriting
    }

    /// A rewrite came back: the draft takes the new text, and the old one is
    /// kept for the undo bar. The draft it was asked about has to still be
    /// the one in the box: once the message has been sent the box is empty,
    /// and a rewrite landing after that has nothing to replace and nothing
    /// to undo — it is dropped, and no bar offers words that are already in
    /// the conversation.
    func applyRewrite(original: String, rewritten: String) {
        setRewriting(false)
        guard (inputEditor.textView.text ?? "") == original else {
            rewriteBar.isHidden = true
            rewriteBar.onUndo = nil
            return
        }
        currentDraft.text = rewritten
        inputEditor.set(text: rewritten)
        publishNewEditorStatus()
        rewriteBar.isHidden = false
        rewriteBar.onUndo = { [weak self] in
            guard let self else { return }
            currentDraft.text = original
            inputEditor.set(text: original)
            publishNewEditorStatus()
            rewriteBar.isHidden = true
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// The rewrite did not land: the wand rests, and the draft stays as it was.
    func rewriteFailed() {
        setRewriting(false)
    }

    /// The ring was tapped: show what is left, or fold it away.
    func toggleContextPanel() {
        contextPanel.setExpanded(!contextPanel.isExpanded)
        modelBar.setContextExpanded(contextPanel.isExpanded)
    }

    /// What the ring and its panel draw, from the agent's last record.
    func setContextUsage(
        usedTokens: Int,
        limitTokens: Int,
        compactable: Bool,
        compacting: Bool,
    ) {
        contextPanel.set(
            usedTokens: usedTokens,
            limitTokens: limitTokens,
            compactable: compactable,
            compacting: compacting,
        )
    }

    /// The text changed: work out which menu, if either, the draft has opened.
    /// A command wins over a mention, and neither opens while a run is taking
    /// the message.
    private func refreshMenus() {
        let draft = text
        if let query = composerCommandQuery(in: draft), !inputEditor.isBusy {
            commandMenu.show(commands.matching(query))
            mentionMenu.show(.idle)
        } else if let query = composerMentionQuery(in: draft), !inputEditor.isBusy {
            commandMenu.show([])
            mentionMenu.show(mentionState(for: query))
        } else {
            commandMenu.show([])
            mentionMenu.show(.idle)
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func mentionState(for query: String) -> ComposerMentionState {
        guard let root = projectRoot else { return .unavailable }
        if projectFiles == nil {
            projectFiles = ComposerProjectIndex.files(in: root)
        }
        guard let files = projectFiles else { return .failed(message: String(localized: "Could not read the project's files.")) }
        return .ready(files: composerMatchingFiles(files, query: query))
    }

    /// A row was chosen: a command runs, a file closes the mention.
    private func pick(_ command: ComposerCommand) {
        switch command.kind {
        case .action:
            guard let action = commands.action(named: command.name) else { return }
            onRunCommand?(action, commandArguments(for: command))
        case .skill:
            guard let skill = commands.skill(named: command.name) else { return }
            onRunSkill?(skill, commandArguments(for: command))
        }
        // Choosing a command takes the draft: it was the command being named,
        // and what is left of it is not a message.
        resetValues()
        refreshMenus()
    }

    private func pick(_ path: String) {
        let updated = composerApplyingMention(path, to: text)
        currentDraft.text = updated
        inputEditor.set(text: updated)
        publishNewEditorStatus()
        refreshMenus()
        beginEditing()
    }

    /// What follows the command's name, for a command that takes arguments.
    private func commandArguments(for command: ComposerCommand) -> String {
        guard command.acceptsArguments else { return "" }
        let draft = text
        let name = command.display
        guard draft.hasPrefix(name) else { return "" }
        return String(draft.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The skills the agent reports, for the command menu's second half.
    func setSkills(_ skills: [AgentSkill]) {
        commands.setSkills(skills)
        refreshMenus()
    }

    func showApproval(_ message: ChatMessage?) {
        if message != nil {
            inputEditor.endEditing(true)
            controlPanel.close()
            // The card takes the composer, and the row whose ring opens the
            // context panel goes with it: a panel left open would have no
            // way back, so it folds as the card arrives.
            if contextPanel.isExpanded {
                toggleContextPanel()
            }
        }
        approvalSection.show(message)
        // A request takes the composer's attention, as typing does: the
        // to-do list folds while either goes on.
        todoPanel.holdFolded(approvalSection.isPresentingRequest || inputEditor.textView.isFirstResponder)
        updateModelBarVisibility()
    }

    private func updateModelBarVisibility() {
        // Only a request being answered takes the row away: the import panel
        // opens under the box, and the row above it keeps its plus — drawn as
        // a close while the panel is open, which is the way back out.
        modelBar.setVisible(!approvalSection.isPresentingRequest)
    }

    /// What is typed, trimmed.
    var text: String {
        (inputEditor.textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What is typed, as typed: the draft a conversation keeps.
    var draft: ComposerDraft {
        var draft = currentDraft
        draft.text = inputEditor.textView.text ?? ""
        return draft
    }

    /// The drop's tint, faint: the accent at 5%, the window's once the
    /// composer is in it.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        dropColorView.backgroundColor = tintColor.withAlphaComponent(0.05)
    }

    /// The ground under the composer's bands: glass on iOS 26, a white card
    /// with a soft shadow before it.
    private func applyShadowStyle() {
        if let glassEffectView {
            shadowContainer.backgroundColor = .clear
            shadowContainer.layer.shadowOpacity = 0
            glassEffectView.isHidden = false
        } else {
            shadowContainer.backgroundColor = handlerColor
            shadowContainer.layer.shadowColor = UIColor.black.cgColor
            shadowContainer.layer.shadowOpacity = 0.08
            shadowContainer.layer.shadowRadius = 8
            shadowContainer.layer.shadowOffset = .zero
        }
    }

    private func updateShadowGeometry() {
        if let glassEffectView {
            shadowContainer.layer.shadowPath = nil
            glassEffectView.frame = shadowContainer.frame
        } else {
            shadowContainer.layer.shadowPath = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: shadowContainer.frame.size),
                cornerRadius: shadowContainer.layer.cornerRadius,
            ).cgPath
        }
    }

    /// Back to empty and at rest.
    func resetValues() {
        currentDraft = ComposerDraft()
        attachmentsBar.show([])
        controlPanel.close()
        inputEditor.set(text: "")
        inputEditor.hasContent = false
        inputEditor.endEditing(true)
        // The words a rewrite kept are no longer in the box: the message they
        // were made from has gone, so the bar offering them back goes with it.
        rewriteBar.isHidden = true
        rewriteBar.onUndo = nil
        setNeedsLayout()
        publishNewEditorStatus()
    }

    /// Shows another conversation's draft. The delegate is not told: the
    /// text is that conversation's already.
    func restore(draft: ComposerDraft) {
        // A reply to the previous conversation must not hold this one's Send.
        submissionID = nil
        currentDraft = draft
        attachmentsBar.show(draft.attachments)
        inputEditor.hasAttachments = !draft.attachments.isEmpty
        inputEditor.hasContent = !draft.text.isEmpty || !draft.attachments.isEmpty
        controlPanel.close()
        inputEditor.set(text: draft.text)
    }

    /// The keyboard up on the text, as a tap on it would bring it; not
    /// while an approval covers the input.
    func beginEditing() {
        guard !approvalSection.isPresentingRequest else { return }
        inputEditor.textView.becomeFirstResponder()
    }

    func insertAttachment(_ attachment: ComposerAttachment) {
        currentDraft.attachments.append(attachment)
        attachmentsBar.show(currentDraft.attachments)
        inputEditor.hasAttachments = true
        inputEditor.hasContent = true
        publishNewEditorStatus()
    }

    func submitValues() {
        var draft = draft
        draft.text = text
        guard !draft.text.isEmpty || !draft.attachments.isEmpty, submissionID == nil, let delegate else { return }
        if draft.text.isEmpty {
            draft.text = String(localized: "Added \(draft.attachments.count) attachments")
        }
        let id = UUID()
        submissionID = id
        // The message shows in the conversation at once, so the composer
        // empties now; another Send waits until this one is answered.
        delegate.onComposerSubmit(draft: draft) { [weak self] in
            guard let self, submissionID == id else { return }
            submissionID = nil
        }
        // A delegate that answered at once sent nothing: the text stays.
        if submissionID == id {
            // The message is out: a rewrite still running for it has nothing
            // left to change, and stopping it keeps its answer — or its
            // failure — from landing on the empty box the send leaves.
            if inputEditor.rewriteButton.isRewriting {
                delegate.onComposerRewriteCancelled()
            }
            resetValues()
        }
    }

    func publishNewEditorStatus() {
        assert(Thread.isMainThread)
        inputEditor.hasAttachments = !currentDraft.attachments.isEmpty
        inputEditor.hasContent = !text.isEmpty || !currentDraft.attachments.isEmpty
        modelBar.setSendState(isBusy: inputEditor.isBusy, hasContent: inputEditor.hasContent)
        delegate?.onComposerUpdateDraft(draft)
    }

    /// A run started or ended: the send button says which of its two jobs a
    /// tap does now. Kept on the composer rather than in the delegate so the
    /// band repaints even when nothing else has changed.
    func setBusy(_ busy: Bool) {
        inputEditor.isBusy = busy
        inputEditor.hasContent = !text.isEmpty || !currentDraft.attachments.isEmpty
        modelBar.setSendState(isBusy: busy, hasContent: inputEditor.hasContent)
    }

    /// Something in the transcript is open: the box leads with the tip about
    /// folding it, since folding it back is what the reader just learnt they
    /// can do with the button under their thumb.
    func setExpandedProcess(_ expanded: Bool) {
        inputEditor.showsExpandedProcess = expanded
    }
}

extension ComposerView: ComposerInputView.Delegate {
    func onComposerInputMoreButtonTapped() {
        endEditing(true)
        controlPanel.toggle()
    }

    func onComposerInputBeginEditing() {
        controlPanel.close()
        todoPanel.holdFolded(true)
        delegate?.onComposerBeginEditing()
    }

    func onComposerInputPasteAsAttachmentTapped() {
        delegate?.onComposerPasteAsAttachmentTapped()
    }

    func onComposerInputSubmitButtonTapped() {
        submitValues()
    }

    func onComposerInputRewriteRequested(draft: String) {
        delegate?.onComposerRewriteRequested(draft: draft)
    }

    func onComposerInputRewriteCancelled() {
        delegate?.onComposerRewriteCancelled()
    }

    func onComposerInputEndEditing() {
        todoPanel.holdFolded(approvalSection.isPresentingRequest)
        publishNewEditorStatus()
    }

    func onComposerInputPastingLargeTextAsDocument(content: String) {
        delegate?.onComposerPastedLongText(content)
    }

    func onComposerInputPastingImage(image: UIImage) {
        delegate?.onComposerPastedImage(image)
    }

    func onComposerInputTextChanged(text: String) {
        dropColorView.alpha = 0
        publishNewEditorStatus()
        refreshMenus()
        if text.isEmpty {
            controlPanel.close()
        }
    }}

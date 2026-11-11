import ApelinCore
import ApelinProtocol
import ListViewKit
import SnapKit
import SPIndicator
import UIKit

/// The conversation page, the detail column's root while one is picked.
/// There is one, made once: picking another conversation hands it that
/// conversation (`use(_:)`), which rolls the title on the bar to the new
/// name, replaces the message list and restores that conversation’s draft.
/// Each conversation gets a fresh list and its own scrolling state.
///
/// The messages fill the page across its safe area; the composer sits at
/// its foot, on the keyboard when it is up, no wider than 750 pt and centred
/// in the safe area, and the list scrolls clear of it. Each side keeps its
/// own inset: a vertical bar (iPhone Duo) takes one side and not the other.
final class ChatController: UIViewController {
    /// The conversation shown, nil until the first is picked.
    private(set) var chat: ChatSummary?

    var runtime: ChatRuntime!
    /// Delete Conversation… in the `…` menu: the sidebar asks and deletes,
    /// as its own Delete does.
    var onDelete: ((UUID) -> Void)?
    /// A conversation to show instead, picked as the sidebar picks one: a
    /// fork Fork from Here made.
    var onOpenChat: ((ChatSummary) -> Void)?
    private let titleView = ChatTitleView()
    private var messageList = ListView<ChatMessage>()
    private let composer = ComposerView()
    private let topBlur = ChatTopBlurView()
    /// A tap on the page, anywhere the composer is not, puts the keyboard
    /// away; the tap still reaches what it landed on.
    private let keyboardDismissTap = UITapGestureRecognizer()
    private let latestMessageButton = UIButton(type: .system)
    /// One tick per message the reader sent, at the list's trailing edge
    /// while it scrolls: dragged, it moves the list between them.
    private let messageRuler = ChatMessageRuler()
    /// Over the page while the rail is dragged: the transcript softens a
    /// little and the card beside the finger is the one thing left sharp.
    /// Decoration only, so it takes no touch and says nothing to VoiceOver.
    /// The lightest material: the page must stay readable under it, since the
    /// reader is still looking for the message they are dragging to.
    private let rulerVeil = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private weak var tracePage: TraceController?
    /// Builds the rows again once a running turn has gone quiet.
    private let quietWatch = ChatQuietWatch()

    /// The shown conversation's rows as last applied.
    private var messages: [ChatMessage] = []
    /// The message the shown conversation's latest turn started with; a
    /// different one starts a new turn.
    private var turnMessage: UUID?
    /// The turn whose output the list follows (`TurnFollowing`): nil once
    /// a fast reply has brought its message to the top of the visible area,
    /// or the reader dragged, until the next turn.
    private var followedTurn: UUID?
    /// The conversations compacting themselves now, and how full each was
    /// when it last tried, so one fill compacts once.
    private var autoCompacting: Set<UUID> = []
    private var autoCompactAttempt: [UUID: Int] = [:]
    /// The request the composer shows in place of the input, and the
    /// conversation its Stop stops. Each change to either lays the whole
    /// window out on the composer's spring, so the composer is told only of
    /// a change, never again on every streamed batch.
    private var shownApproval: ChatMessage?
    /// A root request whose owner check is on screen: a second tap on
    /// Approve does not ask again.
    private var checkingOwner: UUID?
    private var stoppableChat: UUID?
    /// While `use(_:)` swaps another conversation in: nothing animates, and
    /// the list's opening scroll waits for its rows.
    private var isSwitchingChat = false
    /// The keyboard waits for the page to be on screen (`beginTyping`).
    private var typesOnAppear = false
    /// Conversations whose queued messages went back to the composer, said
    /// once the reader sees them (`sayUnsent`).
    private var unsent: [UUID: (messages: Int, attachmentsLeftOut: Int)] = [:]
    private var needsInitialScroll = false
    /// Whether the reader was at the latest message when the page last
    /// changed width — the sidebar opening or closing. The rows wrap again
    /// and the content's height changes under the list, so the list is put
    /// back at its end, and kept there as the rows above are measured again,
    /// until the reader drags it.
    private var holdsLatestMessage = false
    /// Where a reader elsewhere in the conversation was when the page last
    /// changed width: the row at the top of what they saw, under the bar,
    /// and how far into it. The rows wrap again, and a long reply grows or
    /// shrinks around the line the reader was on, so the list is put back
    /// at the same point in that row rather than at the same offset.
    private var readingPlace: (row: ChatMessage.ID, fraction: CGFloat)?
    private var lastLayoutWidth: CGFloat = 0
    private var modelLoader: Task<Void, Never>?
    private var selectionCheck: Task<Void, Never>?
    private var attachmentImport: ComposerAttachmentImport?
    private var skillsLoaded = false
    private var skillsLoading = false
    /// The rewrite in flight, so a second tap stops it rather than racing it.
    private var rewriteTask: Task<Void, Never>?

    private var attachmentHeightLimit: CGFloat {
        (view.window?.bounds.height ?? view.bounds.height) * 0.3
    }

    /// The scale a message row measures and lays out its images at.
    private var displayScale: CGFloat {
        (view.window ?? view).traitCollection.displayScale
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        navigationItem.titleView = titleView
        navigationItem.largeTitleDisplayMode = .never
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: nil)
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self, weak more] completion in
            guard let self, let more, let chat else { completion([]); return }
            ChatActions.menu(
                for: chat,
                runtime: runtime,
                from: self,
                anchor: more,
                onPrepareDistribution: { [weak self] prompt in self?.sendPrompt(prompt) },
                onDelete: { [weak self] id in self?.onDelete?(id) },
                completion: completion,
            )
        }])
        more.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItem = more
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .pageBackground

        // The keyboard goes when the page is tapped anywhere but on the
        // composer. `cancelsTouchesInView` stays false, so the tap still
        // does what it was aimed at — a row, a button, a link.
        keyboardDismissTap.cancelsTouchesInView = false
        keyboardDismissTap.delegate = self
        keyboardDismissTap.addTarget(self, action: #selector(dismissKeyboardOnTap))
        view.addGestureRecognizer(keyboardDismissTap)

        replaceMessageList()
        view.addSubview(topBlur)

        composer.delegate = self
        composer.approvalSection.onDecision = { [weak self] request, decision in
            guard let self, let chat else { return }
            Task { await self.decide(request, decision, in: chat.id) }
        }
        composer.approvalSection.onAnswer = { [weak self] request, answer in
            guard let self, let chat else { return }
            Task { await self.answer(request, answer, in: chat.id) }
        }
        composer.approvalSection.onAnswerOther = { [weak self] request, chosen in
            guard let self, let chat else { return }
            askForOwnAnswer(to: request, chosen: chosen, in: chat.id)
        }
        composer.modelBar.onEffortTapped = { [weak self] in self?.presentEffortSheet() }
        composer.modelBar.onTierTapped = { [weak self] in self?.presentTierSheet() }
        composer.onModeChanged = { [weak self] mode in
            // The store is what the next prompt reads, and it is this
            // conversation's own entry, never the app's: the pill has already
            // taken its own colour, and this writes what it took where the run
            // that leaves from this page will find it.
            guard let self else { return }
            ComposerModeStore.set(mode, for: self.chat?.id)
        }
        composer.onCompactContext = { [weak self] in
            guard let self, let chat else { return }
            ChatActions.askToCompact(for: chat.id, runtime: runtime, from: self)
        }
        composer.todoPanel.onHide = { [weak self] in self?.confirmHideTodoList() }
        composer.onRunCommand = { [weak self] command, arguments in
            guard let self else { return }
            command.run(arguments: arguments, in: self)
        }
        composer.onRunSkill = { [weak self] skill, arguments in
            guard let self else { return }
            // A skill is the turn's instructions: its body is the prompt, with
            // what was typed after the name where the body asks for it.
            let prompt = substituteArguments(skill.body, with: arguments)
            self.sendPrompt(prompt)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateModelSelection),
            name: .composerModelSelectionChanged,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(enabledModelsChanged),
            name: .enabledModelsChanged,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(withdrawNotifications),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sayUnsent),
            name: UIApplication.didBecomeActiveNotification,
            object: nil,
        )
        updateModelSelection()
        view.addSubview(composer)
        composer.snp.makeConstraints { make in
            if #available(iOS 17.0, *) {
                // Above a keyboard, the gap the bands keep between
                // themselves; without one, the safe area's own edge.
                view.keyboardLayoutGuide.usesBottomSafeArea = false
                make.bottom.lessThanOrEqualTo(view.keyboardLayoutGuide.snp.top).offset(-composer.spacing)
                make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide).offset(16)
                make.bottom.equalTo(view.safeAreaLayoutGuide).offset(16).priority(.high)
            } else {
                make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
            }
            // A floating card, not a band welded to the page's edge: the
            // messages scroll under it on both sides, so the card keeps a
            // margin of its own on each side and sits above the safe area.
            make.centerX.equalTo(view.safeAreaLayoutGuide)
            make.width.lessThanOrEqualTo(750)
            make.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide).offset(16)
            make.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide).offset(-16)
            make.width.equalTo(view.safeAreaLayoutGuide).offset(-32).priority(.low)
        }

        var latestConfiguration: UIButton.Configuration
        if #available(iOS 26, *) {
            latestConfiguration = .glass()
        } else {
            latestConfiguration = .plain()
            latestConfiguration.background.customView = UIVisualEffectView(
                effect: UIBlurEffect(style: .systemMaterial),
            )
        }
        latestConfiguration.image = UIImage(systemName: "chevron.down")
        latestConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 17,
            weight: .semibold,
        )
        latestConfiguration.baseForegroundColor = .label
        latestConfiguration.cornerStyle = .capsule
        latestMessageButton.configuration = latestConfiguration
        latestMessageButton.accessibilityLabel = String(localized: "Scroll to latest message")
        latestMessageButton.isHidden = true
        latestMessageButton.alpha = 0
        latestMessageButton.addAction(UIAction { [weak self] _ in
            self?.revealLatestMessage()
        }, for: .touchUpInside)
        view.addSubview(latestMessageButton)
        latestMessageButton.snp.makeConstraints { make in
            make.centerX.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(composer.snp.top).offset(-8)
            make.size.equalTo(44)
        }

        // Under the composer, which the preview card never covers.
        view.insertSubview(messageRuler, belowSubview: composer)
        messageRuler.onScrubBegan = { [weak self] in self?.beginRulerScrub() }
        messageRuler.onSelect = { [weak self] index, settled in
            guard let self else { return }
            // Lifting the finger ends the scrub whether or not the entry it
            // was on is still in the list: the composer and the page come
            // back either way.
            if settled {
                setComposerFaded(false)
                setRulerVeil(false)
            }
            showRulerEntry(index, loadsHistory: settled)
        }
        // The rail and its card stay above the veil, which is why the rail is
        // brought forward of the composer here: the two never overlap.
        rulerVeil.isUserInteractionEnabled = false
        rulerVeil.isAccessibilityElement = false
        rulerVeil.accessibilityElementsHidden = true
        rulerVeil.alpha = 0
        rulerVeil.isHidden = true
        view.addSubview(rulerVeil)
        view.bringSubviewToFront(messageRuler)
        view.accessibilityCustomRotors = [yourMessagesRotor()]
    }

    private func replaceMessageList() {
        let contentInset = messageList.contentInset
        let indicatorInset = messageList.verticalScrollIndicatorInsets
        messageList.delegate = nil
        messageList.layer.mask = nil
        messageList.removeFromSuperview()
        messageList = ListView<ChatMessage>()
        messageList.frame = messageListFrame
        messageList.contentInset = contentInset
        messageList.verticalScrollIndicatorInsets = indicatorInset
        messageList.backgroundColor = .clear
        messageList.keyboardDismissMode = .interactive
        messageList.delegate = self
        messageList.rows {
            ListRow(ChatTurnHeaderRow.self)
                .when { message in
                    if case .turn = message.role { return true }
                    return false
                }
                .height { message, context in ChatTurnHeaderRow.height(for: message, width: context.width) }
                .configure { [weak self] row, message, _ in
                    row.show(message)
                    // The header opens and folds the turn's process: the
                    // rows are put in or taken out, and the list redraws.
                    row.onToggle = { [weak self] in
                        guard let self else { return }
                        self.showTranscript(self.messages)
                    }
                }
            ListRow(ChatActivityRow.self)
                .when { $0.role.isActivity }
                .height { message, context in ChatActivityRow.height(for: message, width: context.width) }
                .configure { [weak self] row, message, _ in
                    row.show(message)
                    // The steps were folded or unfolded: the row is measured
                    // again, and what is under it moves, without the list
                    // being rebuilt.
                    row.onToggle = { [weak self] in
                        guard let self else { return }
                        self.messageList.reconfigureRow(with: message.id)
                        self.messageList.invalidateLayout(forRowWith: message.id)
                    }
                    row.onOpenPage = { [weak self] in
                        guard let self else { return }
                        let page = TraceController(message: message)
                        self.tracePage = page
                        self.presentPageAsFormSheet(page)
                    }
                }
            ListRow(ChatCompactionRow.self)
                .when { $0.role == .compaction }
                .height { message, context in ChatCompactionRow.height(for: message, width: context.width) }
                .configure { [weak self] row, message, _ in
                    row.show(message)
                    row.onOpen = { [weak self] in
                        self?.presentPageAsFormSheet(ChatCompactionController(summary: message.text))
                    }
                }
            ListRow(ChatMessageRow.self)
                .height { [weak self] message, context in
                    ChatMessageRow.height(
                        for: message,
                        width: context.width,
                        maximumAttachmentHeight: self?.attachmentHeightLimit ?? 0,
                        displayScale: self?.displayScale ?? 0,
                    )
                }
                .configure { [weak self] row, message, _ in
                    let chatID = self?.chat?.id
                    row.attachmentHeightLimit = self?.attachmentHeightLimit ?? 0
                    row.displayScale = self?.displayScale ?? 0
                    row.show(message, isStreaming: self?.chat?.isWorking == true)
                    row.onAttachmentLayoutChanged = { [weak self] in
                        guard let self, chat?.id == chatID else { return }
                        messageList.reconfigureRow(with: message.id)
                        messageList.invalidateLayout(forRowWith: message.id)
                    }
                    row.onPreview = { [weak self] item in self?.onComposerPreviewAttachment(item) }
                    row.onCopy = { [weak self, weak row] in
                        self?.copyText(of: message)
                        row?.showCopied()
                    }
                    row.onRewind = { [weak self] in self?.presentRewind(for: message.id) }
                    row.onMore = { [weak self] in self?.presentMessageMenu(for: message.id) }
                    row.onPreviewImages = { [weak self] images, selectedID in
                        do {
                            try self?.present(
                                ComposerAttachmentPreview(attachments: images, selectedID: selectedID),
                                animated: true,
                            )
                        } catch {
                            self?.presentNotice(title: "Unable to Preview Attachment", message: error.readableMessage)
                        }
                    }
                }
        }
        view.insertSubview(messageList, at: 0)
        // The composer is another overlay; explicitly identify the list
        // whose scroll position drives the navigation bar's edge treatment.
        setContentScrollView(messageList, for: .top)
        if #available(iOS 26, *) {
            messageList.topEdgeEffect.isHidden = true
        }
        // Top to bottom of the page, so it scrolls under the bar and the
        // composer, but side to side only across the safe area: a row lays
        // itself out across the list's whole width, and a vertical bar's
        // strip is the bar's. The margins inside it still scroll.
        messageList.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalTo(view.safeAreaLayoutGuide)
        }
    }

    /// Where the constraints put the list: the page, less the safe area's
    /// sides.
    private var messageListFrame: CGRect {
        let insets = view.safeAreaInsets
        return view.bounds.inset(by: UIEdgeInsets(top: 0, left: insets.left, bottom: 0, right: insets.right))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if typesOnAppear {
            typesOnAppear = false
            composer.beginEditing()
        }
        sayUnsent()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // read before the list takes the new width
        let width = messageListFrame.width
        guard width != lastLayoutWidth else { return }
        if lastLayoutWidth > 0, !needsInitialScroll {
            if distanceFromLatestMessage <= 2 {
                holdsLatestMessage = true
            } else if !holdsLatestMessage, readingPlace == nil {
                readingPlace = currentReadingPlace()
            }
        }
        lastLayoutWidth = width
    }

    /// The row the line under the bar crosses, and the fraction of its
    /// height above that line.
    private func currentReadingPlace() -> (row: ChatMessage.ID, fraction: CGFloat)? {
        let line = messageList.contentOffset.y + messageList.adjustedContentInset.top
        for index in messageList.indicesForVisibleRows.sorted() {
            let frame = messageList.rectForRow(at: index)
            guard frame.height > 0, frame.maxY > line else { continue }
            let fraction = min(max((line - frame.minY) / frame.height, 0), 1)
            return (messageList.content[index].id, fraction)
        }
        return nil
    }

    /// Puts the reader back on the line `readingPlace` kept, now that the
    /// rows have their new width.
    private func restoreReadingPlace() {
        guard let place = readingPlace else { return }
        readingPlace = nil
        guard !messageList.isTracking, !messageList.isDecelerating else { return }
        messageList.layoutIfNeeded()
        let frame = messageList.rectForRow(with: place.row)
        guard frame.height > 0 else { return }
        let line = frame.minY + place.fraction * frame.height
        let target = min(
            max(line - messageList.adjustedContentInset.top, messageList.minimumContentOffset.y),
            messageList.maximumContentOffset.y,
        )
        guard abs(target - messageList.contentOffset.y) > 0.5 else { return }
        // inside the sidebar's animation the list rides it, as the latest
        // message does (`holdLatestMessage`)
        messageList.contentOffset = CGPoint(x: messageList.contentOffset.x, y: target)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateMessageListInsets()
        // Not while `use(_:)` is still swapping the conversation in:
        // restoring its draft lays the window out before its rows are in the
        // list, and a pass then would find the new list empty, take that for
        // its end, and leave the page where the estimated heights put the
        // end — a long chat's middle. `use(_:)` asks for the pass after.
        if needsInitialScroll, !isSwitchingChat, view.window != nil, messageList.bounds.width > 0,
           messageList.bounds.height > 0
        {
            needsInitialScroll = false
            // The list measures newly visible rows during layout. Settle
            // those measurements at the end too, before the page is revealed.
            // Each advancing pass measures another row. A clamp or an
            // asynchronous attachment must not keep the main thread here;
            // leave the request pending for its next real layout instead.
            for _ in 0 ... messageList.content.count {
                let previousOffset = messageList.contentOffset.y
                let previousEnd = messageList.maximumContentOffset.y
                messageList.scrollToBottom(animated: false)
                messageList.layoutIfNeeded()
                if abs(messageList.contentOffset.y - messageList.maximumContentOffset.y) <= 0.5 {
                    break
                }
                if abs(messageList.contentOffset.y - previousOffset) <= 0.5,
                   abs(messageList.maximumContentOffset.y - previousEnd) <= 0.5
                {
                    break
                }
            }
            needsInitialScroll = abs(messageList.contentOffset.y - messageList.maximumContentOffset.y) > 0.5
        }
        if holdsLatestMessage {
            messageList.layoutIfNeeded()
            holdLatestMessage()
        } else {
            restoreReadingPlace()
        }
        updateLatestMessageButton()
        topBlur.frame = CGRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: min(view.bounds.height, view.safeAreaInsets.top + 20),
        )
        layoutMessageRuler()
    }

    /// Shows `chat`. The same conversation again only takes its new name;
    /// another one also swaps the messages and the draft.
    func use(_ chat: ChatSummary) {
        loadViewIfNeeded()
        let previous = self.chat
        self.chat = chat
        ConversationNotices.shared.withdraw(session: runtime.records[chat.id]?.sessionID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.loadHistory(chat.id)
                if self.chat?.id == chat.id { refreshRuntime() }
            } catch is CancellationError {
                return
            } catch {
                guard self.chat?.id == chat.id else { return }
                presentNotice(title: "Unable to Load Conversation", message: error.readableMessage)
            }
        }
        updateModelSelection()
        ensureModelSelection()
        // The pill is the one control said to carry a setting of its own: the
        // page it now belongs to hands it this conversation's mode, so a chat
        // opened after another never shows, or sends, the other one's.
        composer.modelBar.modePill.set(mode: ComposerModeStore.mode(for: chat.id))
        title = chat.displayTitle
        // rolled only on screen; a page coming back shows its name at once
        titleView.setTitle(chat.titlePresentation, animated: previous != nil && view.window != nil)
        guard previous?.id != chat.id else { return }
        isSwitchingChat = true
        needsInitialScroll = true
        holdsLatestMessage = false
        readingPlace = nil
        holdsHistoryTop = false
        isLoadingEarlierHistory = false
        defer { isSwitchingChat = false }
        replaceMessageList()

        if let previous {
            runtime.saveDraft(composer.draft, for: previous.id)
        }
        let draft = runtime.records[chat.id]?.draft ?? ComposerDraft()
        composer.restore(draft: draft)
        messages = runtime.transcript(chat.id).messages
        // A turn still running is followed again.
        turnMessage = TurnFollowing.turnMessage(in: messages)
        followedTurn = runtime.records[chat.id]?.summary.isWorking == true ? turnMessage : nil
        showTranscript(messages)
        refreshRuntime()
        messageList.scrollToBottom(animated: false)
        updateLatestMessageButton()
        // the opening pass, now that the rows are in (`viewDidLayoutSubviews`)
        view.setNeedsLayout()
        sayUnsent()
    }

    /// Back in front with this conversation on screen: its banners have
    /// said what they had to.
    @objc private func withdrawNotifications() {
        guard let chat, view.window != nil else { return }
        ConversationNotices.shared.withdraw(session: runtime.records[chat.id]?.sessionID)
    }

    /// Fills the reader's threshold: the conversation compacts itself, as if
    /// they had asked, rather than waiting to run out of room. Once per
    /// fill — a compaction that did not bring the figure down is not tried
    /// again until the conversation grows past where it was.
    private func compactIfFull(
        _ id: UUID,
        usage: ChatContextUsage?,
        isWorking: Bool,
        isCompacting: Bool,
    ) {
        guard let usage, usage.window > 0,
              usage.fraction >= Preferences.compressionThreshold,
              !isWorking, !isCompacting,
              !autoCompacting.contains(id),
              autoCompactAttempt[id] != usage.tokens,
              runtime.canCompact(id)
        else { return }
        autoCompactAttempt[id] = usage.tokens
        autoCompacting.insert(id)
        Task { @MainActor in
            _ = try? await runtime.compact(id)
            autoCompacting.remove(id)
            refreshRuntime()
        }
    }

    func refreshRuntime() {
        guard let chat else { return }
        if let summary = runtime.summary(chat.id) {
            self.chat = summary
            if title != summary.displayTitle {
                // a rename, or the agent's title: the back button's too
                title = summary.displayTitle
            }
            titleView.setTitle(summary.titlePresentation, animated: view.window != nil)
            let transcript = runtime.transcript(chat.id)
            updateMessages(transcript.messages)
            composer.setBusy(summary.isWorking)
            composer.queuePanel.show(transcript.messages.filter(\.isQueued))
            // The agent writes the list through a tool; reading it here is what
            // makes a change the app never saw an event for show up.
            if let sessionID = runtime.records[chat.id]?.sessionID {
                let list = TodoStore(root: DataFolder.app.root).list(for: sessionID)
                let shown = TodoListHiding.isHidden(list, for: sessionID) ? TodoList() : list
                composer.todoPanel.show(shown, for: sessionID)
            } else {
                composer.todoPanel.show(TodoList(), for: nil)
            }
            // The conversation's project decides what an `@` can offer; a
            // temporary chat has no files of its own to name.
            composer.projectRoot = summary.projectName.flatMap { DataFolder.app.project(named: $0) }
            composer.modelBar.setContextUsage(transcript.contextUsage, compactable: runtime.canCompact(chat.id))
            // The agent may have changed the run mode itself
            // (`apelin_run_mode`): the log's last word is what the pill shows
            // and what the next prompt goes out with, whether the change came
            // while this page was open or while the app was away.
            if let mode = transcript.runMode, ComposerModeStore.mode(for: chat.id) != mode {
                ComposerModeStore.set(mode, for: chat.id)
                composer.modelBar.modePill.set(mode: mode)
            }
            composer.setContextUsage(
                usedTokens: transcript.contextUsage?.tokens ?? 0,
                limitTokens: transcript.contextUsage?.window ?? 0,
                compactable: runtime.canCompact(chat.id) && !summary.isWorking,
                compacting: transcript.isCompacting,
            )
            compactIfFull(
                chat.id,
                usage: transcript.contextUsage,
                isWorking: summary.isWorking,
                isCompacting: transcript.isCompacting,
            )
            quietWatch.wake(at: transcript.quietDeadline) { [weak self] in self?.refreshRuntime() }
            if summary.isWorking != chat.isWorking {
                // the session stopped (or came back) with no event that redraws the request
                showApproval(summary.isWorking ? messages.first { $0.role.needsApproval } : nil)
            }
            let stoppable = summary.isWorking ? chat.id : nil
            if stoppable != stoppableChat {
                stoppableChat = stoppable
                composer.modelBar.setSendState(
                    isBusy: summary.isWorking,
                    hasContent: !composer.draft.text.isEmpty || !composer.draft.attachments.isEmpty,
                )
            }
        }
    }

    /// Sends the reader's decision. Approving a command as root first asks
    /// for Face ID, Touch ID or the passcode (`DeviceOwnerCheck`); when that
    /// does not pass, nothing is sent and the request goes on waiting.
    private func decide(_ request: ChatMessage, _ decision: ApprovalDecision, in chatID: UUID) async {
        var ownerVerified: Bool?
        if decision == .approve, request.runsAsRoot {
            guard checkingOwner == nil else { return }
            checkingOwner = request.id
            let confirmed = await DeviceOwnerCheck.confirm(
                reason: String(localized: "Approve a command that runs as root on this device."),
            )
            checkingOwner = nil
            guard confirmed else {
                SPIndicator.present(
                    title: String(localized: "Not Approved"),
                    message: String(localized: "The request is still waiting."),
                    preset: .error,
                    haptic: .error,
                )
                return
            }
            ownerVerified = true
        }
        do {
            try await runtime.approve(request.id, in: chatID, decision: decision, ownerVerified: ownerVerified)
        } catch {
            presentNotice(title: "Unable to Send Decision", message: error.readableMessage)
        }
    }

    /// Sends the reader's answer to the agent's question, or that they
    /// skipped it (nil).
    private func answer(_ request: ChatMessage, _ answer: AgentQuestionAnswer?, in chatID: UUID) async {
        do {
            try await runtime.approve(
                request.id,
                in: chatID,
                decision: answer == nil ? .deny : .approve,
                answer: answer,
            )
        } catch {
            presentNotice(title: "Unable to Send Decision", message: error.readableMessage)
        }
    }

    /// Other…: the reader writes an answer of their own, sent with the
    /// options they had already chosen. Nothing typed sends nothing, and
    /// the question goes on waiting.
    private func askForOwnAnswer(to request: ChatMessage, chosen: [String], in chatID: UUID) {
        presentTextInput(
            title: "Other…",
            message: String.LocalizationValue(request.approvalTitle),
            placeholder: "Your answer",
            doneTitle: "Send",
        ) { [weak self] text in
            let written = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AgentQuestionRules.maximumOtherLength))
            guard let self, !written.isEmpty else { return }
            Task { await self.answer(request, AgentQuestionAnswer(selected: chosen, other: written), in: chatID) }
        }
    }

    private func showApproval(_ request: ChatMessage?) {
        guard request != shownApproval else { return }
        shownApproval = request
        composer.showApproval(request)
    }

    /// A new user message starts a turn, whose output the list then follows
    /// (`followTurn`) while the reader is at the latest message.
    private func updateMessages(_ items: [ChatMessage]) {
        guard Self.differs(messages, items) else { return }
        // A compaction's row comes between turns, with none to follow: a
        // reader at the latest message is shown it.
        let revealsCompaction = followedTurn == nil && distanceFromLatestMessage <= 2
            && items.last?.role == .compaction && items.last?.id != messages.last?.id
        // Read before the rows are applied: the new content moves the offset,
        // and what matters is where the reader was before it arrived.
        let heldLatest = distanceFromLatestMessage <= 2
        messages = items
        let message = TurnFollowing.turnMessage(in: items)
        if message != turnMessage {
            turnMessage = message
            followedTurn = message
        }
        showTranscript(items)
        followTurn(heldLatest: heldLatest)
        if revealsCompaction {
            revealLatestMessage()
        }
        updateLatestMessageButton()
    }

    /// Whether the rows differ, read from the end: a run changes what it last
    /// wrote, and comparing the whole transcript — every call's arguments and
    /// result — on every event of it is what made a stream stutter.
    private static func differs(_ old: [ChatMessage], _ new: [ChatMessage]) -> Bool {
        guard old.count == new.count else { return true }
        var index = new.count - 1
        while index >= 0 {
            if old[index] != new[index] {
                return true
            }
            index -= 1
        }
        return false
    }

    /// Moves the list with the followed turn's output while the reader is at
    /// the latest message; scrolled back into the conversation, they are
    /// reading, and the list stays where they put it.
    private func followTurn(heldLatest: Bool) {
        guard followedTurn != nil, heldLatest else { return }
        guard !messageList.isTracking, !messageList.isDecelerating else { return }
        messageList.scrollToBottom(
            animated: !isSwitchingChat && !needsInitialScroll && !UIAccessibility.isReduceMotionEnabled,
        )
    }

    /// Shows the newest content, once: the turn is not followed again.
    private func revealLatestMessage() {
        messageList.scrollToBottom(animated: !UIAccessibility.isReduceMotionEnabled)
        updateLatestMessageButton()
    }

    private func showTranscript(_ items: [ChatMessage]) {
        if let page = tracePage, let message = items.first(where: { $0.id == page.messageID }) {
            page.show(message)
        }
        // A turn's whole process is drawn under an open header, which is the
        // one way in, as aimini's turn header is. Folded, it is one summary
        // row — the newest, and only while the turn runs, so the state and
        // what it is doing now are on screen — with the reply under it. That
        // row keeps the turn's name, so the next stretch's summary replaces
        // the one before it in place.
        var newestActivity: [UUID: Int] = [:]
        var runningTurns = Set<UUID>()
        for (offset, item) in items.enumerated() {
            guard let turn = item.turnMessageID else { continue }
            if case let .turn(running, _) = item.role, running {
                runningTurns.insert(turn)
            }
            if case .thinking = item.role {
                newestActivity[turn] = offset
            }
        }
        var visible: [ChatMessage] = []
        visible.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            guard !item.role.isApproval else { continue }
            guard case .thinking = item.role, let turn = item.turnMessageID else {
                visible.append(item)
                continue
            }
            if ChatTraceExpansion.isExpanded(turn: turn) {
                visible.append(item)
            } else if runningTurns.contains(turn), newestActivity[turn] == offset {
                var row = item
                row.id = ChatTranscript.rowID(forProcess: turn)
                row.foldsProcessSteps = true
                visible.append(row)
            }
        }
        messageList.apply(visible, animated: !isSwitchingChat && !UIAccessibility.isReduceMotionEnabled)
        updateMessageRuler(visible)
        // a request its stopped session left can no longer be answered
        showApproval(chat?.isWorking == true ? items.first { $0.role.needsApproval } : nil)
    }

    /// A tap outside the composer: the keyboard is done with this page.
    @objc private func dismissKeyboardOnTap() {
        view.endEditing(true)
    }

    @objc private func updateModelSelection() {
        let selection = chat.flatMap { ComposerModelSelection.selection(for: $0.id) }
        composer.modelBar.setModel(selection?.provider, model: selection?.model)
        composer.modelBar.setEfforts(selection?.supportedEfforts ?? [], selected: selection?.effort)
        composer.modelBar.setTiers(selection?.supportedTiers ?? [], selected: selection?.tier)
    }

    /// A model disabled in Settings stops being the one the next message uses.
    @objc private func enabledModelsChanged() {
        ensureModelSelection()
    }

    /// The list scrolls clear of the composer, and of the keyboard under it.
    private func updateMessageListInsets() {
        let covered = max(view.bounds.height - composer.frame.minY + 8, 0)
        let bottom = max(covered - view.safeAreaInsets.bottom, 0)
        if messageList.contentInset.bottom != bottom + 16 {
            // a reader at the latest message, or following a turn, stays there
            let keepsLatest = followedTurn != nil || distanceFromLatestMessage <= 2
            messageList.contentInset.bottom = bottom + 16
            if keepsLatest, !messageList.isTracking, !messageList.isDecelerating {
                if UIView.inheritedAnimationDuration > 0 {
                    // The composer is springing to a new height: the list
                    // rides the same animation. `scrollToBottom(animated:
                    // false)` would jump there ahead of it, since ListView
                    // keeps its own placements out of a caller's animation;
                    // the public setter is the one it leaves to the host.
                    messageList.contentOffset = messageList.maximumContentOffset
                } else {
                    // Opening and keyboard layout place the list immediately;
                    // only a new transcript update animates following output.
                    messageList.scrollToBottom(animated: false)
                }
            }
        }
        if messageList.verticalScrollIndicatorInsets.bottom != bottom {
            messageList.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    /// The mark was tapped: what the signed-in providers have enabled, read
    /// again at each tap, including after setup, and shown in the sheet every
    /// picker of this row opens in.
    private func presentModelSheet() {
        guard let chat else { return }
        modelLoader?.cancel()
        modelLoader = Task { [weak self] in
            guard let self else { return }
            do {
                let accounts = try await EnabledModels.accounts(from: ApelinService.app.agentAccountsWithKnownModels())
                guard !Task.isCancelled, self.chat?.id == chat.id else { return }
                // Nothing enabled is nothing to pick: the accounts page is.
                guard !accounts.isEmpty else {
                    guard presentedViewController == nil else { return }
                    presentPageAsFormSheet(ModelProvidersController())
                    return
                }
                showModels(accounts)
            } catch {
                guard !Task.isCancelled, self.chat?.id == chat.id else { return }
                presentNotice(title: "Models Unavailable", message: error.readableMessage)
            }
        }
    }

    /// One group of models per signed-in provider, the one in use marked.
    private func showModels(_ accounts: [AgentAccount]) {
        guard let id = chat?.id, presentedViewController == nil else { return }
        let selected = ComposerModelSelection.selection(for: id)
        let groups = accounts.map { account in
            ComposerChoiceSheet.Group(
                title: account.account ?? account.provider.displayName,
                choices: (account.models ?? []).map { model in
                    ComposerChoiceSheet.Choice(
                        // The name the catalog gives it, with the provider's own
                        // id under it: the id is what the conversation sends.
                        title: account.displayName(for: model),
                        subtitle: account.catalogTitle(for: model) == nil ? nil : model,
                        isSelected: account.provider == selected?.provider && model == selected?.model,
                        modelTest: AgentModelTestRequest(provider: account.provider, model: model),
                    ) { ComposerModelSelection.choose(Self.selection(of: model, in: account), for: id) }
                },
            )
        }
        ComposerChoiceSheet.present(
            ComposerChoiceSheet(heading: String(localized: "Model"), groups: groups),
            from: self,
        )
    }

    /// The sparks were tapped: the levels this model offers, in the same sheet.
    /// The pick is the reader's own, kept apart from the model, so a later
    /// model that offers it gets it back.
    private func presentEffortSheet() {
        guard let id = chat?.id, let selection = ComposerModelSelection.selection(for: id),
              !selection.supportedEfforts.isEmpty,
              presentedViewController == nil
        else { return }
        let current = selection.effort
        let choices = selection.supportedEfforts.map { effort in
            ComposerChoiceSheet.Choice(
                title: ComposerModelBar.title(for: effort),
                isSelected: effort == current,
            ) { ComposerModelSelection.setEffort(effort, for: id) }
        }
        ComposerChoiceSheet.present(
            ComposerChoiceSheet(
                heading: String(localized: "Reasoning Effort"),
                groups: [ComposerChoiceSheet.Group(choices: choices)],
            ),
            from: self,
        )
    }

    /// The hare was tapped: the standard speed and the faster tiers this model
    /// offers. A model with one tier hides the control, so this is never empty.
    private func presentTierSheet() {
        guard let id = chat?.id, let selection = ComposerModelSelection.selection(for: id),
              let tiers = selection.supportedTiers, !tiers.isEmpty,
              presentedViewController == nil
        else { return }
        let current = selection.tier
        let choices = ([nil] + tiers.map { $0 as AgentServiceTier? }).map { tier in
            ComposerChoiceSheet.Choice(
                title: ComposerModelBar.title(for: tier),
                isSelected: tier == current,
            ) { ComposerModelSelection.setTier(tier, for: id) }
        }
        ComposerChoiceSheet.present(
            ComposerChoiceSheet(
                heading: String(localized: "Speed"),
                groups: [ComposerChoiceSheet.Group(choices: choices)],
            ),
            from: self,
        )
    }
}

extension ChatController {
    /// `model` of `account` with what the catalog says it offers. The
    /// reader's effort and speed are kept apart (`ComposerModelPreferences`),
    /// so picking a model that lacks them does not lose them.
    private static func selection(of model: String, in account: AgentAccount) -> ComposerModelSelection {
        ComposerModelSelection(
            provider: account.provider,
            model: model,
            supportedEfforts: (account.reasoningEfforts?[model] ?? []).filter { [.low, .high, .max].contains($0) },
            supportedTiers: account.serviceTiers?[model] ?? [],
        )
    }

    /// With no model picked, or one no longer enabled, the first enabled
    /// model is picked; with none enabled the bar keeps asking. A model
    /// still enabled takes the catalog's efforts and tiers again. A
    /// signed-in account whose sign-in did not read this time lists no
    /// models; its model is kept rather than swapped for another's.
    func ensureModelSelection() {
        selectionCheck?.cancel()
        guard let id = chat?.id else { return }
        selectionCheck = Task {
            guard let listed = try? await ApelinService.app.agentAccountsWithKnownModels(),
                  !Task.isCancelled, self.chat?.id == id
            else { return }
            let accounts = EnabledModels.accounts(from: listed)
            if let current = ComposerModelSelection.selection(for: id) {
                if let account = accounts.first(where: { account in
                    account.provider == current.provider && (account.models ?? []).contains(current.model)
                }) {
                    let refreshed = Self.selection(of: current.model, in: account)
                    if refreshed.supportedEfforts != current.supportedEfforts
                        || refreshed.supportedTiers != current.supportedTiers
                    {
                        ComposerModelSelection.choose(refreshed, for: id)
                    }
                    return
                }
                if listed.contains(where: { $0.provider == current.provider && $0.signedIn && $0.models == nil }) {
                    return
                }
            }
            guard let account = accounts.first, let model = account.models?.first else { return }
            ComposerModelSelection.choose(Self.selection(of: model, in: account), for: id)
        }
    }

    /// The runtime put `id`'s draft back, or emptied it: a message its run
    /// never took, a send that failed, or a returned one the host had taken.
    func restoreDraft(for id: UUID) {
        guard chat?.id == id, let draft = runtime.records[id]?.draft else { return }
        composer.restore(draft: draft)
    }

    /// A stopped run's queued messages went back to `id`'s composer: the
    /// reader is told when they next see the conversation, now if they do.
    func unsentReturned(_ returned: DroppedMessages.Returned, to id: UUID) {
        let earlier = unsent[id] ?? (0, 0)
        unsent[id] = (earlier.messages + returned.messages, earlier.attachmentsLeftOut + returned.attachmentsLeftOut)
        sayUnsent()
    }

    /// Says what went back to the composer of the conversation on screen,
    /// spoken too: nothing else marks it.
    @objc private func sayUnsent() {
        guard let chat, view.window != nil, UIApplication.shared.applicationState == .active,
              let returned = unsent.removeValue(forKey: chat.id)
        else { return }
        let title = String(localized: "\(returned.messages) Messages Not Sent")
        let message = returned.attachmentsLeftOut > 0
            ? String(localized: "\(returned.attachmentsLeftOut) attachments could not be put back")
            : String(localized: "Back in the input box")
        SPIndicator.present(title: title, message: message, preset: .error, haptic: .warning)
        UIAccessibility.post(notification: .announcement, argument: [title, message].joined(separator: ", "))
    }

    /// The keyboard up in the composer, now if the page is on screen, else
    /// once it is: a link's prompt waits there for the reader's Send.
    func beginTyping() {
        guard view.window != nil else {
            typesOnAppear = true
            return
        }
        composer.beginEditing()
    }

    /// `text` as the reader's next message, as if typed and sent; during a
    /// reply, the run takes it at its next step.
    func sendPrompt(_ text: String) {
        guard chat != nil else { return }
        onComposerSubmit(draft: ComposerDraft(text: text)) {}
    }
}

extension ChatController: ComposerCommandContext {
    func compactConversation() {
        guard let chat else { return }
        ChatActions.askToCompact(for: chat.id, runtime: runtime, from: self)
    }

    func showUsage() {
        guard let chat else { return }
        guard let usage = runtime.transcript(chat.id).contextUsage else {
            presentNotice(
                title: "No Usage Yet",
                message: "This conversation has not made a request yet.",
            )
            return
        }
        let percent = usage.percentText
        // The figure is a value the catalogue cannot hold, so it goes in as one
        // already-formed sentence.
        presentNotice(
            title: "Context Usage",
            message: "\(usage.tokens.formatted()) of \(usage.window.formatted()) tokens used (\(percent)).",
        )
    }

    func send(prompt: String) {
        sendPrompt(prompt)
    }

    func fillComposer(with text: String) {
        var draft = composer.draft
        draft.text = text
        composer.restore(draft: draft)
        composer.publishNewEditorStatus()
        composer.beginEditing()
    }
}

extension ChatController: ComposerView.Delegate {
    func onComposerSubmit(draft: ComposerDraft, completion: @escaping @MainActor () -> Void) {
        guard let chat else {
            completion()
            return
        }
        ConversationNotices.shared.requestAuthorizationIfNeeded()
        // shown at once; the runtime puts the draft back if the send fails
        let sending = runtime.submit(draft, to: chat.id)
        // One a running turn takes later starts no turn yet: shown once.
        if let row = messages.last, row.id == draft.id, row.isQueued {
            revealLatestMessage()
        }
        Task {
            defer { completion() }
            do {
                try await sending.value
            } catch {
                presentNotice(title: "Unable to Send Message", message: error.readableMessage)
            }
        }
    }

    func onComposerSendTapped() {
        // The row under the draft has no draft of its own: it asks the
        // composer to send what is there, which is the one path a keyboard's
        // Send takes too.
        composer.submitValues()
    }

    func onComposerStopTapped() {
        guard let chat else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await runtime.stop(chat.id) }
            catch { presentNotice(title: "Unable to Stop", message: error.readableMessage) }
        }
    }

    func onComposerModelPickerTapped() {
        presentModelSheet()
    }

    func onComposerBeginEditing() {
        ensureModelSelection()
        loadSkillsIfNeeded()
    }

    func onComposerRewriteRequested(draft: String) {
        rewriteTask?.cancel()
        // Nothing chosen is nothing to rewrite with: said here rather than
        // after a request the worker would refuse.
        let selection = Preferences.DefaultModels.selection(for: .promptRewrite)
            ?? chat.flatMap { ComposerModelSelection.selection(for: $0.id) }.map {
                Preferences.DefaultModelSelection(provider: $0.provider, model: $0.model)
            }
        guard let selection = selection else {
            presentNotice(
                title: "Unable to Rewrite",
                message: String(localized: "Choose a model before rewriting."),
            )
            return
        }
        composer.setRewriting(true)
        rewriteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await ApelinService.app.agentRewritePrompt(
                    text: draft,
                    provider: selection.provider,
                    model: selection.model,
                )
                try Task.checkCancellation()
                composer.applyRewrite(original: draft, rewritten: answer.text)
            } catch is CancellationError {
                composer.rewriteFailed()
            } catch {
                composer.rewriteFailed()
                // A rewrite stopped because its draft went out is not a
                // failure to report: the message it belonged to has already
                // been sent.
                guard !Task.isCancelled else { return }
                presentNotice(title: "Unable to Rewrite", message: error.readableMessage)
            }
        }
    }

    func onComposerRewriteCancelled() {
        rewriteTask?.cancel()
        rewriteTask = nil
        composer.rewriteFailed()
    }

    func onComposerExpandTapped() {
        let editor = ComposerFullScreenEditor(
            text: composer.draft.text,
            placeholderText: String(localized: "Ask anything"),
        ) { [weak self] text in
            guard let self, self.composer.draft.text != text else { return }
            // Written back through the composer so the draft it reports is the
            // one that was typed on the page.
            var draft = self.composer.draft
            draft.text = text
            self.composer.restore(draft: draft)
            self.composer.publishNewEditorStatus()
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
    }

    func onComposerUpdateDraft(_ draft: ComposerDraft) {
        guard let chat else { return }
        runtime.saveDraft(draft, for: chat.id)
    }

    func onComposerCameraTapped() {
        importer()?.camera()
    }

    func onComposerPhotoTapped() {
        importer()?.photos()
    }

    func onComposerFileTapped() {
        importer()?.files()
    }

    func onComposerWebTapped() {
        importer()?.web()
    }

    func onComposerPasteAsAttachmentTapped() {
        importer()?.paste()
    }

    func onComposerPastedLongText(_ text: String) {
        importer()?.importText(text)
    }

    func onComposerPastedImage(_ image: UIImage) {
        importer()?.importImage(image)
    }

    func onComposerDropped(_ providers: [NSItemProvider]) {
        importer()?.drop(providers)
    }

    func onComposerPreviewAttachment(_ attachment: ComposerAttachment) {
        do { try present(ComposerAttachmentPreview(attachment: attachment), animated: true) }
        catch { presentNotice(title: "Unable to Preview Attachment", message: error.readableMessage) }
    }

    /// The skills the agent offers, fetched once and handed to the command
    /// menu. Read when the composer is first touched rather than at launch:
    /// a reader who never types never pays for it.
    private func loadSkillsIfNeeded() {
        guard !skillsLoaded, !skillsLoading else { return }
        skillsLoading = true
        Task { [weak self] in
            defer {
                self?.skillsLoading = false
                self?.skillsLoaded = true
            }
            guard let self else { return }
            do {
                let listing = try await ApelinService.app.agentSkillList()
                composer.setSkills(listing.skills)
            } catch {
                // No skills is a usable composer: the actions still run.
                composer.setSkills([])
            }
        }
    }

    private func importer() -> ComposerAttachmentImport? {
        guard let chat, presentedViewController == nil else { return nil }
        let draftID = composer.draft.id
        let importer = ComposerAttachmentImport(presenter: self) { [weak self] item in
            guard let self else { return }
            if self.chat?.id == chat.id, composer.draft.id == draftID {
                composer.insertAttachment(item)
            } else if var draft = runtime.records[chat.id]?.draft, draft.id == draftID {
                draft.attachments.append(item)
                runtime.saveDraft(draft, for: chat.id)
            }
        }
        attachmentImport = importer
        return importer
    }
}

extension ChatController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_: UIScrollView) {
        holdsLatestMessage = false
        readingPlace = nil
        // The reader has the list: only the next turn is followed again.
        followedTurn = nil
        setComposerFaded(true)
        messageRuler.listMoved(true)
    }

    func scrollViewWillBeginDecelerating(_: UIScrollView) {
        setComposerFaded(true)
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            setComposerFaded(false)
            messageRuler.listMoved(false)
            resumeFollowingAtLatest()
        }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        setComposerFaded(false)
        messageRuler.listMoved(false)
        resumeFollowingAtLatest()
    }

    /// Back at the latest message with the run still going: the list follows
    /// it again, as it did before the reader scrolled away.
    private func resumeFollowingAtLatest() {
        guard followedTurn == nil, chat?.isWorking == true, distanceFromLatestMessage <= 2 else { return }
        followedTurn = turnMessage
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        setComposerFaded(false)
    }

    /// What is typed fades while the list moves under it, as aimini's input bar
    /// does: a reader scrolling the transcript reads the transcript, and the
    /// card comes back the moment the list stops. Never hidden, only quiet, so
    /// a tap on it still lands.
    private func setComposerFaded(_ faded: Bool) {
        let alpha: CGFloat = faded ? 0.75 : 1
        guard abs(composer.alpha - alpha) > 0.001 else { return }
        guard !UIAccessibility.isReduceMotionEnabled else {
            composer.alpha = alpha
            return
        }
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
        ) {
            self.composer.alpha = alpha
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !scrollView.isTracking, !scrollView.isDecelerating {
            holdLatestMessage()
        }
        updateLatestMessageButton()
        if messageRuler.alpha > 0 {
            messageRuler.setCurrent(rulerIndexAtTop())
        }
        loadEarlierHistoryIfNeeded()
    }

    /// At the top of what is shown, with the conversation holding earlier
    /// turns: another page of them is folded in. The row the reader was
    /// reading stays at the top, so the page grows above them rather than
    /// moving what they see.
    private func loadEarlierHistoryIfNeeded() {
        let top = messageList.minimumContentOffset.y
        // Reading again, away from where a page ends: the next return to the
        // top may load another.
        if messageList.contentOffset.y > top + 240 {
            holdsHistoryTop = false
        }
        guard !isLoadingEarlierHistory, !holdsHistoryTop, let chat else { return }
        guard runtime.hasEarlierHistory(chat.id) else { return }
        guard messageList.contentOffset.y <= top + 120 else { return }
        guard let first = messageList.indicesForVisibleRows.sorted().first,
              messageList.content.indices.contains(first) else { return }
        let anchor = messageList.content[first].id
        isLoadingEarlierHistory = true
        holdsHistoryTop = true
        defer { isLoadingEarlierHistory = false }
        guard runtime.loadEarlierHistory(chat.id) else { return }
        updateMessages(runtime.transcript(chat.id).messages)
        messageList.scrollToRow(with: anchor, at: .top, animated: false)
    }

    private func holdLatestMessage() {
        guard holdsLatestMessage, !messageList.isTracking, !messageList.isDecelerating,
              distanceFromLatestMessage > 0.5 else { return }
        if UIView.inheritedAnimationDuration > 0 {
            // inside the sidebar's animation, which ListView leaves to the
            // host when the offset is set directly
            messageList.contentOffset = messageList.maximumContentOffset
        } else {
            messageList.scrollToBottom(animated: false)
        }
    }

    /// A page of earlier turns is being folded in: the scroll that follows is
    /// ours, and must not ask for another page.
    private var isLoadingEarlierHistory = false
    /// A page was loaded at the top, and the reader has not left it yet: the
    /// next page is asked for when they come back up, not at once.
    private var holdsHistoryTop = false
    /// The rail's entries whose messages the list is showing, in order: what
    /// the top of the page can be read against.
    private var loadedRulerIndices: [Int] = []
    private var distanceFromLatestMessage: CGFloat {
        max(0, messageList.maximumContentOffset.y - messageList.contentOffset.y)
    }

    private func updateLatestMessageButton() {
        let alpha: CGFloat = followedTurn == nil && distanceFromLatestMessage > 2 ? 1 : 0
        guard latestMessageButton.alpha != alpha else { return }
        if alpha > 0 {
            latestMessageButton.isHidden = false
        }
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
        ) {
            self.latestMessageButton.alpha = alpha
        } completion: { _ in
            self.latestMessageButton.isHidden = self.latestMessageButton.alpha == 0
        }
    }
}

extension ChatController: UIGestureRecognizerDelegate {
    /// A tap that lands on the composer is the composer's: its field, its
    /// buttons and the panels it opens over them keep the keyboard they
    /// asked for.
    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touched = touch.view else { return true }
        return !(touched === composer || touched.isDescendant(of: composer))
    }
}

/// A message's own actions: Copy, Checkpoint & Rewind, and More's edit,
/// copy, fork and delete. Each change goes to the conversation's session,
/// whose event then shows it; one it refuses is said as it said it.
extension ChatController {
    /// The message as the page shows it now, the row's copy being older.
    private func shownMessage(_ id: UUID) -> ChatMessage? {
        messages.first { $0.id == id }
    }

    fileprivate func copyText(of message: ChatMessage) {
        UIPasteboard.general.string = shownMessage(message.id)?.text ?? message.text
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
    }

    /// What a sheet shows of the message it acts on.
    private func preview(of message: ChatMessage) -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(localized: "Attachment") : String(text.prefix(300))
    }

    // MARK: Checkpoint & Rewind

    fileprivate func presentRewind(for id: UUID) {
        guard let chat, let message = shownMessage(id), let messageID = message.turnMessageID else { return }
        let saved = message.hasCheckpoint && chat.projectName != nil
        let noCode = String(localized: "No code was saved before this message.")
        let sheet = MessageActionSheet(title: String(localized: "Checkpoint & Rewind"), preview: preview(of: message), actions: [
            MessageActionSheet.Action(
                title: String(localized: "Restore Code and Conversation"),
                subtitle: saved ? String(localized: "Puts the code and the chat back to before this message.") : noCode,
                symbol: "arrow.counterclockwise",
                enabled: saved,
            ) { [weak self] in self?.confirmRestore(message, messageID: messageID, conversation: true) },
            MessageActionSheet.Action(
                title: String(localized: "Restore Conversation Only"),
                subtitle: String(localized: "Keeps the code as it is and takes the chat back to before this message."),
                symbol: "text.bubble",
            ) { [weak self] in self?.restoreConversation(message, messageID: messageID) },
            MessageActionSheet.Action(
                title: String(localized: "Restore Code Only"),
                subtitle: saved ? String(localized: "Puts the code back to before this message and keeps the chat.") : noCode,
                symbol: "chevron.left.forwardslash.chevron.right",
                enabled: saved,
            ) { [weak self] in self?.confirmRestore(message, messageID: messageID, conversation: false) },
        ])
        MessageActionSheet.present(sheet, from: self)
    }

    /// Putting code back changes files on disk: asked first.
    private func confirmRestore(_ message: ChatMessage, messageID: UUID, conversation: Bool) {
        presentConfirmation(
            title: "Restore Code?",
            message: "The project's files go back to how they were before this message. What they hold now is saved on a backup branch first.",
            confirmTitle: "Restore",
            destructive: true,
        ) { [weak self] in
            self?.restore(message, messageID: messageID, conversation: conversation)
        }
    }

    private func restore(_ message: ChatMessage, messageID: UUID, conversation: Bool) {
        guard let chat else { return }
        let chatID = chat.id
        Task {
            do {
                if conversation {
                    try await runtime.rewind(messageID, in: chatID, truncate: true)
                }
                let restored = try await runtime.restoreCode(before: messageID, in: chatID)
                if conversation {
                    refillComposer(with: message, in: chatID)
                }
                if let branch = restored.backupBranch {
                    SPIndicator.present(
                        title: String(localized: "Code Restored"),
                        message: String(localized: "Saved what was there on the branch \(branch) first."),
                        preset: .done,
                        haptic: .success,
                    )
                } else {
                    SPIndicator.present(
                        title: String(localized: "Nothing to Restore"),
                        message: String(localized: "The code is already as it was before this message."),
                        preset: .done,
                        haptic: .success,
                    )
                }
            } catch {
                presentNotice(title: "Unable to Restore", message: error.readableMessage)
            }
        }
    }

    private func restoreConversation(_ message: ChatMessage, messageID: UUID) {
        guard let chat else { return }
        let chatID = chat.id
        Task {
            do {
                try await runtime.rewind(messageID, in: chatID, truncate: true)
                refillComposer(with: message, in: chatID)
            } catch {
                presentNotice(title: "Unable to Restore", message: error.readableMessage)
            }
        }
    }

    /// The message taken back goes into the composer again, to send as it
    /// was or changed: under a new id, since the session has seen its own.
    private func refillComposer(with message: ChatMessage, in chatID: UUID) {
        let draft = ComposerDraft(text: message.text, attachments: message.attachments)
        runtime.saveDraft(draft, for: chatID)
        guard chat?.id == chatID else { return }
        composer.restore(draft: draft)
        composer.beginEditing()
    }

    // MARK: More

    /// The to-do panel's ✕: asked first, since the agent's list stays and a
    /// new one brings the panel back.
    private func confirmHideTodoList() {
        guard let chat, let sessionID = runtime.records[chat.id]?.sessionID else { return }
        let list = TodoStore(root: DataFolder.app.root).list(for: sessionID)
        guard !list.items.isEmpty else { return }
        presentConfirmation(
            title: "Hide To-Do List?",
            message: "The list leaves this chat until the agent writes a new one. The agent keeps its own copy.",
            confirmTitle: "Hide",
        ) { [weak self] in
            TodoListHiding.hide(list, for: sessionID)
            self?.refreshRuntime()
        }
    }

    fileprivate func presentMessageMenu(for id: UUID) {
        guard let chat, let message = shownMessage(id), let messageID = message.turnMessageID else { return }
        let reply = message.role != .user
        let busy = chat.isWorking
        var actions: [MessageActionSheet.Action] = []
        if !busy {
            actions.append(MessageActionSheet.Action(
                title: String(localized: "Edit Message"),
                symbol: "pencil",
            ) { [weak self] in self?.editMessage(message, messageID: messageID, reply: reply) })
        }
        if !message.text.isEmpty {
            actions.append(MessageActionSheet.Action(
                title: String(localized: "Copy Text"),
                symbol: "doc.on.doc",
            ) { [weak self] in self?.copyText(of: message) })
        }
        if runtime.canFork(chat.id) {
            actions.append(MessageActionSheet.Action(
                title: String(localized: "Fork from Here"),
                symbol: "arrow.triangle.branch",
            ) { [weak self] in self?.fork(through: messageID) })
        }
        if !busy {
            actions.append(MessageActionSheet.Action(
                title: String(localized: "Delete Message"),
                symbol: "trash",
                destructive: true,
            ) { [weak self] in self?.confirmDelete(message, messageID: messageID, reply: reply) })
        }
        guard !actions.isEmpty else { return }
        let sheet = MessageActionSheet(title: String(localized: "More"), preview: preview(of: message), actions: actions)
        MessageActionSheet.present(sheet, from: self)
    }

    private func editMessage(_ message: ChatMessage, messageID: UUID, reply: Bool) {
        let sheet = EditMessageSheet(title: String(localized: "Edit Message"), text: message.text) { [weak self] text in
            self?.saveEdit(text, of: message, messageID: messageID, reply: reply)
        }
        EditMessageSheet.present(sheet, from: self)
    }

    private func saveEdit(_ text: String, of message: ChatMessage, messageID: UUID, reply: Bool) {
        guard let chat else { return }
        let chatID = chat.id
        Task {
            do {
                try await runtime.edit(messageID, in: chatID, reply: reply, text: text, expected: reply ? message.text : nil)
            } catch {
                presentNotice(title: "Unable to Edit", message: error.readableMessage)
            }
        }
    }

    private func fork(through messageID: UUID) {
        guard let chat else { return }
        let chatID = chat.id
        Task {
            do {
                if let forked = try await runtime.fork(chatID, through: messageID) {
                    onOpenChat?(forked)
                }
            } catch {
                presentNotice(title: "Unable to Fork", message: error.readableMessage)
            }
        }
    }

    private func confirmDelete(_ message: ChatMessage, messageID: UUID, reply: Bool) {
        if reply {
            presentConfirmation(
                title: "Delete Reply?",
                message: "This reply leaves the chat. The rest of the chat stays.",
                confirmTitle: "Delete",
                destructive: true,
            ) { [weak self] in
                self?.deleteFromChat(message, messageID: messageID, reply: true)
            }
        } else {
            presentConfirmation(
                title: "Delete Message?",
                message: "This message and everything after it leave the chat. The code stays as it is.",
                confirmTitle: "Delete",
                destructive: true,
            ) { [weak self] in
                self?.deleteFromChat(message, messageID: messageID, reply: false)
            }
        }
    }

    /// A reply goes alone; a message of the reader's takes what follows it.
    private func deleteFromChat(_ message: ChatMessage, messageID: UUID, reply: Bool) {
        guard let chat else { return }
        let chatID = chat.id
        Task {
            do {
                if reply {
                    try await runtime.deleteReply(of: messageID, in: chatID, expected: message.text)
                } else {
                    try await runtime.rewind(messageID, in: chatID, truncate: true)
                }
            } catch {
                presentNotice(title: "Unable to Delete", message: error.readableMessage)
            }
        }
    }
}

/// The ruler of the reader's messages (`ChatMessageRuler`) and the VoiceOver
/// rotor that reaches the same messages.
extension ChatController {
    private func updateMessageRuler(_ rows: [ChatMessage]) {
        // The rail covers the whole conversation, not only the turns folded
        // in: its entries come from the record, and one whose message the page
        // has not loaded is folded in when the rail picks it.
        let fromRecord = chat.map { runtime.promptRows(of: $0.id) } ?? []
        let entries = fromRecord.isEmpty
            ? rows
                .filter { $0.role == .user && !$0.isQueued }
                .map { ChatMessageRuler.Entry(id: $0.id, text: $0.text, sentAt: $0.sentAt) }
            : fromRecord
        if entries != messageRuler.entries {
            messageRuler.show(entries)
        }
        // Which of them the list is showing: a rail cannot be drawn from a
        // row the page has not folded in.
        let loaded = Set(rows.map(\.id))
        loadedRulerIndices = entries.indices.filter { loaded.contains(entries[$0].id) }
        // The ruler is the list's indicator once it has two messages to move
        // between; with fewer, the system's stays.
        let systemIndicator = entries.count < 2
        if messageList.showsVerticalScrollIndicator != systemIndicator {
            messageList.showsVerticalScrollIndicator = systemIndicator
        }
        if messageRuler.alpha > 0 {
            messageRuler.setCurrent(rulerIndexAtTop())
        }
    }

    /// At the list's trailing edge, from under the bar's blur to above the
    /// composer.
    private func layoutMessageRuler() {
        if rulerVeil.frame != view.bounds {
            rulerVeil.frame = view.bounds
        }
        let list = messageList.frame
        let top = max(topBlur.frame.maxY, view.safeAreaInsets.top) + 8
        let bottom = composer.frame.minY - 12
        let width = ChatMessageRuler.width
        let x = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? list.minX : list.maxX - width
        let frame = CGRect(x: x, y: top, width: width, height: max(0, bottom - top))
        if messageRuler.frame != frame {
            messageRuler.frame = frame
        }
    }

    /// The last of the reader's messages whose top is at or above the top of
    /// the page: the one being read under.
    private func rulerIndexAtTop() -> Int {
        let entries = messageRuler.entries
        guard !loadedRulerIndices.isEmpty else { return 0 }
        let line = messageList.contentOffset.y + max(messageList.adjustedContentInset.top, topBlur.frame.maxY) + 1
        // The rows are in order, so their tops are too; only the ones the list
        // holds can be asked where they are.
        var low = 0
        var high = loadedRulerIndices.count - 1
        var found = loadedRulerIndices[0]
        while low <= high {
            let middle = (low + high) / 2
            let entry = loadedRulerIndices[middle]
            if messageList.rectForRow(with: entries[entry].id).minY <= line {
                found = entry
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    /// A drag on the ruler takes the list from the reader as a drag on it
    /// would: whatever it was following, it stops following, and a fling
    /// still moving stops where it is.
    private func beginRulerScrub() {
        holdsLatestMessage = false
        readingPlace = nil
        followedTurn = nil
        messageList.setContentOffset(messageList.contentOffset, animated: false)
        setComposerFaded(true)
        setRulerVeil(true)
    }

    /// The page softens while the rail is held, and comes back on lift with the
    /// card: only the rail and its card are above the veil.
    private func setRulerVeil(_ shown: Bool) {
        let alpha: CGFloat = shown ? 1 : 0
        guard !UIAccessibility.isReduceMotionEnabled else {
            // Nothing to animate: drop whatever is running and put it there.
            rulerVeil.layer.removeAllAnimations()
            rulerVeil.alpha = alpha
            rulerVeil.isHidden = !shown
            return
        }
        UIView.animate(
            withDuration: shown ? 0.14 : 0.22,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                self.rulerVeil.isHidden = false
                self.rulerVeil.alpha = alpha
            },
        ) { _ in
            self.rulerVeil.isHidden = self.rulerVeil.alpha == 0
        }
    }

    /// Puts entry `index` at the top of the page, under the bar's blur. While
    /// the finger moves it jumps; once it lifts, the list settles there, with
    /// the rows on the way measured, since a row not yet shown was placed by
    /// an estimate.
    private func showRulerEntry(_ index: Int, loadsHistory: Bool = true) {
        let entries = messageRuler.entries
        guard entries.indices.contains(index) else { return }
        let id = entries[index].id
        // A message the page is not showing — the rail reaches the whole
        // conversation — is folded in first, in one fold rather than a page
        // at a time. Only once the finger is off the rail: a drag across a
        // long conversation would otherwise fold a page per message it passes.
        if loadsHistory, !loadedRulerIndices.contains(index), let chat,
           runtime.showHistory(chat.id, from: id)
        {
            updateMessages(runtime.transcript(chat.id).messages)
        }
        let topLine = max(messageList.adjustedContentInset.top, topBlur.frame.maxY) + 8
        func target() -> CGPoint {
            let row = messageList.rectForRow(with: id)
            let y = min(max(row.minY - topLine, messageList.minimumContentOffset.y), messageList.maximumContentOffset.y)
            return CGPoint(x: messageList.contentOffset.x, y: y)
        }
        messageList.setContentOffset(target(), animated: false)
        messageList.layoutIfNeeded()
        // Measured on arrival, the row may have moved: once more puts it in place.
        messageList.setContentOffset(target(), animated: false)
        updateLatestMessageButton()
    }

    /// "Your Messages": VoiceOver steps from one of the reader's messages to
    /// the next, the way the ruler does for a finger.
    private func yourMessagesRotor() -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(name: String(localized: "Your Messages")) { [weak self] predicate in
            guard let self else { return nil }
            let entries = messageRuler.entries
            guard !entries.isEmpty else { return nil }
            let forward = predicate.searchDirection == .next
            let start: Int
            if let element = predicate.currentItem.targetElement as? UIView,
               let at = entries.firstIndex(where: { (self.messageList.rowView(for: $0.id) as? ChatMessageRow)?.spokenElement === element })
            {
                start = forward ? at + 1 : at - 1
            } else {
                let top = rulerIndexAtTop()
                start = forward ? top : top - 1
            }
            guard entries.indices.contains(start) else { return nil }
            showRulerEntry(start)
            messageList.layoutIfNeeded()
            guard let row = messageList.rowView(for: entries[start].id) as? ChatMessageRow else { return nil }
            return UIAccessibilityCustomRotorItemResult(targetElement: row.spokenElement, targetRange: nil)
        }
    }
}

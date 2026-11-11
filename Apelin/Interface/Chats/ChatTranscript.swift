import ApelinCore
import ApelinProtocol
import CryptoKit
import Foundation

/// Rebuilds visible rows from ordered host events. Rebuilding from the same
/// events gives the same row IDs.
///
/// A fold: the events are read once, in order, into rows that `append`
/// carries on from, and the rows shown are made from those afresh each
/// time. Events read in batches and shown at a `now` give what a transcript
/// built from all of them at once, at that `now`, would.
struct ChatTranscript {
    var messages: [ChatMessage] = []
    var isWorking = false
    /// Compacting between runs, as the app asked (`agentCompact`).
    var isCompacting = false
    /// How full the conversation's context is, from the last `contextUsage`
    /// the agent recorded: the figure the ring beside the composer shows.
    var contextUsage: ChatContextUsage?
    /// The run mode the agent last changed this conversation to itself
    /// (`apelin_run_mode`): the page writes it where the pill reads it, so a
    /// change made while the app was away is not lost.
    var runMode: ComposerMode?
    var approvalIDs: [UUID: String] = [:]
    /// While the turn runs and its last row is a reply with nothing after
    /// it: when, with no event before then, a running summary stands in
    /// under the reply. Nil once it does, and whenever nothing would.
    private(set) var quietDeadline: Date?
    /// How many events it has read.
    private(set) var eventCount = 0
    /// How long a running turn goes without an event before a summary
    /// stands in under its reply: the model may be writing a call it has
    /// not announced yet, or the provider has stalled.
    static let quietInterval: TimeInterval = 1.5
    /// The rows the events have made, before the thoughts, calls and
    /// approvals between two replies are folded into their summary.
    private var rows: [ChatMessage] = []
    /// Where each id's first row is among `rows`, so a message or a decision
    /// finds its row without reading every row before it.
    private var firstRows: [UUID: Int] = [:]
    /// Sent during a run and not taken by it yet: shown after everything
    /// else until the run takes them, then in place like any message.
    private var queued: [ChatMessage] = []
    private var lastEventTime: Date?
    private var thinking: Int?
    private var thinkingStarted: Date?
    private var assistant: Int?
    private var toolRows: [String: Int] = [:]
    /// The reason the agent gave each call (`ToolReason`), by call ID: what
    /// an approval card says first.
    private var callReasons: [String: String] = [:]
    /// The row the turn has shown nothing after yet: its prompt, or images a
    /// tool returned. A running summary stands in under it, under the id the
    /// next thought takes, so the one becomes the other with no gap.
    private var unanswered: UUID?
    /// The run's output so far, from its latest `received`.
    private var receivedTokens: Int?
    private var processingSource: String?
    /// Each turn the events started, in order: from a `prompt` to the next
    /// one or to its run's end, with what its replies cost.
    private var turns: [Turn] = []

    private struct Turn {
        /// Where its message is among `rows`.
        var start: Int
        /// The message's own id, when it has one.
        var messageID: UUID?
        var began: Date
        var ended: Date?
        var stats = ChatTurnStats()
    }
    /// Where the message streaming now began among `rows`, and the row it
    /// answered then, from its `messageStarted` until anything but its
    /// stream comes: a `messageDiscarded` (kwwk asks for it again) takes
    /// back what it showed, so the reply that follows is not drawn twice.
    private var attempt: (rows: Int, unanswered: UUID?)?
    /// A model request failed and is being made again, and nothing has
    /// come of it yet (`reconnecting`): the running summary says so.
    private var reconnecting = false
    /// What ends `attempt`: anything but its stream, or news that may come
    /// meanwhile (a title, a message queued, the count).
    private static let endsAttempt: Set<String> = [
        "prompt", "steer", "message", "toolCall", "toolResult", "approvalRequested", "approvalResolved",
        "error", "finished", "compactionStarted", "compactionFinished", TaskEvent.stateKind,
    ]
    /// What ends `reconnecting`: the request answered, or the run moved on.
    private static let endsReconnecting = endsAttempt.union(["messageStarted", "thinking", "toolCallPreparing", "text"])

    /// `conversationTitle` names another conversation of the project by its
    /// session ID, for a message its agent sent. `sending` are messages sent
    /// and not echoed yet: each shows last, under its draft's id, until the
    /// host's `prompt` or `queued` event with that id takes its place.
    /// `now` judges whether a running turn has been quiet for
    /// `quietInterval`; without it no summary stands in for the quiet.
    init(
        events: [TaskEvent],
        sending: [ComposerDraft] = [],
        conversationTitle: (String) -> String? = { _ in nil },
        now: Date? = nil,
        attachment: (AgentAttachment) -> ComposerAttachment?,
    ) {
        append(events, sending: sending, conversationTitle: conversationTitle, now: now, attachment: attachment)
    }

    /// Reads `events`, the ones that follow those read so far, and shows the
    /// rows again with `sending` and at `now`, as `init` describes them; an
    /// empty `events` only shows them again.
    mutating func append(
        _ events: some Collection<TaskEvent>,
        sending: [ComposerDraft] = [],
        conversationTitle: (String) -> String? = { _ in nil },
        now: Date? = nil,
        attachment: (AgentAttachment) -> ComposerAttachment?,
    ) {
        // By position: a reopened session's events go on after the earlier
        // task's under a numbering that starts again (`ChatRecord.reopen`).
        for (index, event) in zip(eventCount..., events) {
            // A conversation read back — a fork's whole history, or a
            // session reopened — is relayed in one burst, so the host's stamp
            // says when it was replayed rather than when it happened: `at`
            // carries the log's own time, and the turn's length with it.
            var event = event
            if let at = event.payload?["at"]?.doubleValue {
                event.time = Date(timeIntervalSince1970: at)
            }
            let payload = event.payload
            let text = payload?["text"]?.stringValue ?? ""
            let id = Self.rowID("event:\(index)")
            lastEventTime = event.time
            if Self.endsAttempt.contains(event.kind) {
                attempt = nil
            }
            if Self.endsReconnecting.contains(event.kind) {
                reconnecting = false
            }
            switch event.kind {
            case "prompt", "steer":
                finishThinking(at: event.time)
                assistant = nil
                let messageID = Self.userMessageID(of: event) ?? id
                processingSource = payload?["from"]?.stringValue.map { Self.processingLine(conversationTitle($0)) }
                let files = Self.attachments(in: payload?["attachments"])
                queued.removeAll { $0.id == messageID }
                if firstRows[messageID] == nil {
                    var message = ChatMessage(
                        id: messageID,
                        role: .user,
                        text: text,
                        attachments: files.compactMap(attachment),
                    )
                    message.sender = payload?["from"]?.stringValue.map { Self.senderLine(conversationTitle($0)) }
                    message.sentAt = event.time
                    if event.kind == "prompt" {
                        let named = payload?["from"]?.stringValue == nil ? Self.userMessageID(of: event) : nil
                        message.turnMessageID = named
                        endTurn(at: event.time)
                        turns.append(Turn(start: rows.count, messageID: named, began: event.time))
                    }
                    add(message)
                }
                unanswered = messageID
                isWorking = true
            case "queued":
                guard let messageID = Self.userMessageID(of: event),
                      firstRows[messageID] == nil, !queued.contains(where: { $0.id == messageID })
                else { break }
                let files = Self.attachments(in: payload?["attachments"])
                var message = ChatMessage(
                    id: messageID,
                    role: .user,
                    text: text,
                    attachments: files.compactMap(attachment),
                )
                message.isQueued = true
                message.sender = payload?["from"]?.stringValue.map { Self.senderLine(conversationTitle($0)) }
                queued.append(message)
            case "queueDropped":
                let ids = Self.identifiers(in: payload?["ids"])
                queued.removeAll { ids.contains($0.id) }
            case "messageStarted":
                assistant = nil
                finishThinking(at: event.time)
                attempt = (rows.count, unanswered)
                startThinking(id: id, at: event.time)
                isWorking = true
            case "messageDiscarded":
                // The rows it made go, and what it answered is unanswered
                // again: the stand-in its thought replaced comes back, and
                // the next attempt's thought takes its id once more.
                guard let attempt else { break }
                rows.removeSubrange(attempt.rows...)
                firstRows = firstRows.filter { $0.value < attempt.rows }
                thinking = nil
                thinkingStarted = nil
                assistant = nil
                unanswered = attempt.unanswered
                self.attempt = nil
            case "reconnecting":
                reconnecting = true
            case "thinking":
                if thinking == nil {
                    startThinking(id: id, at: event.time)
                }
                if let thinking {
                    rows[thinking].text += text
                }
            case "toolCallPreparing":
                // The call shows only once its arguments are whole, so the
                // summary runs meanwhile. The message keeps its one text
                // row: its full text still comes in `message`.
                if thinking == nil {
                    startThinking(id: id, at: event.time)
                }
            case "text", "message":
                finishThinking(at: event.time)
                guard !text.isEmpty else { break }
                unanswered = nil
                if assistant == nil {
                    assistant = rows.count
                    var reply = ChatMessage(id: id, role: .assistant, text: "")
                    reply.isReply = true
                    reply.turnMessageID = turns.last?.messageID
                    add(reply)
                }
                if let assistant {
                    if event.kind == "message" {
                        rows[assistant].text = text
                    } else {
                        rows[assistant].text += text
                    }
                }
            case "toolCall":
                // A call no thought announced heads its summary from where
                // a summary standing in under the last row was.
                if thinking == nil, standInAnchor != nil {
                    startThinking(id: id, at: event.time)
                }
                finishThinking(at: event.time)
                assistant = nil
                unanswered = nil
                if let toolID = payload?["id"]?.stringValue {
                    toolRows[toolID] = rows.count
                    let name = payload?["tool"]?.stringValue ?? ""
                    let arguments = payload?["arguments"]?.stringValue
                    var row = ChatMessage(id: id, role: .tool, text: Self.toolTitle(name, arguments: arguments))
                    row.tool = name
                    row.detail = arguments ?? ""
                    row.banner = ToolCallBanner(tool: name, arguments: arguments, title: row.text)
                    row.awaitsResult = true
                    if let reason = Self.reason(arguments) {
                        callReasons[toolID] = reason
                    }
                    add(row)
                }
            case "toolResult":
                if let toolID = payload?["id"]?.stringValue, let index = toolRows[toolID] {
                    let output = payload?["output"]?.stringValue ?? ""
                    rows[index].detail += "\n\n" + output
                    rows[index].awaitsResult = false
                    if rows[index].banner?.file != nil, payload?["isError"]?.boolValue != true {
                        rows[index].banner?.change = ToolCallBanner.lineChange(in: output)
                    }
                }
                let files = Self.attachments(in: payload?["attachments"])
                if !files.isEmpty {
                    add(ChatMessage(
                        id: id,
                        role: .assistant,
                        text: "",
                        attachments: files.compactMap(attachment),
                    ))
                    unanswered = id
                }
            case "approvalRequested":
                if let approvalID = payload?["approvalID"]?.stringValue {
                    let rowID = Self.rowID(approvalID)
                    approvalIDs[rowID] = approvalID
                    let title = ApprovalCardText.title(payload) ?? Self.toolTitle(
                        payload?["tool"]?.stringValue ?? "",
                        arguments: payload?["arguments"]?.stringValue,
                    )
                    let detail = ApprovalCardText.detail(
                        payload,
                        title: title,
                        callReason: payload?["toolCallID"]?.stringValue.flatMap { callReasons[$0] },
                    )
                    var request = ChatMessage(id: rowID, role: .approval(nil), text: title + "\n\n" + detail)
                    request.runsAsRoot = ApprovalCardText.isRoot(payload)
                    request.question = ApprovalCardText.question(payload)
                    let modeSwitch = ApprovalCardText.runModeSwitch(payload)
                    // A question's card is its options, and a mode switch's
                    // is its reason: the call's arguments, which name them
                    // again, are not shown.
                    request.approvalSections = request.question != nil || modeSwitch != nil ? [] : ApprovalCardText.sections(
                        payload, title: title,
                        callReason: payload?["toolCallID"]?.stringValue.flatMap { callReasons[$0] },
                    )
                    if let question = request.question {
                        request.text = title + "\n\n" + question.options.map(\.label).joined(separator: "\n")
                    }
                    if let modeSwitch {
                        request.text = title + "\n\n" + modeSwitch.reason
                    }
                    add(request)
                }
            case "approvalResolved":
                if let approvalID = payload?["approvalID"]?.stringValue,
                   let index = firstRows[Self.rowID(approvalID)]
                {
                    rows[index].role = .approval(payload?["decision"]?.stringValue == "approve" ? .approve : .deny)
                }
            case "error":
                // Also the sessions that recorded a whole NSError before the agent cut it.
                let message = payload?["message"]?.stringValue.map(ErrorDescription.localized)
                add(ChatMessage(id: id, role: .assistant, text: message ?? ""))
            case "received":
                receivedTokens = payload?["tokens"]?.doubleValue.map { Int($0) }
            case "contextUsage":
                // Outlives the run it was recorded in: it describes the
                // conversation, and only a compaction brings it down.
                if let usage = ChatContextUsage(payload) {
                    contextUsage = usage
                }
            case "runModeChanged":
                // The last one wins: the mode the conversation is in now.
                if let raw = payload?["mode"]?.stringValue, let mode = ComposerMode(rawValue: raw) {
                    runMode = mode
                }
            case "finished":
                finishThinking(at: event.time)
                assistant = nil
                isWorking = false
                processingSource = nil
                receivedTokens = nil
                endTurn(at: event.time)
            case "usage":
                let count = { (key: String) in payload?[key]?.doubleValue.map { Int($0) } ?? 0 }
                if !turns.isEmpty {
                    turns[turns.count - 1].stats.inputTokens += count("input")
                    turns[turns.count - 1].stats.outputTokens += count("output")
                    turns[turns.count - 1].stats.cacheReadTokens += count("cacheRead")
                    turns[turns.count - 1].stats.cacheWriteTokens += count("cacheWrite")
                }
            case "checkpoint":
                if let messageID = Self.payloadID(payload), let index = firstRows[messageID] {
                    rows[index].hasCheckpoint = true
                }
            case "messageEdited":
                if let messageID = Self.payloadID(payload), let index = firstRows[messageID], rows[index].role == .user {
                    rows[index].text = text
                }
            case "replyEdited":
                if let messageID = Self.payloadID(payload), let index = lastReply(ofTurn: messageID) {
                    rows[index].text = text
                }
            case "replyDeleted":
                if let messageID = Self.payloadID(payload), let index = lastReply(ofTurn: messageID) {
                    rows[index].isRemoved = true
                }
            case "historyRewound":
                if let messageID = Self.payloadID(payload), let index = firstRows[messageID] {
                    rewind(to: index)
                }
            case "compactionStarted":
                isCompacting = true
            case "compactionFinished":
                isCompacting = false
                if payload?["outcome"]?.stringValue == AgentCompactionResult.Outcome.compacted.rawValue {
                    // text after it is a reply of its own, under it
                    assistant = nil
                    add(ChatMessage(id: id, role: .compaction, text: payload?["summary"]?.stringValue ?? ""))
                }
            case TaskEvent.stateKind:
                if Self.endsTask(event) {
                    finishThinking(at: event.time)
                    isWorking = false
                    processingSource = nil
                    isCompacting = false
                    receivedTokens = nil
                    endTurn(at: event.time)
                }
            default: break
            }
        }
        eventCount += events.count
        show(sending: sending, now: now)
    }

    /// The rows as shown, made afresh from the fold's: what it holds and
    /// `sending` and `now` decide them, never what was shown before.
    private mutating func show(sending: [ComposerDraft], now: Date?) {
        messages = Self.presentationRows(rowsWithTurns().filter { !$0.isRemoved })
        quietDeadline = nil
        if isWorking {
            if let unanswered, messages.last?.id == unanswered {
                messages.append(Self.standIn(after: unanswered))
            } else if let reply = Self.standInAnchor(after: messages, unanswered: unanswered),
                      let last = lastEventTime
            {
                let deadline = last.addingTimeInterval(Self.quietInterval)
                if let now, now >= deadline {
                    messages.append(Self.standIn(after: reply))
                } else {
                    quietDeadline = deadline
                }
            }
            Self.keepTrailingSummaryRunning(&messages, receivedTokens: receivedTokens, reconnecting: reconnecting)
            if let summary = messages.lastIndex(where: { $0.role.isThinking }) {
                messages[summary].processingSource = processingSource
            }
        }
        // One header per turn, under the prompt that began it: the run's
        // state said once for the whole turn, never once per stretch inside
        // it. A turn that writes a reply and then works on is the same turn.
        messages = Self.withTurnHeaders(
            messages,
            running: isWorking ? turns.last?.messageID : nil,
            durations: turnDurations,
            began: turnBegan,
            now: lastEventTime ?? Date(),
        )
        messages += queued
        for draft in sending where !messages.contains(where: { $0.id == draft.id }) {
            var message = ChatMessage(id: draft.id, role: .user, text: draft.text, attachments: draft.attachments)
            // A running turn takes it at its next step, as the host will say.
            message.isQueued = isWorking
            messages.append(message)
        }
    }

    /// Adds a row to the fold's, noting where its id's first row is.
    private mutating func add(_ row: ChatMessage) {
        if firstRows[row.id] == nil {
            firstRows[row.id] = rows.count
        }
        rows.append(row)
    }

    /// How long each turn took, and when each began, by the message that
    /// began it.
    private var turnDurations: [UUID: Int] {
        var durations: [UUID: Int] = [:]
        for turn in turns {
            guard let id = turn.messageID, let ended = turn.ended else { continue }
            durations[id] = max(0, Int(ended.timeIntervalSince(turn.began).rounded()))
        }
        return durations
    }

    private var turnBegan: [UUID: Date] {
        var began: [UUID: Date] = [:]
        for turn in turns {
            guard let id = turn.messageID else { continue }
            began[id] = turn.began
        }
        return began
    }

    /// Each turn's header under the prompt that began it: the run's state,
    /// once for the whole turn, and — while it runs — what the turn has done
    /// so far. Every row the turn made is named with its id, so the page can
    /// leave the process out until the reader opens the header; a turn with
    /// nothing but its reply gets no header.
    private static func withTurnHeaders(
        _ rows: [ChatMessage],
        running: UUID?,
        durations: [UUID: Int],
        began: [UUID: Date],
        now: Date,
    ) -> [ChatMessage] {
        var result: [ChatMessage] = []
        result.reserveCapacity(rows.count + 1)
        var index = 0
        while index < rows.count {
            let row = rows[index]
            guard row.role == .user, !row.isQueued, let turnID = row.turnMessageID else {
                result.append(row)
                index += 1
                continue
            }
            let end = (index + 1 ..< rows.count).first { rows[$0].role == .user } ?? rows.count
            let range = (index + 1) ..< end
            let isRunning = running == turnID
            result.append(row)
            if isRunning || range.contains(where: { rows[$0].role.isActivity }) {
                let tools = range.count(where: { rows[$0].role == .tool })
                let seconds = isRunning
                    ? began[turnID].map { max(0, Int(now.timeIntervalSince($0).rounded())) }
                    : durations[turnID]
                var header = ChatMessage(
                    id: rowID("turn:\(turnID)"),
                    role: .turn(running: isRunning, seconds: seconds),
                    text: isRunning ? ChatMessage.workTitle(seconds: seconds ?? 0, tools: tools) : "",
                )
                header.turnMessageID = turnID
                result.append(header)
            }
            for offset in range {
                var member = rows[offset]
                member.turnMessageID = turnID
                result.append(member)
            }
            index = end
        }
        return result
    }

    /// Ends the turn still open, at `date`.
    private mutating func endTurn(at date: Date) {
        guard let last = turns.indices.last, turns[last].ended == nil else { return }
        turns[last].ended = date
    }

    /// The last reply shown in the turn of message `id`, deleted ones left out.
    private func lastReply(ofTurn id: UUID) -> Int? {
        guard let turn = turns.lastIndex(where: { $0.messageID == id }) else { return nil }
        let end = turns.indices.contains(turn + 1) ? turns[turn + 1].start : rows.count
        let range = turns[turn].start ..< min(end, rows.count)
        return range.last { rows[$0].isReply && !rows[$0].isRemoved && !rows[$0].text.isEmpty }
    }

    /// Message `rows[index]` taken back: it and every row after it go, and
    /// whatever the fold kept of them.
    private mutating func rewind(to index: Int) {
        guard index < rows.count else { return }
        rows.removeSubrange(index...)
        firstRows = firstRows.filter { $0.value < index }
        toolRows = toolRows.filter { $0.value < index }
        turns = turns.filter { $0.start < index }
        if let row = assistant, row >= index {
            assistant = nil
        }
        if let row = thinking, row >= index {
            thinking = nil
            thinkingStarted = nil
        }
        if let current = attempt, current.rows >= index {
            attempt = nil
        }
        if let row = unanswered, firstRows[row] == nil {
            unanswered = nil
        }
    }

    /// The rows with each turn's cost on its last reply, and Copy and More
    /// there too, as aimini's chat has them: on every turn that ended, and
    /// on the last one only once no run goes; until then the figures are not
    /// the turn's yet, and the reply is still being written.
    private func rowsWithTurns() -> [ChatMessage] {
        var shown = rows
        for (position, turn) in turns.enumerated() {
            guard position < turns.count - 1 || !isWorking else { continue }
            let end = turns.indices.contains(position + 1) ? turns[position + 1].start : shown.count
            let range = turn.start ..< min(end, shown.count)
            guard let reply = range.last(where: { shown[$0].isReply && !shown[$0].isRemoved }) else { continue }
            // The reply the history's changes act on: the turn's last with
            // text, as the agent finds it.
            if let target = range.last(where: { shown[$0].isReply && !shown[$0].isRemoved && !shown[$0].text.isEmpty }),
               shown[target].turnMessageID != nil
            {
                shown[target].offersActions = true
            }
            var stats = turn.stats
            stats.seconds = turn.ended.map { max(0, Int($0.timeIntervalSince(turn.began).rounded())) }
            if stats.hasTokens || stats.seconds != nil {
                shown[reply].turnStats = stats
            }
        }
        // A reply before the first turn (another conversation's, or one
        // made before turns were kept) offers them as the newest reply.
        if !isWorking, let newest = shown.lastIndex(where: { $0.isReply && !$0.isRemoved }),
           shown[newest].turnMessageID != nil, !shown[newest].text.isEmpty
        {
            shown[newest].offersActions = true
        }
        return shown
    }

    /// The message id an event of the history's changes names.
    private static func payloadID(_ payload: JSONValue?) -> UUID? {
        payload?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// The attachments an event lists, read off its payload as decoding
    /// them would: every one, or none when any is not an attachment.
    /// Decoding writes the value out as JSON and reads it back.
    static func attachments(in value: JSONValue?) -> [AgentAttachment] {
        guard case let .array(items)? = value else { return [] }
        var files: [AgentAttachment] = []
        for item in items {
            guard let path = item["path"]?.stringValue, let name = item["name"]?.stringValue,
                  let mimeType = item["mimeType"]?.stringValue
            else { return [] }
            files.append(AgentAttachment(path: path, name: name, mimeType: mimeType))
        }
        return files
    }

    /// The ids a `queueDropped` lists, read as `attachments(in:)` reads:
    /// every one, or none when any is not an id.
    static func identifiers(in value: JSONValue?) -> Set<UUID> {
        guard case let .array(items)? = value else { return [] }
        var ids: Set<UUID> = []
        for item in items {
            guard let id = item.stringValue.flatMap(UUID.init(uuidString:)) else { return [] }
            ids.insert(id)
        }
        return ids
    }

    /// The id of the user message an event shows: a `prompt`, `steer` or
    /// `queued` that carries one.
    static func userMessageID(of event: TaskEvent) -> UUID? {
        guard ["prompt", "steer", "queued"].contains(event.kind) else { return nil }
        return event.payload?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// Whether an event is the `state` a task ends with, which ends its
    /// turn: the host appends nothing after it.
    static func endsTask(_ event: TaskEvent) -> Bool {
        guard event.kind == TaskEvent.stateKind else { return false }
        return event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:))?.isTerminal == true
    }

    /// While the run goes, its newest summary says so — it heads the run,
    /// even when a reply is being written under it or a card waits below.
    /// Each thought ends when a tool starts, so without this the header
    /// would say "Completed" over a run still working, with the reply it is
    /// writing arriving underneath. It carries the run's output so far, the
    /// newest call in its trace and whether a failed request is being made
    /// again.
    private static func keepTrailingSummaryRunning(
        _ rows: inout [ChatMessage],
        receivedTokens: Int?,
        reconnecting: Bool,
    ) {
        guard let index = rows.lastIndex(where: { Self.isSummary($0.role) }),
              case let .thinking(_, tools) = rows[index].role
        else { return }
        // A reply being written after the summary takes the count: it
        // settles there once the run is writing, rather than climbing slowly.
        if let last = rows.indices.last, rows[last].role == .assistant {
            settleCount(&rows, reply: last, receivedTokens: receivedTokens)
        }
        rows[index].role = .thinking(seconds: nil, tools: tools)
        rows[index].receivedTokens = receivedTokens
        rows[index].banner = rows[index].trace.last { $0.role == .tool }?.banner
        rows[index].isReconnecting = reconnecting
    }

    /// Whether a row is one of the summaries the transcript folds a run's
    /// thoughts, calls and approvals into — running or finished.
    private static func isSummary(_ role: ChatMessage.Role) -> Bool {
        if case .thinking = role {
            return true
        }
        return false
    }

    /// While the run writes a reply, the summary above it keeps the run's
    /// count, which settles there — its header still says the run is going;
    /// never a summary above the turn's own message.
    private static func settleCount(_ rows: inout [ChatMessage], reply: Int, receivedTokens: Int?) {
        guard receivedTokens != nil, rows[reply].role == .assistant,
              let summary = rows[..<reply].lastIndex(where: { $0.role != .assistant }),
              case .thinking = rows[summary].role
        else { return }
        rows[summary].receivedTokens = receivedTokens
        rows[summary].receivedSettles = true
    }

    /// The running summary that stands in under `row` until the turn shows
    /// what follows it, under the id the next thought will take.
    private static func standIn(after row: UUID) -> ChatMessage {
        ChatMessage(id: firstThoughtID(after: row), role: .thinking(seconds: nil, tools: 0), text: "")
    }

    /// Folds the thoughts, calls and approvals between two replies into one
    /// summary, which counts only the calls in its own trace.
    static func presentationRows(_ messages: [ChatMessage]) -> [ChatMessage] {
        var combined: [ChatMessage] = []
        var summary: Int?
        for (index, message) in messages.enumerated() {
            switch message.role {
            case let .thinking(seconds, _):
                // A finished thought with no text adds only its time: to the
                // summary it follows, or to a new one for the call after it.
                let isEmpty = seconds != nil && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if let summary, case let .thinking(previousSeconds, tools) = combined[summary].role {
                    let totalSeconds = previousSeconds.flatMap { elapsed in seconds.map { elapsed + $0 } }
                    combined[summary].role = .thinking(seconds: totalSeconds, tools: tools)
                    guard !isEmpty else { break }
                    combined[summary].text = [combined[summary].text, message.text].filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    combined[summary].trace.append(message)
                } else {
                    guard !isEmpty || Self.callFollows(messages, index) else { break }
                    summary = combined.count
                    var header = message
                    header.role = .thinking(seconds: seconds, tools: 0)
                    header.trace = isEmpty ? [] : [message]
                    combined.append(header)
                }
            case .tool, .approval:
                if summary == nil {
                    summary = combined.count
                    combined.append(ChatMessage(
                        id: Self.rowID("trace:\(message.id)"),
                        role: .thinking(seconds: 0, tools: 0),
                        text: "",
                    ))
                }
                if let summary {
                    combined[summary].trace.append(message)
                    if case let .thinking(seconds, _) = combined[summary].role {
                        let calls = combined[summary].trace.count(where: { $0.role == .tool })
                        combined[summary].role = .thinking(seconds: seconds, tools: calls)
                    }
                }
                if message.role.needsApproval {
                    combined.append(message)
                }
            case .turn:
                // A turn's header is made after the fold, from the turn
                // itself; one that arrives here only passes through.
                combined.append(message)
            case .user, .assistant, .compaction:
                summary = nil
                combined.append(message)
            }
        }
        return combined.filter {
            if case let .thinking(seconds?, tools) = $0.role {
                return seconds > 0 || tools > 0
            }
            return true
        }
    }

    /// Whether a call or an approval comes right after the row at `index`:
    /// the thought before a call heads the summary that holds it.
    private static func callFollows(_ rows: [ChatMessage], _ index: Int) -> Bool {
        guard rows.indices.contains(index + 1) else { return false }
        let next = rows[index + 1].role
        return next == .tool || next.isApproval
    }

    /// The last of the fold's rows, when a running summary may stand in
    /// under it (`standInAnchor(after:unanswered:)`).
    private var standInAnchor: UUID? {
        Self.standInAnchor(after: rows, unanswered: unanswered)
    }

    /// The last of `rows`, when a running summary may stand in under it:
    /// the turn's unanswered row, or a reply (or an error) it showed last,
    /// under which one stands in once the turn has gone quiet.
    private static func standInAnchor(after rows: [ChatMessage], unanswered: UUID?) -> UUID? {
        guard let last = rows.last, last.id == unanswered || last.role == .assistant else { return nil }
        return last.id
    }

    /// A thought right after a row a summary may have stood in under takes
    /// the id the stand-in had.
    private mutating func startThinking(id: UUID, at date: Date) {
        let id = standInAnchor.map(Self.firstThoughtID) ?? unanswered.map(Self.firstThoughtID) ?? id
        thinking = rows.count
        thinkingStarted = date
        unanswered = nil
        add(ChatMessage(id: id, role: .thinking(seconds: nil, tools: 0), text: ""))
    }

    private static func firstThoughtID(after row: UUID) -> UUID {
        rowID("answer:\(row)")
    }

    private mutating func finishThinking(at date: Date) {
        guard let thinking else { return }
        let seconds = max(0, Int(date.timeIntervalSince(thinkingStarted ?? date)))
        rows[thinking].role = .thinking(seconds: seconds, tools: 0)
        self.thinking = nil
        thinkingStarted = nil
    }

    /// What a message from another conversation says over its bubble.
    static func senderLine(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return String(localized: "From another chat") }
        return String(localized: "From \(title)")
    }

    /// Above the active summary, distinct from the bubble's attribution.
    static func processingLine(_ title: String?) -> String {
        guard let title, !title.isEmpty else {
            return String(localized: "Processing a message from another chat")
        }
        return String(localized: "Processing a message from \(title)")
    }

    /// The reason in a call's arguments, trimmed; nil when it gave none.
    private static func reason(_ arguments: String?) -> String? {
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        let reason = values?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? nil : reason
    }

    /// A call's title, by the tool it names: today's name or one an earlier
    /// release recorded (`AgentToolName.canonical`), so an old conversation
    /// reads as a new one does. A tool added without a title does not build.
    private static func toolTitle(_ name: String, arguments: String?) -> String {
        guard let tool = AgentToolName.canonical(name) else {
            return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        let path = values?["path"]?.stringValue ?? ""
        switch tool {
        case .fileRead: return path.isEmpty ? String(localized: "Read a file") : String(localized: "Read \(path)")
        case .fileWrite, .fileCreate:
            return path.isEmpty ? String(localized: "Write a file") : String(localized: "Write \(path)")
        case .fileEdit: return path.isEmpty ? String(localized: "Edit a file") : String(localized: "Edit \(path)")
        case .fileList: return String(localized: "List files")
        case .fileGrep, .fileFind: return String(localized: "Search files")
        case .fileShow:
            guard case let .array(items)? = values?["paths"] else { return String(localized: "Show a file") }
            let paths = items.compactMap(\.stringValue)
            if paths.count > 1 {
                return String(localized: "Show \(paths.count) files")
            }
            return paths.first.map { String(localized: "Show \($0)") } ?? String(localized: "Show a file")
        case .todoList: return String(localized: "Read the to-do list")
        case .todoWrite: return String(localized: "Update the to-do list")
        case .shellRun: return String(localized: "Run a command")
        case .sdkAnalyzeFramework, .sdkReadHeader: return String(localized: "Read the SDK")
        case .projectBuild: return String(localized: "Build the project")
        case .packageInstall: return String(localized: "Install the package")
        case .packageRemove: return String(localized: "Remove the package")
        case .packageList: return String(localized: "List installed packages")
        case .packagePublish: return String(localized: "Publish to the package repository")
        case .packageConfirmLoaded: return String(localized: "Check the tweak loaded")
        case .screenCapture: return String(localized: "Capture the screen")
        case .screenReadTree: return String(localized: "Inspect the screen")
        case .screenInteract: return String(localized: "Interact with the screen")
        case .logRead: return String(localized: "Read logs")
        case .crashList, .crashRead: return String(localized: "Read crash reports")
        case .crashSymbolicate: return String(localized: "Symbolicate a crash")
        case .deviceRespring: return String(localized: "Restart SpringBoard")
        case .memoryList: return String(localized: "Read memories")
        case .memorySave: return String(localized: "Save a memory")
        case .memoryDelete: return String(localized: "Delete a memory")
        case .skillList: return String(localized: "List skills")
        case .skillRead: return String(localized: "Read a skill")
        case .skillSave: return String(localized: "Save a skill")
        case .skillRemove: return String(localized: "Remove a skill")
        case .projectCheckDistribution: return String(localized: "Check for distribution")
        case .gitBranches: return String(localized: "Branches")
        case .gitBranchCreate: return String(localized: "Create branch")
        case .gitBranchCheckout: return String(localized: "Switch Branch")
        case .gitBranchRename: return String(localized: "Rename Branch")
        case .gitMerge: return String(localized: "Merge Branch")
        case .gitMergeAbort: return String(localized: "Abort Merge")
        case .gitLog: return String(localized: "Git History")
        case .gitCommitDetail: return String(localized: "Read the changes")
        case .gitStatus: return String(localized: "Check the repository")
        case .gitDiff: return String(localized: "Read the changes")
        case .gitStage: return String(localized: "Stage changes")
        case .gitUnstage: return String(localized: "Unstage changes")
        case .gitCommit: return String(localized: "Commit changes")
        case .gitInit: return String(localized: "Create repository")
        case .gitFetch: return String(localized: "Fetch from the remote")
        case .gitPull: return String(localized: "Pull from the remote")
        case .gitPush: return String(localized: "Push to the remote")
        case .gitClone: return String(localized: "Import the repository")
        case .gitSquash: return String(localized: "Squash commits")
        case .gitRemoteList: return String(localized: "List the remotes")
        case .gitRemoteSet: return String(localized: "Set a remote")
        case .gitRemoteRemove: return String(localized: "Remove a remote")
        case .gitResetToRemote: return String(localized: "Reset to the remote")
        case .gitReadSettings: return String(localized: "Read the Git settings")
        case .gitSetAuthor: return String(localized: "Set the commit author")
        case .gitSaveCredential: return String(localized: "Save a Git credential")
        case .gitRemoveCredential: return String(localized: "Remove a Git credential")
        case .gitCreateRepository: return String(localized: "Create a GitHub repository")
        case .gitCreateIssue: return String(localized: "Create a GitHub issue")
        case .conversationCreate: return String(localized: "Create a chat")
        case .conversationSend: return String(localized: "Send to a chat")
        case .conversationList: return String(localized: "List chats")
        case .conversationRead: return String(localized: "Read a chat")
        case .conversationStop: return String(localized: "Stop a chat")
        case .notificationSend: return String(localized: "Send a notification")
        case .questionAsk: return String(localized: "Ask a question")
        case .runMode: return String(localized: "Switch the run mode")
        case .webSearch:
            let query = values?["query"]?.stringValue ?? ""
            return query.isEmpty ? String(localized: "Search the web") : String(localized: "Search for \(query)")
        case .webFetch:
            let host = values?["url"]?.stringValue.flatMap { URLComponents(string: $0)?.host } ?? ""
            return host.isEmpty ? String(localized: "Read a webpage") : String(localized: "Read \(host)")
        case .feedbackSend: return String(localized: "Send feedback")
        case .feedbackRead: return String(localized: "Read a feedback issue")
        case .feedbackEdit: return String(localized: "Edit a feedback issue")
        case .toolchainList: return String(localized: "List toolchains")
        case .sdkList: return String(localized: "List SDKs")
        case .toolchainSetup: return String(localized: "Set up a toolchain")
        case .sdkImport: return String(localized: "Import an SDK")
        case .toolchainSelfTest: return String(localized: "Test the toolchain")
        case .projectSetEnvironment: return String(localized: "Switch the toolchain or SDK")
        case .templateList: return String(localized: "List project templates")
        case .projectList: return String(localized: "List projects")
        case .projectRename: return String(localized: "Rename the project")
        case .projectDelete: return String(localized: "Delete a project")
        case .projectCreate:
            let project = values?["name"]?.stringValue ?? ""
            return project.isEmpty ? String(localized: "Create a project") : String(localized: "Create \(project)")
        }
    }

    private static func rowID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ))
    }
}

/// How full a conversation's context is: what the agent measures for
/// compaction (`contextUsage`), and what the ring beside the composer draws.
struct ChatContextUsage: Equatable {
    /// What the conversation takes now.
    var tokens: Int
    /// What it may take before compaction.
    var window: Int

    init(tokens: Int, window: Int) {
        self.tokens = max(0, tokens)
        self.window = max(0, window)
    }

    /// From an event's payload, and only with a window to read it against.
    init?(_ payload: JSONValue?) {
        guard let tokens = payload?["tokens"]?.doubleValue,
              let window = payload?["window"]?.doubleValue,
              window > 0
        else { return nil }
        self.init(tokens: Int(tokens), window: Int(window))
    }

    /// How much of the window is used, 0 ... 1.
    var fraction: Double {
        guard window > 0 else { return 0 }
        return min(1, max(0, Double(tokens) / Double(window)))
    }

    /// The figure the ring writes, in the user's locale: "12%".
    var percentText: String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// What VoiceOver reads for the ring: the share and the room.
    var spoken: String {
        String(localized: "\(percentText) of \(window.formatted()) tokens used")
    }
}

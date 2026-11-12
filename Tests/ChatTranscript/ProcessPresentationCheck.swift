import Foundation

func checkProcessPresentation() {
    let turn = UUID()
    func row(_ role: ChatMessage.Role, _ text: String = "") -> ChatMessage {
        var value = ChatMessage(role: role, text: text)
        value.turnMessageID = turn
        return value
    }
    let prompt = row(.user, "Work through several tools")
    let header = row(.turn(running: true, seconds: nil))
    var items = [prompt, header]
    var replies: [ChatMessage] = []
    let processID = ChatTranscript.rowID(forProcess: turn)
    for index in 0 ..< 24 {
        var summary = row(.thinking(seconds: nil, tools: 1))
        summary.banner = ToolCallBanner(reason: "Call \(index)")
        summary.receivedTokens = index + 1
        summary.receivedSettles = index.isMultiple(of: 2)
        let thought = row(.thinking(seconds: 1, tools: 0), "Thought \(index)")
        let call = row(.tool, "Tool \(index)")
        summary.trace = [thought, call]
        items.append(summary)
        let text = row(.assistant, "Commentary \(index)")
        replies.append(text)
        items.append(text)

        let folded = ChatProcessPresentation.rows(items, isExpanded: { _ in false })
        precondition(folded[0].id == prompt.id && folded[1].id == header.id)
        precondition(folded[2].id == processID && folded[2].banner == summary.banner,
                     "the newest process stays next to the header as text accumulates")
        precondition(folded[2].trace == summary.trace && folded[2].foldsProcessSteps,
                     "long-press detail keeps its original trace")
        precondition(folded[1].headerReceivedTokens == summary.receivedTokens)
        precondition(folded[1].headerReceivedSettles == summary.receivedSettles)
        precondition(folded.filter { $0.role == .assistant } == replies,
                     "commentary is not deleted or reordered")
        precondition(Set(folded.map(\.id)).count == folded.count, "each visible id occurs once")
        let open = ChatProcessPresentation.rows(items, isExpanded: { _ in true })
        precondition(open.map(\.id) == items.map(\.id), "open steps keep chronology")
        precondition(!open.contains { $0.foldsProcessSteps })
        precondition(ChatProcessPresentation.rows(items, isExpanded: { _ in false }) == folded,
                     "fold-open-fold is stable")
    }

    var noBanner = row(.thinking(seconds: nil, tools: 0), "")
    noBanner.receivedTokens = 99
    noBanner.processingSource = " \n "
    let quiet = ChatProcessPresentation.rows([prompt, header] + replies + [noBanner], isExpanded: { _ in false })
    precondition(quiet.map(\.id) == [prompt.id, header.id] + replies.map(\.id),
                 "a title-only running summary occupies the header, never an empty extra row")
    precondition(quiet[1].headerReceivedTokens == 99)
    noBanner.processingSource = "Another conversation"
    let sourced = ChatProcessPresentation.rows([prompt, header, noBanner], isExpanded: { _ in false })
    precondition(sourced.count == 3 && sourced[2].processingSource == noBanner.processingSource)

    let empty = row(.thinking(seconds: 1, tools: 0), " \n\t ")
    precondition(!ChatActivityContent.hasContent(empty))
    let first = row(.thinking(seconds: 1, tools: 0), "A real thought")
    let second = row(.thinking(seconds: 2, tools: 0), "Another thought")
    let adjacent = ChatProcessPresentation.rows([prompt, header, first, empty, second], isExpanded: { _ in true })
    precondition(adjacent.map(\.id) == [prompt.id, header.id, first.id, second.id])
    precondition(!adjacent[2].activityJoinsPrevious && adjacent[3].activityJoinsPrevious)
    let separated = ChatProcessPresentation.rows([first, replies[0], second], isExpanded: { _ in true })
    precondition(!separated[2].activityJoinsPrevious, "body text keeps its normal boundary")
    var mixed = first
    mixed.trace = [empty, first, first, row(.tool, "Call")]
    precondition(ChatActivityContent.steps(mixed).count == 2, "blank thoughts are skipped, ids deduplicated")
    var tokensOnly = empty
    tokensOnly.receivedTokens = 10
    precondition(ChatActivityContent.hasContent(tokensOnly), "a count still has a visible line")

    var finished = header
    finished.role = .turn(running: false, seconds: 8)
    let ended = ChatProcessPresentation.rows([prompt, finished, first, replies[0]], isExpanded: { _ in false })
    precondition(ended.map(\.id) == [prompt.id, header.id, replies[0].id])
    // A legacy transcript without a turn header must not lose its activity.
    precondition(ChatProcessPresentation.rows([first], isExpanded: { _ in false }).first?.id == first.id)
    let older = UUID()
    var otherHeader = header
    otherHeader.id = UUID()
    otherHeader.turnMessageID = older
    var otherSummary = second
    otherSummary.turnMessageID = older
    let multiple = ChatProcessPresentation.rows([otherHeader, otherSummary, prompt, header, noBanner]) { $0 == older }
    precondition(multiple[1].id == otherSummary.id && !multiple[1].foldsProcessSteps)
    precondition(multiple.last?.id == processID, "each turn uses only its own latest summary")
    print("ok: process stays beside header across 24 segments; order, identity, empty rows, scopes and toggling")
}

func checkActivityLayout() {
    for width: CGFloat in [0, 12, 28, 100, 240, 390, 700] {
        for title: CGFloat in [40, 120, 500] {
            for showsTokens in [false, true] {
                let slots = ChatHeaderLayout(width: width, stateWidth: title, showsTokens: showsTokens)
                precondition(slots.stateWidth >= 0 && slots.tokensWidth >= 0)
                precondition(slots.stateWidth <= slots.tokensX)
                precondition(slots.tokensX + slots.tokensWidth <= slots.chevronX)
                precondition(slots.chevronX + slots.chevronWidth <= width)
                // Mirroring these disjoint slots also keeps RTL disjoint.
                let arrowEnd = width - slots.chevronX
                let tokenStart = width - slots.tokensX - slots.tokensWidth
                precondition(arrowEnd <= tokenStart)
            }
        }
    }
    print("ok: 42 header slot combinations; narrow widths, large titles and RTL stay disjoint")
    let empty = ChatActivityLayout(source: 0, title: 0, banner: 0, steps: 0, top: 8, bottom: 8)
    precondition(empty.height == 0, "an empty row has no insets")
    let steps = ChatActivityLayout(source: 0, title: 0, banner: 0, steps: 30, top: 8, bottom: 8)
    precondition(steps.stepsY == 8 && steps.height == 46, "no phantom title gap above steps")
    let joined = ChatActivityLayout(source: 0, title: 0, banner: 0, steps: 30, top: 0, bottom: 8)
    precondition(joined.stepsY == 0 && joined.height == 38, "adjacent segments share one inset")
    let banner = ChatActivityLayout(source: 0, title: 0, banner: 24, steps: 0, top: 8, bottom: 8)
    precondition(banner.bannerY == 8 && banner.height == 40, "no title gap above a lone banner")
    let all = ChatActivityLayout(source: 12, title: 20, banner: 24, steps: 30, top: 8, bottom: 8)
    precondition(all.sourceY == 8 && all.titleY == 24 && all.bannerY == 52 && all.stepsY == 86 && all.height == 124)
    let source = ChatActivityLayout(source: 12, title: 0, banner: 0, steps: 0, top: 8, bottom: 8)
    precondition(source.height == 28, "no gap after the final part")
    for mask in 0 ..< 16 {
        let source: CGFloat = mask & 1 == 0 ? 0 : 12
        let title: CGFloat = mask & 2 == 0 ? 0 : 20
        let banner: CGFloat = mask & 4 == 0 ? 0 : 24
        let steps: CGFloat = mask & 8 == 0 ? 0 : 30
        let layout = ChatActivityLayout(source: source, title: title, banner: banner, steps: steps, top: 8, bottom: 8)
        precondition(layout.sourceY <= layout.titleY && layout.titleY <= layout.bannerY && layout.bannerY <= layout.stepsY)
        precondition(layout.height == (mask == 0 ? 0 : layout.stepsY + steps + 8))
    }
    print("ok: shared activity geometry, all 16 visibility combinations and adjacent segments")
}

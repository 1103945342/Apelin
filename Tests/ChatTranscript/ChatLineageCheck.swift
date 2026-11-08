import ApelinCore
import ApelinProtocol
import Foundation

/// The sidebar's lineage: a fork follows its direct parent's title, a number
/// is never handed out twice, and a relationship is restored only from what a
/// record proves about itself — never from a title.
func checkChatLineage() {
    func chat(
        _ title: String,
        _ project: String?,
        id: UUID = UUID(),
        parent: UUID? = nil,
        relationship: ChatRelationship? = nil,
        number: Int? = nil,
        lastNumber: Int? = nil
    ) -> ChatSummary {
        var summary = ChatSummary(title: title, lastInteraction: Date(timeIntervalSince1970: 1), projectName: project)
        summary.id = id
        summary.parentChatID = parent
        summary.relationship = relationship
        summary.branchNumber = number
        summary.lastBranchNumber = lastNumber
        return summary
    }

    func branch(of parent: ChatSummary, _ title: String, number: Int) -> ChatSummary {
        chat(title, parent.projectName, parent: parent.id, relationship: .branch, number: number)
    }

    // MARK: A record saved before lineage keeps none of it.

    let legacy = Data(#"{"id":"1B4E28BA-2FA1-11D2-883F-0016D3CCA427","title":"Old","updated":0,"isPinned":false,"isWorking":false}"#.utf8)
    guard let legacySummary = try? JSONDecoder().decode(ChatSummary.self, from: legacy) else {
        preconditionFailure("a record saved before lineage still reads")
    }
    precondition(legacySummary.parentChatID == nil && legacySummary.relationship == nil)
    precondition(legacySummary.branchNumber == nil && legacySummary.lastBranchNumber == nil, "absent lineage reads as none")

    let saved = chat("Plan", "Clock", parent: UUID(), relationship: .branch, number: 2, lastNumber: 5)
    guard let encoded = try? JSONEncoder().encode(saved),
          let readBack = try? JSONDecoder().decode(ChatSummary.self, from: encoded)
    else {
        preconditionFailure("a record with lineage round-trips")
    }
    precondition(readBack.parentChatID == saved.parentChatID && readBack.relationship == .branch)
    precondition(readBack.branchNumber == 2 && readBack.lastBranchNumber == 5, "lineage is saved, not merely held")

    // MARK: A branch shows its direct parent's title, one level at a time.

    var root = chat("Plan", "Clock")
    let first = branch(of: root, "Plan", number: 1)
    let second = branch(of: first, "Plan", number: 1)
    precondition(
        first.titlePresentation == ChatTitlePresentation(title: "Plan", branchNumber: 1),
        "a branch title carries its number into the page-title presentation"
    )
    precondition(
        root.titlePresentation == ChatTitlePresentation(title: "Plan"),
        "a root conversation has no branch badge"
    )
    var malformedBranch = branch(of: root, "Plan", number: 0)
    precondition(malformedBranch.titlePresentation.branchNumber == nil, "a nonpositive branch number is not shown")
    malformedBranch.relationship = .derived
    malformedBranch.branchNumber = 3
    precondition(malformedBranch.titlePresentation.branchNumber == nil, "a derived conversation has no branch badge even with a stored number")
    precondition(branch(of: root, "Plan", number: 2).titlePresentation != first.titlePresentation,
                 "same-title branches with different numbers are distinct presentations")
    precondition(ChatTitlePresentation(title: "Plan", branchNumber: -1).branchNumber == nil,
                 "negative numbers never become badges")
    var projected = Dictionary(uniqueKeysWithValues: ChatLineage.projected([root, first, second]).map { ($0.id, $0) })
    precondition(projected[first.id]?.title == "Plan" && projected[second.id]?.title == "Plan")
    precondition(projected[second.id]?.branchNumber == 1, "only the title is projected")

    root.title = "Plan the clock"
    projected = Dictionary(uniqueKeysWithValues: ChatLineage.projected([root, first, second]).map { ($0.id, $0) })
    precondition(projected[first.id]?.title == "Plan the clock", "a renamed parent renames its branches")
    precondition(projected[second.id]?.title == "Plan the clock", "and the whole subtree below it")
    precondition(first.title == "Plan", "the saved record keeps its own title as the fallback")

    // The parent deleted, or in another project, leaves the saved title.
    projected = Dictionary(uniqueKeysWithValues: ChatLineage.projected([first, second]).map { ($0.id, $0) })
    precondition(projected[second.id]?.title == "Plan", "a branch whose parent is gone keeps its saved title")
    let stranger = branch(of: chat("Elsewhere", "Docs"), "Plan", number: 1)
    let crossProject = chat("Branch", "Clock", parent: stranger.id, relationship: .branch, number: 1)
    projected = Dictionary(uniqueKeysWithValues: ChatLineage.projected([stranger, crossProject]).map { ($0.id, $0) })
    precondition(projected[crossProject.id]?.title == "Branch", "no edge crosses a project's root")

    // Two branches naming each other neither hang nor borrow a title.
    var loopA = chat("A", "Clock")
    var loopB = chat("B", "Clock")
    loopA.parentChatID = loopB.id
    loopA.relationship = .branch
    loopB.parentChatID = loopA.id
    loopB.relationship = .branch
    projected = Dictionary(uniqueKeysWithValues: ChatLineage.projected([loopA, loopB]).map { ($0.id, $0) })
    precondition(projected[loopA.id]?.title == "A" && projected[loopB.id]?.title == "B", "a cycle falls back to the saved titles")

    // A derived conversation names itself; only a fork inherits.
    let derived = chat("Docs", "Clock", parent: root.id, relationship: .derived)
    projected = Dictionary(uniqueKeysWithValues: ChatLineage.projected([root, derived]).map { ($0.id, $0) })
    precondition(projected[derived.id]?.title == "Docs", "a conversation an agent opened keeps its own name")

    // An agent's suggested title never renames a branch.
    var named = branch(of: root, "Plan", number: 2)
    named.suggestTitle("Something the agent liked")
    precondition(named.title == "Plan", "a branch keeps its parent's title")
    var suggested = root
    suggested.suggestTitle("Plan the clock")
    precondition(suggested.title == "Plan the clock", "anything else is still named by the agent")

    // MARK: Numbers are handed out once, in order, even after a deletion.

    let parentID = UUID()
    var parent = chat("Plan", "Clock", id: parentID)
    let fresh = [parent]
    precondition(ChatLineage.reserveBranchNumber(in: &parent, summaries: fresh) == 1)
    precondition(parent.lastBranchNumber == 1, "the parent keeps the high-water mark")
    let kept = branch(of: parent, "Plan", number: 1)
    var again = chat("Plan", "Clock", id: parentID, lastNumber: parent.lastBranchNumber)
    let withChild = [again, kept]
    precondition(ChatLineage.reserveBranchNumber(in: &again, summaries: withChild) == 2)
    // `kept` deleted: the counter alone still says 2 was used.
    var afterDeletion = chat("Plan", "Clock", id: parentID, lastNumber: again.lastBranchNumber)
    let alone = [afterDeletion]
    precondition(ChatLineage.reserveBranchNumber(in: &afterDeletion, summaries: alone) == 3,
                 "a deleted branch's number is never reused")
    // A parent saved before it counted repairs its mark from its children.
    var uncounted = chat("Plan", "Clock", id: parentID)
    let fourth = branch(of: uncounted, "Plan", number: 4)
    let withFourth = [uncounted, fourth]
    precondition(ChatLineage.reserveBranchNumber(in: &uncounted, summaries: withFourth) == 5)
    precondition(uncounted.lastBranchNumber == 5)
    var exhausted = chat("Plan", "Clock", id: parentID, lastNumber: Int.max)
    let full = [exhausted]
    precondition(ChatLineage.reserveBranchNumber(in: &exhausted, summaries: full) == nil, "a full range reserves nothing")
    precondition(exhausted.lastBranchNumber == Int.max)

    // MARK: An edge stays inside one project and never closes a cycle.

    let child = chat("Branch", "Clock")
    var summaries: [UUID: ChatSummary] = [parentID: chat("Plan", "Clock", id: parentID)]
    precondition(ChatLineage.canAttach(child, to: summaries[parentID]!, summaries: summaries))
    precondition(!ChatLineage.canAttach(child, to: child, summaries: [child.id: child]), "never its own parent")
    let far = chat("Plan", "Docs", id: parentID)
    precondition(!ChatLineage.canAttach(child, to: far, summaries: [far.id: far]), "never another project")
    let temporary = chat("Branch", nil)
    precondition(!ChatLineage.canAttach(temporary, to: temporary, summaries: [:]), "a temporary chat has no project to share")
    let grandparent = chat("Root", "Clock")
    let middle = branch(of: grandparent, "Root", number: 1)
    let last = branch(of: middle, "Root", number: 1)
    summaries = [grandparent.id: grandparent, middle.id: middle, last.id: last]
    precondition(!ChatLineage.canAttach(grandparent, to: last, summaries: summaries), "never below its own branch")

    // MARK: What a record proves, and nothing else.

    func record(_ summary: ChatSummary, session: String?, events: [TaskEvent] = []) -> ChatRecord {
        ChatRecord(summary: summary, sessionID: session, events: events)
    }

    func records(_ list: [ChatRecord]) -> [UUID: ChatRecord] {
        Dictionary(uniqueKeysWithValues: list.map { ($0.summary.id, $0) })
    }

    func openedEvent(_ session: String, historical: Bool = false) -> [TaskEvent] {
        var payload: [String: JSONValue] = ["sessionID": .string(session)]
        if historical {
            payload["historical"] = .bool(true)
        }
        return [TaskEvent(seq: EventSeq(1), kind: AgentConversations.openedEventKind, payload: .object(payload))]
    }

    let openerSession = UUID().uuidString.lowercased()
    let childSession = UUID().uuidString.lowercased()
    let opener = chat("Plan", "Clock")
    let openerRecord = record(opener, session: openerSession, events: openedEvent(childSession))
    let childSummary = chat("Docs", "Clock")
    let childRecord = record(childSummary, session: childSession)
    var loaded = [opener.id: openerRecord, childSummary.id: childRecord]
    var changed = ChatAdoption.restoreLineage(in: &loaded)
    precondition(changed == [childSummary.id], "one edge is restored from the saved event: \(changed)")
    precondition(loaded[childSummary.id]?.summary.parentChatID == opener.id)
    precondition(loaded[childSummary.id]?.summary.relationship == .derived)
    precondition(loaded[childSummary.id]?.summary.branchNumber == nil, "an edge restores no branch number")
    let settled = loaded
    precondition(ChatAdoption.restoreLineage(in: &loaded).isEmpty, "a record already in place is left alone")
    precondition(loaded[childSummary.id]?.summary == settled[childSummary.id]?.summary, "and nothing about it is rewritten")
    precondition(loaded[opener.id]?.summary == settled[opener.id]?.summary, "the opener is untouched too")

    // A historical replay is the fork's copy of an old open, not the fork's own.
    var historicalRecords = records([
        record(opener, session: openerSession, events: openedEvent(childSession, historical: true)),
        childRecord,
    ])
    precondition(ChatAdoption.restoreLineage(in: &historicalRecords).isEmpty, "a replayed open makes no edge")

    // Two openers claiming one child prove nothing.
    let other = chat("Docs", "Clock")
    var conflicting = records([
        openerRecord,
        record(other, session: UUID().uuidString.lowercased(), events: openedEvent(childSession)),
        childRecord,
    ])
    precondition(ChatAdoption.restoreLineage(in: &conflicting).isEmpty, "conflicting evidence leaves the child unrelated")

    // A session id two records share is ambiguous.
    let third = chat("Other", "Clock")
    var ambiguous = records([
        openerRecord,
        childRecord,
        record(third, session: childSession),
    ])
    precondition(ChatAdoption.restoreLineage(in: &ambiguous).isEmpty, "an ambiguous session id makes no edge")

    // A branch saved by an earlier build keeps its number and its edge.
    var forked = chat("Plan", "Clock", parent: opener.id, relationship: .branch, number: 3)
    var forkedRecords = records([record(opener, session: openerSession), record(forked, session: childSession)])
    changed = ChatAdoption.restoreLineage(in: &forkedRecords)
    precondition(changed == [opener.id], "a saved branch raises its parent's high-water mark: \(changed)")
    precondition(forkedRecords[opener.id]?.summary.lastBranchNumber == 3)
    precondition(forkedRecords[forked.id]?.summary.parentChatID == opener.id, "an explicit relationship is left as it is")
    precondition(forkedRecords[forked.id]?.summary.relationship == .branch)
    // Never lowered: two is below what the branch already says.
    let higher = chat("Plan", "Clock", id: opener.id, lastNumber: 9)
    forkedRecords = records([record(higher, session: UUID().uuidString.lowercased()), record(forked, session: childSession)])
    precondition(ChatAdoption.restoreLineage(in: &forkedRecords).isEmpty, "a lower mark never lowers it")
    precondition(forkedRecords[opener.id]?.summary.lastBranchNumber == 9)

    // A fork made before lineage kept no parent, and a title is no evidence.
    let orphan = chat("Fork of Plan", "Clock", number: nil)
    var guessed = records([record(opener, session: openerSession), record(orphan, session: UUID().uuidString.lowercased())])
    precondition(ChatAdoption.restoreLineage(in: &guessed).isEmpty, "a title never names a parent")
    precondition(guessed[orphan.id]?.summary.parentChatID == nil)

    // The host's list supplies what the opener's events were never saved with.
    // (A record whose own event already names the child proves the edge on its
    // own, so these openers keep no events.)
    func listed(_ session: String, parent: String?, project: String? = nil, state: TaskState = .running) -> AgentSessionSummary {
        var summary = AgentSessionSummary(
            sessionID: session,
            task: TaskHandle(taskID: TaskID("child-task"), kind: .agent),
            title: "Docs",
            state: state,
            updatedAt: Date(timeIntervalSince1970: 9),
            parentSessionID: parent
        )
        summary.projectName = project
        return summary
    }

    let silentOpener = record(opener, session: openerSession)
    var fromHost = records([silentOpener, childRecord])
    changed = ChatAdoption.restoreLineage(in: &fromHost, sessions: [listed(childSession, parent: openerSession)])
    precondition(changed == [childSummary.id], "the host's list restores the edge: \(changed)")
    precondition(fromHost[childSummary.id]?.summary.parentChatID == opener.id)

    // An ended session's record still says who opened it.
    var ended = records([silentOpener, childRecord])
    precondition(!ChatAdoption.restoreLineage(in: &ended, sessions: [listed(childSession, parent: openerSession, state: .succeeded)]).isEmpty,
                 "an ended session's opener is still evidence")

    // The host listing it in another project than the record's names no edge.
    var elsewhere = records([silentOpener, childRecord])
    precondition(ChatAdoption.restoreLineage(in: &elsewhere, sessions: [listed(childSession, parent: openerSession, project: "Docs")]).isEmpty,
                 "a session in another project makes no edge")
    precondition(elsewhere[childSummary.id]?.summary.parentChatID == nil)

    // Evidence pointing both ways must not close a cycle.
    let loopSessionA = UUID().uuidString.lowercased()
    let loopSessionB = UUID().uuidString.lowercased()
    let roundA = chat("A", "Clock")
    let roundB = chat("B", "Clock")
    var cycle: [UUID: ChatRecord] = [
        roundA.id: record(roundA, session: loopSessionA, events: openedEvent(loopSessionB)),
        roundB.id: record(roundB, session: loopSessionB, events: openedEvent(loopSessionA)),
    ]
    ChatAdoption.restoreLineage(in: &cycle)
    let aParent = cycle[roundA.id]?.summary.parentChatID
    let bParent = cycle[roundB.id]?.summary.parentChatID
    precondition((aParent == nil) != (bParent == nil), "only one of the two edges is made")
    var walked: Set<UUID> = []
    var current: UUID? = roundA.id
    while let id = current, walked.insert(id).inserted {
        current = cycle[id]?.summary.parentChatID
    }
    precondition(walked.count <= 2 && current == nil, "the restored graph is acyclic")

    // An agent's open is a derived edge in its own project only, and never a
    // cross-project one; this changes no host lineage.
    let openedPayload: JSONValue = .object([
        "sessionID": .string(childSession),
        "task": .object(["taskID": .string("child-task"), "kind": .string("agent")]),
        "title": .string("Docs"),
    ])
    let adopted = ChatAdoption.record(opened: openedPayload, parent: record(opener, session: openerSession), records: [record(opener, session: openerSession)])
    precondition(adopted?.summary.parentChatID == opener.id && adopted?.summary.relationship == .derived)
    var farOpened = openedPayload
    if case var .object(fields) = farOpened {
        fields["projectName"] = .string("Docs")
        farOpened = .object(fields)
    }
    let acrossProjects = ChatAdoption.record(opened: farOpened, parent: record(opener, session: openerSession), records: [record(opener, session: openerSession)])
    precondition(acrossProjects?.summary.projectName == "Docs" && acrossProjects?.summary.parentChatID == nil,
                 "an open in another project makes no sidebar edge")

    print("ok: branches follow their parent's title, numbers are never reused, and lineage is restored only from what a record proves")
}

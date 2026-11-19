import ApelinProtocol
import Darwin
import Foundation

/// The host's durable assignment ledger: one file per opener, written whole and
/// atomically, read without a cache.
///
/// This store is authority, not a model: it authenticates nobody (the caller
/// must already know the child belongs to the authenticated opener), it grants
/// no filesystem permission over the workspace, and it never decides that a
/// child's turn finished means the opener accepted the work. Only the opener's
/// explicit `accept` writes `.accepted`, and it does so only for a plan carried
/// to its end; work without a passing check for every criterion stays
/// `.unverified` there forever.
///
/// Fail-closed rules:
/// - A read that does not decode, is not a bounded regular file, is a link, or
///   names another opener refuses the operation. Its bytes are preserved; it is
///   never replaced by an empty ledger. The file is inspected through the
///   descriptor it opened (`fstat`) and read up to that size, never with an
///   unbounded read of whatever the path may have become.
/// - A failed write is never published: the caller sees the error, the file
///   keeps its previous bytes, and nothing is cached in memory.
/// - Registration is idempotent per child and opener: the same brief answers the
///   stored member without a write, a different brief must be amended, and a
///   child already registered to another opener is refused.
/// - A plan older than the last one this store saw is stale and refused. A newer
///   plan revision updates the plan note and may add a derived state, but never
///   removes an explicit one: accepted, cancelled, failed and an explicitly
///   blocked member survive plan revisions untouched.
///
/// Blockers carry provenance. One derived from the plan's own blocked step is
/// recorded with the plan revision that produced it and removed when the opener
/// amends that step open again; any other blocker belongs to the member and is
/// left alone. A derived block never outlives the plan that caused it.
///
/// A report is kept as a claim: its source, turn identity and text are recorded
/// so the account can show what the child said. It changes no state, no receipt
/// and no verification.
///
/// The final account uses the ledger model's stable event ID
/// (`assignment-final:<groupID>:<groupRevision>`). Staging it and acknowledging
/// it are delivery bookkeeping here; sending it through the outbox is the host's
/// job.
actor AgentAssignmentStore {
    /// How many artifacts one assignment may report. Bounded so a child cannot
    /// grow the opener's record without limit.
    static let maximumOutputs = 64

    /// The whole file for one opener. Versioned so a later layout can refuse to
    /// interpret these bytes instead of guessing. Fields added after the first
    /// layout are optional so an existing version-1 file still reads.
    struct Record: Codable, Sendable {
        var version = 1
        var opener: String
        var group: AgentAssignmentGroup
        /// The last plan revision this store accepted for each child, so a
        /// redelivered older plan is refused rather than replayed. Survives
        /// restarts with the file.
        var plans: [String: UInt64]
        /// Blockers this store derived from a plan's blocked step, by child.
        var derivedBlockers: [String: DerivedBlocker]?
        /// Turn reports kept as claims, by child, newest last. Bounded so the
        /// file cannot grow without limit; the raw text of every turn stays in
        /// the child's own conversation log, and the final account never reads
        /// these claims.
        var reports: [String: [StoredReport]]?
        /// How many older claims per child were dropped from this file.
        var droppedReports: [String: Int]?
        /// Final-account events staged for delivery, by event ID.
        var finalAccounts: [AgentAssignmentFinalAccount]?
        /// The event IDs whose delivery the host acknowledged.
        var acknowledgedEvents: [String]?
    }

    /// A blocker the store added because the plan's current step was blocked.
    /// It records the plan revision so the amendment that reopens the step can
    /// remove exactly this one.
    struct DerivedBlocker: Codable, Sendable, Equatable {
        var planRevision: UInt64
        var reason: String
        var needs: String?

        var blocker: AgentAssignment.Blocker {
            AgentAssignment.Blocker(reason: reason, needs: needs)
        }

        static let defaultReason = "The brief's current step is blocked."
        static let defaultNeeds = "the opener decides how the step proceeds"
    }

    /// One turn report, kept as the child's claim about its own turn.
    struct StoredReport: Codable, Sendable, Equatable {
        var childSessionID: String
        var childTaskID: String
        var closingSeq: UInt64
        var outcome: AgentTurnOutcome
        var stoppedBy: AgentTurnStoppedBy?
        var title: String?
        var text: String
        var truncated: Bool

        init(_ report: AgentTurnReport) {
            childSessionID = report.childSessionID
            childTaskID = report.childTaskID
            closingSeq = report.closingSeq
            outcome = report.outcome
            stoppedBy = report.stoppedBy
            title = report.title
            text = report.text
            truncated = report.truncated
        }
    }

    let directory: URL
    private let write: @Sendable (Data, URL) throws -> Void

    init(directory: URL,
         write: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
             try data.write(to: url, options: .atomic)
         }) {
        self.directory = directory
        self.write = write
    }

    // MARK: API — delegation

    /// Registers a child conversation under its opener and creates the member's
    /// ledger entry from the brief the opener delegated.
    ///
    /// Idempotent: registering the same child with the same objective and
    /// acceptance returns the stored member unchanged, with no write and no
    /// revision bump. A different brief is refused — that is an amendment, not a
    /// re-registration. A sealed group takes no more members.
    @discardableResult
    func register(child: String, opener: String, brief: AgentDelegationBrief,
                  request: String? = nil) throws -> AgentAssignment {
        guard UUID(uuidString: opener) != nil, UUID(uuidString: child) != nil, child != opener else {
            throw refusal("Assignments key on session UUIDs, and a child cannot open itself.")
        }
        try brief.validate()
        var record = try loadRecord(opener) ?? newRecord(opener)
        if let existing = record.group.assignment(child) {
            guard existing.objective == brief.objective,
                  existing.acceptance == brief.acceptance else {
                throw refusal("This child is already registered with another brief; amend it explicitly.", child)
            }
            return existing
        }
        let owners = try otherOwners(of: child, excluding: opener)
        guard owners.isEmpty else {
            throw refusal("This child is already registered to opener \(owners[0]); one account per child.",
                          child)
        }
        let member = try AgentAssignment(
            id: child,
            origin: AgentAssignment.Origin(
                openerSessionID: opener,
                openerRequestID: request ?? "delegation-\(child)",
                childSessionID: child
            ),
            objective: brief.objective,
            acceptance: brief.acceptance,
            briefRevision: 1
        )
        record.group = try record.group.adding(member, expectedRevision: record.group.revision)
        try persist(record)
        return record.group.assignment(child) ?? member
    }

    /// Reconciles a member with the plan its child's host tracks.
    ///
    /// Only derived states are added: a blocked current step marks a working
    /// member blocked and records a derived blocker; a plan carried to its end
    /// marks a working member readyForReview. A finished plan is never accepted.
    /// A newer plan revision records its number. When the plan no longer blocks
    /// its current step, the derived blocker is removed and the member returns to
    /// working; an explicit blocker is never removed by this call.
    @discardableResult
    func sync(child: String, opener: String, plan: AgentDelegationPlan) throws -> AgentAssignment {
        guard UUID(uuidString: opener) != nil, UUID(uuidString: child) != nil else {
            throw refusal("Assignments key on session UUIDs.", child)
        }
        try plan.validate()
        guard var record = try loadRecord(opener) else {
            throw refusal("No assignments are registered for this opener.", child)
        }
        guard let stored = record.group.assignment(child) else {
            throw refusal("This child has no assignment; register it before syncing a plan.", child)
        }
        var derivedBlocks = record.derivedBlockers ?? [:]
        var derived = derivedBlocks[child]
        // An amendment may restate what the assignment is measured against: the
        // objective stays, the plan revision is newer, and the acceptance it
        // carries replaces the old one. The member re-baselines; receipts from
        // the old revision keep their number and stop counting, and a blocker
        // derived from the step being replaced goes with it.
        var member = stored
        if plan.brief.objective != stored.objective {
            throw refusal("The plan belongs to another brief; it cannot speak for this assignment.", child)
        }
        if plan.brief.acceptance != stored.acceptance {
            guard plan.revision > stored.briefRevision else {
                throw refusal("The plan's acceptance differs from this assignment without a newer revision; register it anew instead.", child)
            }
            member = try stored.rebased(briefRevision: plan.revision,
                                        acceptance: plan.brief.acceptance,
                                        expectedRevision: stored.revision)
            if let note = derived {
                member = try removing(note.blocker, from: member)
                derived = nil
            }
        }
        let note = record.plans[child] ?? 0
        guard plan.revision >= note else {
            throw refusal("Stale plan revision \(plan.revision); this assignment already saw \(note).", child)
        }
        let reconciled = try reconcile(member, with: plan, derived: &derived)
        derivedBlocks[child] = derived
        let stateChanged = reconciled != stored
        let noteChanged = plan.revision != note
        let derivedChanged = derivedBlocks[child] != (record.derivedBlockers ?? [:])[child]
        guard stateChanged || noteChanged || derivedChanged else { return member }
        if stateChanged {
            record.group = try record.group.replacing(reconciled,
                                                      expectedRevision: record.group.revision)
        }
        record.plans[child] = plan.revision
        record.derivedBlockers = derivedBlocks.isEmpty ? nil : derivedBlocks
        try persist(record)
        return record.group.assignment(child) ?? reconciled
    }

    // MARK: API — the opener's explicit review

    /// The opener's review: the only path to `.accepted`.
    ///
    /// Requires a plan carried to its end (`currentStep == nil`), the member's
    /// exact revision, and the group's opener. A sync-derived block is cleared
    /// first because the finished plan no longer blocks; an explicit blocker
    /// refuses the acceptance. Work without a passing receipt for every
    /// acceptance criterion stays `.unverified` in the ledger.
    @discardableResult
    func accept(child: String, opener: String, plan: AgentDelegationPlan,
                expectedRevision: UInt64) throws -> AgentAssignment {
        try plan.validate()
        guard var record = try loadRecord(opener) else {
            throw refusal("No assignments are registered for this opener.", child)
        }
        guard let stored = record.group.assignment(child) else {
            throw refusal("This child has no assignment; register it before accepting it.", child)
        }
        try requireSameBrief(plan, as: stored)
        guard plan.currentStep == nil else {
            throw refusal("Only a plan carried to its end can be accepted; the current step still belongs to the child.",
                          child)
        }
        let note = record.plans[child] ?? 0
        guard plan.revision >= note else {
            throw refusal("Stale plan revision \(plan.revision); this assignment already saw \(note).", child)
        }
        if stored.state == .accepted { return stored }
        guard !stored.state.isTerminal else {
            throw refusal("The assignment is \(stored.state.rawValue); acceptance cannot undo that.", child)
        }
        guard stored.revision == expectedRevision else {
            throw refusal("Stale member revision \(expectedRevision); the ledger holds \(stored.revision).", child)
        }
        var derivedBlocks = record.derivedBlockers ?? [:]
        var member = stored
        if let derived = derivedBlocks[child] {
            derivedBlocks[child] = nil
            if member.state == .blocked {
                member = try removing(derived.blocker, from: member)
            }
        }
        guard member.state != .blocked else {
            throw refusal("The child is blocked for a reason it reported; resolve it or cancel the assignment instead.",
                          child)
        }
        if member.state == .working {
            member = try member.submittedForReview(expectedRevision: member.revision)
        }
        member = try member.accepted(by: opener, expectedRevision: member.revision)
        record.group = try record.group.replacing(member, expectedRevision: record.group.revision)
        record.plans[child] = plan.revision
        record.derivedBlockers = derivedBlocks.isEmpty ? nil : derivedBlocks
        try persist(record)
        return record.group.assignment(child) ?? member
    }

    /// The opener ends the assignment with a reason. Cancellation is reported,
    /// never painted as success; repeating the same call is the same fact.
    @discardableResult
    func cancel(child: String, opener: String, reason: String,
                expectedRevision: UInt64) throws -> AgentAssignment {
        guard var record = try loadRecord(opener) else {
            throw refusal("No assignments are registered for this opener.", child)
        }
        guard var member = record.group.assignment(child) else {
            throw refusal("This child has no assignment.", child)
        }
        guard Self.nonempty(reason) else {
            throw refusal("A cancellation states why.", child)
        }
        if member.state == .cancelled { return member }
        guard member.revision == expectedRevision else {
            throw refusal("Stale member revision \(expectedRevision); the ledger holds \(member.revision).", child)
        }
        guard !member.state.isTerminal else {
            throw refusal("The assignment is \(member.state.rawValue); it cannot be cancelled now.", child)
        }
        var derivedBlocks = record.derivedBlockers ?? [:]
        derivedBlocks[child] = nil
        if let derived = (record.derivedBlockers ?? [:])[child], member.state == .blocked {
            member = try removing(derived.blocker, from: member)
        }
        member = try member.cancelled(by: opener, reason: reason,
                                      expectedRevision: member.revision)
        record.group = try record.group.replacing(member, expectedRevision: record.group.revision)
        record.derivedBlockers = derivedBlocks.isEmpty ? nil : derivedBlocks
        try persist(record)
        return member
    }

    /// What the child says it produced, recorded while the assignment is still
    /// working — before the plan transition that ends the step moves it. It is
    /// a claim: only a host check receipt is evidence. A member that has
    /// already left `working` keeps what it had, and an output the ledger
    /// already holds (same `id`) is not recorded twice.
    @discardableResult
    func report(_ outputs: [AgentAssignment.Output], child: String, opener: String) throws -> AgentAssignment {
        guard var record = try loadRecord(opener) else {
            throw refusal("No assignments are registered for this opener.", child)
        }
        guard let current = record.group.assignment(child) else {
            throw refusal("This child has no assignment.", child)
        }
        guard current.state == .working else { return current }
        var member = current
        for output in outputs {
            guard Self.nonempty(output.summary) else {
                throw refusal("An output says what it is in summary.", child)
            }
            guard output.summary.utf8.count <= 1024, (output.path?.utf8.count ?? 0) <= 4096 else {
                throw refusal("An output is at most 1 KiB of summary and 4 KiB of path.", child)
            }
            guard !member.outputs.contains(where: { $0.id == output.id }) else { continue }
            guard member.outputs.count < Self.maximumOutputs else {
                throw refusal("An assignment records at most \(Self.maximumOutputs) outputs.", child)
            }
            member = try member.recording(output, expectedRevision: member.revision)
        }
        guard member != current else { return current }
        record.group = try record.group.replacing(member, expectedRevision: record.group.revision)
        try persist(record)
        return member
    }

    /// Records that the child's work failed, with the reason the host observed.
    /// Failure is reported, never repainted as success.
    @discardableResult
    func fail(child: String, opener: String, reason: String,
              expectedRevision: UInt64) throws -> AgentAssignment {
        guard var record = try loadRecord(opener) else {
            throw refusal("No assignments are registered for this opener.", child)
        }
        guard var member = record.group.assignment(child) else {
            throw refusal("This child has no assignment.", child)
        }
        guard Self.nonempty(reason) else {
            throw refusal("A failure states why.", child)
        }
        if member.state == .failed { return member }
        guard member.revision == expectedRevision else {
            throw refusal("Stale member revision \(expectedRevision); the ledger holds \(member.revision).", child)
        }
        guard !member.state.isTerminal else {
            throw refusal("The assignment is \(member.state.rawValue); it cannot fail now.", child)
        }
        var derivedBlocks = record.derivedBlockers ?? [:]
        derivedBlocks[child] = nil
        if let derived = (record.derivedBlockers ?? [:])[child], member.state == .blocked {
            member = try removing(derived.blocker, from: member)
        }
        member = try member.failed(reason, expectedRevision: member.revision)
        record.group = try record.group.replacing(member, expectedRevision: record.group.revision)
        record.derivedBlockers = derivedBlocks.isEmpty ? nil : derivedBlocks
        try persist(record)
        return member
    }

    /// The opener fixes membership: exactly the children registered now, no
    /// more delegations, and the group revision moves once.
    @discardableResult
    func seal(opener: String, expectedRevision: UInt64) throws -> AgentAssignmentGroup {
        guard var record = try loadRecord(opener) else {
            throw refusal("No assignments are registered for this opener.")
        }
        guard record.group.revision == expectedRevision else {
            throw refusal("Stale group revision \(expectedRevision); the group holds \(record.group.revision).")
        }
        let ids = record.group.assignments.map { $0.id }
        record.group = try record.group.sealed(expectedAssignmentIDs: ids,
                                               expectedRevision: record.group.revision)
        try persist(record)
        return record.group
    }

    // MARK: API — claims

    /// Records one turn report as the child's claim: its source, turn identity
    /// and text. It changes no state, no receipt and no verification.
    ///
    /// The same turn again is the same fact; another text under the same
    /// identity is refused. Each child keeps its most recent 32 claims so the
    /// file stays bounded, and `droppedReportCount` says how many older ones
    /// were left out. Nothing is lost to the account by this: raw reports stay
    /// in the child's own conversation history, and the final account is built
    /// from the ledger's members, never from these claims.
    @discardableResult
    func recordReport(_ report: AgentTurnReport, opener: String) throws -> AgentAssignment {
        guard var record = try loadRecord(opener) else {
            throw refusal("No assignments are registered for this opener.", report.childSessionID)
        }
        guard let member = record.group.assignment(report.childSessionID) else {
            throw refusal("The report names a conversation with no assignment.", report.childSessionID)
        }
        guard report.text.utf8.count <= 16 * 1024 else {
            throw refusal("The report text is too large to keep as a claim; bound it before recording.",
                          report.childSessionID)
        }
        if let title = report.title, title.utf8.count > 256 {
            throw refusal("The report title is too long; bound it before recording.", report.childSessionID)
        }
        let stored = StoredReport(report)
        var all = record.reports ?? [:]
        var list = all[report.childSessionID] ?? []
        var existing: StoredReport?
        for earlier in list where earlier.childTaskID == stored.childTaskID
            && earlier.closingSeq == stored.closingSeq {
            existing = earlier
            break
        }
        if let earlier = existing {
            guard earlier == stored else {
                throw refusal("A report with this turn identity already exists with other content.",
                              report.childSessionID)
            }
            return member
        }
        list.append(stored)
        if list.count > 32 {
            let dropped = list.count - 32
            list.removeFirst(dropped)
            var counts = record.droppedReports ?? [:]
            counts[report.childSessionID] = (counts[report.childSessionID] ?? 0) + dropped
            record.droppedReports = counts
        }
        all[report.childSessionID] = list
        record.reports = all
        try persist(record)
        return member
    }

    // MARK: API — the final account

    /// The group's final account when it is sealed and every member is
    /// accepted, cancelled or failed; nil while anything can still change.
    /// Computed, not staged.
    func finalAccount(opener: String) throws -> AgentAssignmentFinalAccount? {
        guard let record = try loadRecord(opener), record.group.isAccountable else { return nil }
        return try record.group.makeFinalAccount()
    }

    /// Stages the final account in the file, once per group revision, under the
    /// ledger model's stable event ID, and answers it while it is unacknowledged.
    /// A restart sees the same staged event instead of a new one.
    @discardableResult
    func pendingFinalAccount(opener: String) throws -> AgentAssignmentFinalAccount? {
        guard var record = try loadRecord(opener), record.group.isAccountable else { return nil }
        let account = try record.group.makeFinalAccount()
        var accounts = record.finalAccounts ?? []
        if let stored = accounts.first(where: { $0.eventID == account.eventID }) {
            guard stored == account else {
                throw refusal("The staged final account for this revision was rewritten; preserve it and stop.")
            }
        } else {
            guard accounts.count < 8 else {
                throw refusal("Too many staged final accounts; stop and inspect the file.")
            }
            accounts.append(account)
            record.finalAccounts = accounts
            try persist(record)
        }
        if (record.acknowledgedEvents ?? []).contains(account.eventID) { return nil }
        return account
    }

    /// Marks the staged final account delivered. Repeating the same
    /// acknowledgement is the same fact; an unknown event ID is refused.
    @discardableResult
    func acknowledgeFinalAccount(opener: String, eventID: String) throws -> AgentAssignmentFinalAccount {
        guard var record = try loadRecord(opener) else {
            throw refusal("No assignments are registered for this opener.")
        }
        guard let account = (record.finalAccounts ?? []).first(where: { $0.eventID == eventID }) else {
            throw refusal("No staged final account has this event ID; stage it before acknowledging it.")
        }
        var acknowledged = record.acknowledgedEvents ?? []
        if !acknowledged.contains(eventID) {
            guard acknowledged.count < 8 else {
                throw refusal("Too many acknowledged events; stop and inspect the file.")
            }
            acknowledged.append(eventID)
            record.acknowledgedEvents = acknowledged
            try persist(record)
        }
        return account
    }

    // MARK: API — reads

    /// The opener's ledger, or nil when this opener has no assignments yet. A
    /// corrupt or unreadable file throws instead of answering nil.
    func read(opener: String) throws -> AgentAssignmentLedger? {
        guard let record = try loadRecord(opener) else { return nil }
        return try AgentAssignmentLedger().adding(record.group)
    }

    func assignment(child: String, opener: String) throws -> AgentAssignment? {
        try loadRecord(opener)?.group.assignment(child)
    }

    /// The claims recorded for one child, oldest first. Bounded: older ones are
    /// counted by `droppedReportCount` and remain available in the child's own
    /// conversation history.
    func reports(child: String, opener: String) throws -> [StoredReport] {
        try loadRecord(opener)?.reports?[child] ?? []
    }

    /// How many older claims this file no longer holds for one child.
    func droppedReportCount(child: String, opener: String) throws -> Int {
        try loadRecord(opener)?.droppedReports?[child] ?? 0
    }

    /// The plan-derived blocker, when the current block came from the plan
    /// rather than from the member itself.
    func derivedBlocker(child: String, opener: String) throws -> AgentAssignment.Blocker? {
        try loadRecord(opener)?.derivedBlockers?[child]?.blocker
    }

    // MARK: Reconciliation

    /// What a plan alone may say about a member. It never writes accepted: an
    /// opener's acceptance is a separate, explicit review.
    private func reconcile(_ member: AgentAssignment, with plan: AgentDelegationPlan,
                           derived: inout DerivedBlocker?) throws -> AgentAssignment {
        if member.state.isTerminal {
            derived = nil
            return member
        }
        let planBlocked: Bool
        if plan.currentStep == nil {
            planBlocked = false
        } else {
            planBlocked = plan.statuses[plan.currentIndex] == .blocked
        }
        if planBlocked {
            if member.state == .working {
                let blocker = AgentAssignment.Blocker(reason: DerivedBlocker.defaultReason,
                                                      needs: DerivedBlocker.defaultNeeds)
                derived = DerivedBlocker(planRevision: plan.revision,
                                         reason: DerivedBlocker.defaultReason,
                                         needs: DerivedBlocker.defaultNeeds)
                return try member.blocked(blocker, expectedRevision: member.revision)
            }
            if member.state == .blocked, derived != nil {
                derived?.planRevision = plan.revision
            } else if member.state == .readyForReview {
                derived = nil
            }
            return member
        }
        if member.state == .blocked, let note = derived {
            derived = nil
            let cleared = try removing(note.blocker, from: member)
            if plan.currentStep == nil, cleared.state == .working {
                return try cleared.submittedForReview(expectedRevision: cleared.revision)
            }
            return cleared
        }
        if member.state == .readyForReview {
            derived = nil
            return member
        }
        if plan.currentStep == nil, member.state == .working {
            return try member.submittedForReview(expectedRevision: member.revision)
        }
        return member
    }

    // MARK: Derived-blocker removal

    /// Removes exactly the derived blocker, leaving any blocker the member
    /// carries for its own reasons. The member returns to `working` only when
    /// nothing else still blocks it.
    ///
    /// `AgentAssignment` exposes no transition that removes a blocker, so the
    /// stored record is rewritten field for field with only `blockers`, `state`
    /// and the member revision changed. This is an annotation rewrite of a
    /// derived block, never of evidence: outputs, receipts and outcome notes are
    /// carried across untouched and the result is validated before it is used.
    private func removing(_ blocker: AgentAssignment.Blocker,
                          from member: AgentAssignment) throws -> AgentAssignment {
        var blockers = member.blockers
        guard let index = blockers.firstIndex(of: blocker) else { return member }
        blockers.remove(at: index)
        guard member.revision < UInt64.max else {
            throw refusal("The member revision space is exhausted.", member.id)
        }
        let encoder = JSONEncoder()
        guard var json = try JSONSerialization.jsonObject(with: encoder.encode(member))
                as? [String: Any] else {
            throw refusal("The member could not be rewritten; preserve it and stop.", member.id)
        }
        json["blockers"] = try JSONSerialization.jsonObject(with: encoder.encode(blockers))
        json["state"] = (blockers.isEmpty ? AgentAssignment.State.working : .blocked).rawValue
        json["revision"] = member.revision + 1
        let rebuilt: AgentAssignment
        do {
            rebuilt = try JSONDecoder().decode(
                AgentAssignment.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
        } catch {
            throw refusal("The member could not be rewritten; preserve it and stop.", member.id)
        }
        try rebuilt.validate()
        return rebuilt
    }

    // MARK: Files

    private func newRecord(_ opener: String) throws -> Record {
        Record(opener: opener,
               group: try AgentAssignmentGroup(id: Self.groupID(opener), openerSessionID: opener),
               plans: [:])
    }

    private func loadRecord(_ opener: String) throws -> Record? {
        guard UUID(uuidString: opener) != nil else {
            throw refusal("An opener must be a session UUID.")
        }
        return try load(opener, at: location(opener))
    }

    /// Reads one opener's file without following links, checks the descriptor it
    /// actually opened, and reads at most the size that descriptor reports. The
    /// bytes stay where they are when they do not read.
    private func load(_ opener: String, at file: URL) throws -> Record? {
        var pathInfo = stat()
        if lstat(file.path, &pathInfo) != 0 {
            if errno == ENOENT { return nil }
            throw refusal("The assignment ledger cannot be inspected; no operation is authorised.")
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw refusal("The assignment ledger cannot be opened safely.")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 4 * 1024 * 1024 else {
            throw refusal("The assignment ledger is not a bounded regular file; preserve it and stop.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var remaining = Int(info.st_size)
        while remaining > 0 {
            let count = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(fd, pointer.baseAddress, min(pointer.count, remaining))
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                remaining -= Int(count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw refusal("The assignment ledger cannot be read; no operation is authorised.")
            }
        }
        guard data.count == Int(info.st_size) else {
            throw refusal("The assignment ledger changed while it was read; preserve it and stop.")
        }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch {
            throw refusal("The assignment ledger is unreadable. Its bytes were preserved; repair it before continuing.")
        }
        try validate(record, opener: opener)
        return record
    }

    private func persist(_ record: Record) throws {
        try validate(record, opener: record.opener)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try write(JSONEncoder().encode(record), location(record.opener))
    }

    private func location(_ opener: String) -> URL {
        directory.appendingPathComponent(opener + ".json")
    }

    private func validate(_ record: Record, opener: String) throws {
        guard record.version == 1, record.opener == opener else {
            throw refusal("The saved assignment ledger names another opener or version; preserve it and stop.")
        }
        guard record.group.id == Self.groupID(opener),
              record.group.openerSessionID == opener else {
            throw refusal("The saved group is not derived from its opener; preserve it and stop.")
        }
        try record.group.validate()
        let members = Set(record.group.assignments.map { $0.id })
        for (child, revision) in record.plans {
            guard members.contains(child), revision > 0 else {
                throw refusal("The saved plan notes do not match the group; preserve it and stop.")
            }
        }
        for (child, blocker) in record.derivedBlockers ?? [:] {
            guard members.contains(child), blocker.planRevision > 0, Self.nonempty(blocker.reason) else {
                throw refusal("The saved derived blockers do not match the group; preserve it and stop.")
            }
        }
        for (child, dropped) in record.droppedReports ?? [:] {
            guard members.contains(child), dropped > 0 else {
                throw refusal("The saved dropped-report counts do not match the group; preserve it and stop.")
            }
        }
        for (child, list) in record.reports ?? [:] {
            guard members.contains(child), list.count <= 32 else {
                throw refusal("The saved reports do not match the group; preserve it and stop.")
            }
            var turns = Set<String>()
            for report in list {
                guard report.childSessionID == child, report.text.utf8.count <= 16 * 1024,
                      Self.nonempty(report.childTaskID), report.closingSeq > 0,
                      (report.title?.utf8.count ?? 0) <= 256,
                      turns.insert("\(report.childTaskID)\u{0}\(report.closingSeq)").inserted else {
                    throw refusal("A saved report is inconsistent; preserve it and stop.")
                }
            }
        }
        var events = Set<String>()
        for account in record.finalAccounts ?? [] {
            try account.validate()
            guard account.groupID == record.group.id,
                  account.groupRevision <= record.group.revision,
                  events.insert(account.eventID).inserted else {
                throw refusal("A saved final account does not belong to this group; preserve it and stop.")
            }
        }
        guard (record.finalAccounts ?? []).count <= 8,
              (record.acknowledgedEvents ?? []).count <= 8,
              Set(record.acknowledgedEvents ?? []).count == (record.acknowledgedEvents ?? []).count,
              Set(record.acknowledgedEvents ?? []).isSubset(of: events) else {
            throw refusal("The saved final-account delivery state is inconsistent; preserve it and stop.")
        }
    }

    private func requireSameBrief(_ plan: AgentDelegationPlan, as member: AgentAssignment) throws {
        guard plan.brief.objective == member.objective,
              plan.brief.acceptance == member.acceptance else {
            throw refusal("The plan belongs to another brief; it cannot speak for this assignment.", member.id)
        }
    }

    /// Other openers' files that already hold this child. One account per child
    /// keeps a redelivered report from naming two delegations, and a file that
    /// cannot be read refuses the registration instead of being skipped.
    private func otherOwners(of child: String, excluding opener: String) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw refusal("The assignment directory is not a directory; preserve it and stop.", child)
        }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            throw refusal("The assignment directory cannot be listed; no operation is authorised.", child)
        }
        guard entries.count <= 4096 else {
            throw refusal("The assignment directory holds too many entries; stop and inspect it.", child)
        }
        var owners: [String] = []
        for entry in entries {
            guard entry.pathExtension == "json" else { continue }
            let name = entry.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: name) != nil, name != opener else { continue }
            guard let record = try load(name, at: entry) else { continue }
            if record.group.assignment(child) != nil { owners.append(name) }
        }
        return owners
    }

    private func refusal(_ rule: String, _ child: String? = nil) -> AgentAssignmentViolation {
        AgentAssignmentViolation(subject: "assignment store \(child ?? "ledger")", rule: rule)
    }

    private static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.contains("\0")
    }

    private static func groupID(_ opener: String) -> String {
        "team." + opener
    }
}

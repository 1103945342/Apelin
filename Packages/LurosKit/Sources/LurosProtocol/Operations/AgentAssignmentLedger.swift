import Foundation

// The assignment ledger: what the opener delegated, what each delegated
// conversation reported, and whether the work was accepted with evidence or
// without it (Documents/Plan/Team-Collaboration.md §6, slice 4).
//
// This is a pure value model. It authenticates no caller, persists nothing,
// starts no worker and reads no artifact: the host must establish that the
// `by` identity is the opener before it applies `accepted(by:...)` or
// `cancelled(by:...)`, must commit each returned value atomically before
// publishing it to a worker, and must treat a worker that decodes a ledger as
// not authorised to install it as host state. The workspace paths a report
// names are evidence to be canonicalised and re-validated by the host; this
// file grants no permission over them.
//
// A run's outcome (`AgentTurnOutcome`: completed, aborted, failed,
// interrupted) is a fact about one turn. It never moves this ledger on its
// own, and no amount of self-reported completion reaches `accepted`: only the
// opener's explicit review does, and even then work without a passing check
// for every acceptance criterion stays visibly `unverified`.

/// One delegated assignment and its ledger entry: the member identity, the
/// request that opened it, the objective it was given, and the evidence
/// reported against it.
public struct AgentAssignment: Codable, Sendable, Equatable {
    /// The ledger state of the work. It is not the child's runtime state: a
    /// child may be running while `blocked`, idle while `readyForReview`, and
    /// the host's running/idle bookkeeping stays separate.
    public enum State: String, Codable, Sendable, CaseIterable {
        /// The child is expected to be working; mutations are allowed.
        case working
        /// Work is stopped on something the child reported. Reads and reports
        /// (blockers, check re-runs) continue; mutations do not.
        case blocked
        /// The child says its turn is done. That is a claim, never acceptance.
        case readyForReview
        /// The opener reviewed the artifacts. Only the opener sets this.
        case accepted
        case cancelled
        case failed

        public var isTerminal: Bool {
            switch self {
            case .accepted, .cancelled, .failed: return true
            case .working, .blocked, .readyForReview: return false
            }
        }
    }

    /// The label the ledger keeps on evidence, before and after acceptance.
    /// Acceptance without a current passing check for every criterion is
    /// `.unverified` for good; it is never repainted later.
    public enum Verification: String, Codable, Sendable {
        case verified
        case unverified
    }

    /// Where this assignment came from: the conversation that opened the
    /// child, the request that asked for it, and the child conversation.
    public struct Origin: Codable, Sendable, Equatable {
        public var openerSessionID: String
        public var openerRequestID: String
        public var childSessionID: String

        public init(openerSessionID: String, openerRequestID: String, childSessionID: String) {
            self.openerSessionID = openerSessionID
            self.openerRequestID = openerRequestID
            self.childSessionID = childSessionID
        }
    }

    /// An artifact the child reported. `path`, when present, is a claim the
    /// host canonicalises against the project; the ledger stores it as text.
    public struct Output: Codable, Sendable, Equatable {
        public var id: String
        public var summary: String
        public var path: String?

        public init(id: String, summary: String, path: String? = nil) {
            self.id = id
            self.summary = summary
            self.path = path
        }
    }

    /// A host-observed check receipt. `planRevision` is the
    /// `AgentDelegationPlan.revision` the check ran under, so a receipt from
    /// an older plan cannot certify a newer acceptance criterion.
    public struct Check: Codable, Sendable, Equatable {
        public var adapterID: String
        /// The acceptance criterion this receipt settles, verbatim.
        public var criterion: String
        public var passed: Bool
        public var planRevision: UInt64

        public init(adapterID: String, criterion: String, passed: Bool, planRevision: UInt64) {
            self.adapterID = adapterID
            self.criterion = criterion
            self.passed = passed
            self.planRevision = planRevision
        }
    }

    public struct Blocker: Codable, Sendable, Equatable {
        public var reason: String
        /// What the opener must decide or supply to unblock the work.
        public var needs: String?

        public init(reason: String, needs: String? = nil) {
            self.reason = reason
            self.needs = needs
        }
    }

    public private(set) var id: String
    public private(set) var origin: Origin
    public private(set) var objective: String
    public private(set) var acceptance: [String]
    /// The brief revision this assignment's steps were written for.
    public private(set) var briefRevision: UInt64
    /// The member revision: every accepted change bumps it, and every change
    /// must name the revision it expects.
    public private(set) var revision: UInt64
    public private(set) var state: State
    public private(set) var outputs: [Output]
    public private(set) var checks: [Check]
    public private(set) var blockers: [Blocker]
    /// The reason recorded with a cancellation or failure, for the account.
    public private(set) var outcomeNote: String?

    public init(id: String, origin: Origin, objective: String, acceptance: [String],
                briefRevision: UInt64) throws {
        self.id = id
        self.origin = origin
        self.objective = objective
        self.acceptance = acceptance
        self.briefRevision = briefRevision
        revision = 1
        state = .working
        outputs = []
        checks = []
        blockers = []
        outcomeNote = nil
        try validate()
    }

    // MARK: Evidence

    /// Checks taken under a different plan revision; they never certify the
    /// current one and stay in the record so the account can show them.
    public var staleChecks: [Check] { checks.filter { $0.planRevision != briefRevision } }

    public var currentChecks: [Check] { checks.filter { $0.planRevision == briefRevision } }

    public var passingChecks: [Check] { currentChecks.filter { $0.passed } }

    public var failedChecks: [Check] { currentChecks.filter { !$0.passed } }

    /// Acceptance criteria with no current passing receipt. Never a claim the
    /// child can fill in for itself.
    public var missingChecks: [String] {
        let settled = Set(passingChecks.map { $0.criterion })
        return acceptance.filter { !settled.contains($0) }
    }

    /// `.verified` only when every criterion has a current passing receipt.
    /// This is computed from stored receipts, never from the child's prose,
    /// and an accepted assignment keeps saying `.unverified` forever when the
    /// opener accepted work without checks.
    public var verification: Verification {
        missingChecks.isEmpty ? .verified : .unverified
    }

    // MARK: Transitions

    /// Records a blocker. Allowed from `working` and `readyForReview`, and on
    /// an already `blocked` assignment to add a second reason.
    public func blocked(_ blocker: Blocker, expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard !state.isTerminal else {
            throw refusal("The assignment is \(state.rawValue); a blocker cannot reopen it.")
        }
        return try mutated { next in
            next.blockers.append(blocker)
            next.state = .blocked
        }
    }

    public func resumed(expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard state == .blocked else { throw refusal("Only a blocked assignment can resume.") }
        return try mutated { next in next.state = .working }
    }

    /// Records an artifact the child reported. Only `working` accepts new
    /// output; a blocked or reviewed assignment reports instead.
    public func recording(_ output: Output, expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard state == .working else {
            throw refusal("Only a working assignment records output; this one is \(state.rawValue).")
        }
        return try mutated { next in next.outputs.append(output) }
    }

    /// Records a host-observed check receipt. A re-run of the same adapter for
    /// the same criterion at the same plan revision replaces the earlier one,
    /// so a failing check that is corrected stops blocking acceptance without
    /// inventing a second history.
    public func reporting(_ check: Check, expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard !state.isTerminal else {
            throw refusal("The assignment is \(state.rawValue); a receipt cannot move it.")
        }
        return try mutated { next in
            next.checks.removeAll {
                $0.adapterID == check.adapterID && $0.criterion == check.criterion
                    && $0.planRevision == check.planRevision
            }
            next.checks.append(check)
        }
    }

    /// The child's own completion claim. It reaches `readyForReview` and no
    /// further; acceptance belongs to the opener.
    public func submittedForReview(expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard state == .working else {
            throw refusal("Only a working assignment can be submitted for review; this one is \(state.rawValue).")
        }
        return try mutated { next in next.state = .readyForReview }
    }

    /// The opener's explicit review, the only path to `accepted`. The host
    /// authenticates `openerSessionID` before calling; the parameter is a
    /// check against the recorded origin, not a credential.
    public func accepted(by openerSessionID: String, expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard openerSessionID == origin.openerSessionID else {
            throw refusal("Only the conversation that opened this assignment can accept it.")
        }
        guard state == .readyForReview else {
            throw refusal("The assignment is \(state.rawValue); only a reviewed submission can be accepted.")
        }
        return try mutated { next in next.state = .accepted }
    }

    public func cancelled(by openerSessionID: String, reason: String,
                          expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard openerSessionID == origin.openerSessionID else {
            throw refusal("Only the conversation that opened this assignment can cancel it.")
        }
        guard !state.isTerminal else {
            throw refusal("The assignment is already \(state.rawValue).")
        }
        return try mutated { next in
            next.state = .cancelled
            next.outcomeNote = reason
        }
    }

    /// The child's run failed, as the host observed it. Reported, never
    /// repainted as success.
    public func failed(_ reason: String, expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard !state.isTerminal else {
            throw refusal("The assignment is already \(state.rawValue).")
        }
        return try mutated { next in
            next.state = .failed
            next.outcomeNote = reason
        }
    }

    /// A new brief revision (an amendment). The assignment goes back to
    /// `working`, keeps its outputs and old receipts, and the old receipts stop
    /// counting: the new revision owes fresh evidence.
    public func rebased(briefRevision: UInt64, acceptance: [String],
                        expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard !state.isTerminal else {
            throw refusal("The assignment is \(state.rawValue); a new brief is a new assignment.")
        }
        guard briefRevision > self.briefRevision else {
            throw refusal("An amendment must have a newer brief revision than \(self.briefRevision).")
        }
        return try mutated { next in
            next.briefRevision = briefRevision
            next.acceptance = acceptance
            next.state = .working
            next.outcomeNote = nil
        }
    }

    // MARK: Validation

    /// Decoding is deliberately not validation. Every entry point and every
    /// host read of persisted data calls this first.
    public func validate() throws {
        guard Self.identifier(id) else {
            throw refusal("An assignment needs an identifier of letters, digits, '.', '-' or '_'.")
        }
        guard Self.identifier(origin.openerSessionID), Self.identifier(origin.openerRequestID),
              Self.identifier(origin.childSessionID) else {
            throw refusal("The origin must name the opener conversation, its request and the child conversation.")
        }
        guard Self.nonempty(objective), objective.utf8.count <= 4096 else {
            throw refusal("An assignment needs a bounded objective.")
        }
        guard !acceptance.isEmpty, acceptance.count <= 32,
              acceptance.allSatisfy({ Self.nonempty($0) && $0.utf8.count <= 1024 }),
              Set(acceptance).count == acceptance.count else {
            throw refusal("Acceptance criteria must be 1–32 distinct, nonempty lines.")
        }
        guard revision > 0, briefRevision > 0 else {
            throw refusal("Member and brief revisions start at 1.")
        }
        guard Set(outputs.map { $0.id }).count == outputs.count else {
            throw refusal("Each output needs a distinct identifier.")
        }
        for output in outputs {
            guard Self.identifier(output.id), Self.nonempty(output.summary) else {
                throw refusal("An output needs an identifier and a summary.")
            }
            if let path = output.path {
                guard AgentDelegationBrief.validRelativePath(path) else {
                    throw refusal("An output path must be a normalised project-relative path.")
                }
            }
        }
        for check in checks {
            guard Self.identifier(check.adapterID), Self.nonempty(check.criterion),
                  check.criterion.utf8.count <= 1024, check.planRevision > 0 else {
                throw refusal("A check names an adapter, a criterion and the plan revision it ran under.")
            }
        }
        let checkKeys = checks.map { "\($0.adapterID)\u{0}\($0.criterion)\u{0}\($0.planRevision)" }
        guard Set(checkKeys).count == checkKeys.count else {
            throw refusal("One check receipt per adapter, criterion and plan revision.")
        }
        for blocker in blockers {
            guard Self.nonempty(blocker.reason), blocker.reason.utf8.count <= 4096 else {
                throw refusal("A blocker needs a bounded reason.")
            }
            if let needs = blocker.needs, !Self.nonempty(needs) || needs.utf8.count > 1024 {
                throw refusal("A blocker's need, when present, is a bounded line.")
            }
        }
        switch state {
        case .cancelled, .failed:
            guard let note = outcomeNote, Self.nonempty(note), note.utf8.count <= 4096 else {
                throw refusal("A cancelled or failed assignment records why.")
            }
        case .working, .blocked, .readyForReview, .accepted:
            guard outcomeNote == nil else {
                throw refusal("Only a cancellation or failure carries an outcome note.")
            }
        }
    }

    // MARK: Helpers

    private func requireRevision(_ expected: UInt64) throws {
        try validate()
        guard expected == revision else {
            throw refusal("Stale member revision \(expected); the ledger holds \(revision).")
        }
    }

    private func mutated(_ change: (inout AgentAssignment) throws -> Void) throws -> AgentAssignment {
        var next = self
        try change(&next)
        guard next.revision < UInt64.max else { throw refusal("The member revision space is exhausted.") }
        next.revision += 1
        try next.validate()
        return next
    }

    private func refusal(_ rule: String) -> AgentAssignmentViolation {
        AgentAssignmentViolation(subject: "assignment \(id)", rule: rule)
    }

    private static func nonempty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.contains("\0")
    }

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95 || $0 == 46
        }
    }
}

/// A compact, complete account of a group's members as they stood at one group
/// revision: still-working and blocked members included, claims and evidence
/// together. The opener's contract is to account for it, not to summarise only
/// the child that happened to finish.
public struct AgentAssignmentSnapshot: Codable, Sendable, Equatable {
    public struct Member: Codable, Sendable, Equatable {
        public var assignmentID: String
        public var childSessionID: String
        public var state: AgentAssignment.State
        public var verification: AgentAssignment.Verification
        public var memberRevision: UInt64
        public var briefRevision: UInt64
        public var outputs: [AgentAssignment.Output]
        public var checks: [AgentAssignment.Check]
        public var missingChecks: [String]
        public var blockers: [AgentAssignment.Blocker]
        public var outcomeNote: String?
    }

    public var groupID: String
    public var groupRevision: UInt64
    public var isSealed: Bool
    public var members: [Member]

    public var allTerminal: Bool { members.allSatisfy { $0.state.isTerminal } }

    public var acceptedCount: Int { members.filter { $0.state == .accepted }.count }

    public var unverifiedAcceptedCount: Int {
        members.filter { $0.state == .accepted && $0.verification == .unverified }.count
    }

    public func member(_ assignmentID: String) -> Member? {
        members.first { $0.assignmentID == assignmentID }
    }
}

/// Whether a snapshot or account still matches the group it describes. A
/// summary taken before a new member joined (or before any member moved) is
/// `outdated`, and the new revision owes a fresh account.
public enum AgentAssignmentFreshness: String, Codable, Sendable {
    case current
    case outdated
}

/// One final-account event, keyed by group ID and group revision. It travels
/// through the same outbox as every other report; this model only names it.
public struct AgentAssignmentFinalAccount: Codable, Sendable, Equatable {
    public var eventID: String
    public var groupID: String
    public var groupRevision: UInt64
    public var snapshot: AgentAssignmentSnapshot

    public init(groupID: String, groupRevision: UInt64, snapshot: AgentAssignmentSnapshot) {
        self.groupID = groupID
        self.groupRevision = groupRevision
        self.snapshot = snapshot
        eventID = AgentAssignmentFinalAccount.identifier(groupID: groupID, groupRevision: groupRevision)
    }

    /// What makes two deliveries of this event the same fact.
    public static func identifier(groupID: String, groupRevision: UInt64) -> String {
        "assignment-final:\(groupID):\(groupRevision)"
    }

    public func validate() throws {
        guard eventID == Self.identifier(groupID: groupID, groupRevision: groupRevision) else {
            throw AgentAssignmentViolation(subject: "final account \(eventID)",
                                           rule: "The event ID must be derived from its group and revision.")
        }
        guard snapshot.groupID == groupID, snapshot.groupRevision == groupRevision else {
            throw AgentAssignmentViolation(subject: "final account \(eventID)",
                                           rule: "The snapshot describes another group or revision.")
        }
        guard snapshot.isSealed, snapshot.allTerminal else {
            throw AgentAssignmentViolation(subject: "final account \(eventID)",
                                           rule: "A final account needs a sealed group whose members are all accepted, cancelled or failed.")
        }
    }
}

/// One work group: its members, its group revision, the seal that fixes
/// membership, and the one final account it owes per revision.
///
/// The group revision moves when membership moves (a new assignment, or the
/// seal); a member's own revision moves with its state and evidence and is
/// checked separately. The host authenticates the opener before sealing,
/// cancelling or accepting; this type only enforces what a consistent ledger
/// may say.
public struct AgentAssignmentGroup: Codable, Sendable, Equatable {
    public private(set) var id: String
    public private(set) var openerSessionID: String
    public private(set) var revision: UInt64
    public private(set) var isSealed: Bool
    public private(set) var expectedAssignmentIDs: [String]
    public private(set) var assignments: [AgentAssignment]

    public init(id: String, openerSessionID: String) throws {
        self.id = id
        self.openerSessionID = openerSessionID
        revision = 1
        isSealed = false
        expectedAssignmentIDs = []
        assignments = []
        try validate()
    }

    public func assignment(_ assignmentID: String) -> AgentAssignment? {
        assignments.first { $0.id == assignmentID }
    }

    public var allTerminal: Bool { assignments.allSatisfy { $0.state.isTerminal } }

    /// The group may owe a final account: sealed, with nothing still running.
    public var isAccountable: Bool { isSealed && allTerminal }

    // MARK: Membership

    /// A new delegation. The group revision moves, which makes every earlier
    /// snapshot outdated.
    public func adding(_ assignment: AgentAssignment, expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard !isSealed else { throw violation("The group is sealed; a later task is a new group.") }
        try assignment.validate()
        guard assignment.origin.openerSessionID == openerSessionID else {
            throw violation("Every member belongs to this group's opener.")
        }
        guard !assignments.contains(where: { $0.id == assignment.id }) else {
            throw violation("Assignment \(assignment.id) is already a member.")
        }
        guard !assignments.contains(where: { $0.origin.childSessionID == assignment.origin.childSessionID }) else {
            throw violation("The child conversation already holds a member; one account per child.")
        }
        return try mutated { next in next.assignments.append(assignment) }
    }

    /// Replaces a member with a newer revision of itself. A stale or rewritten
    /// member is refused, so reports cannot arrive out of order unnoticed. An
    /// identical replay is accepted as the same fact. Membership and group
    /// revision do not change.
    public func replacing(_ assignment: AgentAssignment, expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        try assignment.validate()
        guard let index = assignments.firstIndex(where: { $0.id == assignment.id }) else {
            throw violation("\(assignment.id) is not a member of this group.")
        }
        let current = assignments[index]
        guard current.origin == assignment.origin else {
            throw violation("A member keeps its origin; a different child is a new assignment.")
        }
        if current == assignment { return self }
        guard assignment.revision > current.revision else {
            throw violation("Stale member revision \(assignment.revision); the group holds \(current.revision).")
        }
        var next = self
        next.assignments[index] = assignment
        try next.validate()
        return next
    }

    /// Fixes membership: no more assignments, and every expected ID must be a
    /// member, so the final account cannot quietly omit one.
    public func sealed(expectedAssignmentIDs: [String], expectedRevision: UInt64) throws -> Self {
        try requireRevision(expectedRevision)
        guard !isSealed else { throw violation("The group is already sealed.") }
        var ids = Set<String>()
        guard expectedAssignmentIDs.allSatisfy({
            !$0.isEmpty && ids.insert($0).inserted
        }) else {
            throw violation("Expected assignment IDs are distinct and nonempty.")
        }
        let members = Set(assignments.map { $0.id })
        guard ids == members else {
            let missing = ids.subtracting(members).sorted().joined(separator: ", ")
            let unlisted = members.subtracting(ids).sorted().joined(separator: ", ")
            throw violation("The seal must list exactly the current members (unlisted: [\(unlisted)]; unknown: [\(missing)]).")
        }
        return try mutated { next in
            next.isSealed = true
            next.expectedAssignmentIDs = expectedAssignmentIDs
        }
    }

    // MARK: Account

    public func snapshot() -> AgentAssignmentSnapshot {
        AgentAssignmentSnapshot(
            groupID: id,
            groupRevision: revision,
            isSealed: isSealed,
            members: assignments.map { assignment in
                AgentAssignmentSnapshot.Member(
                    assignmentID: assignment.id,
                    childSessionID: assignment.origin.childSessionID,
                    state: assignment.state,
                    verification: assignment.verification,
                    memberRevision: assignment.revision,
                    briefRevision: assignment.briefRevision,
                    outputs: assignment.outputs,
                    checks: assignment.checks,
                    missingChecks: assignment.missingChecks,
                    blockers: assignment.blockers,
                    outcomeNote: assignment.outcomeNote
                )
            }
        )
    }

    /// Whether a summary still describes this group exactly as it stands now:
    /// same group, same revision, same seal, and the same member revisions.
    public func freshness(of snapshot: AgentAssignmentSnapshot) -> AgentAssignmentFreshness {
        guard snapshot.groupID == id, snapshot.groupRevision == revision,
              snapshot.isSealed == isSealed, snapshot.members.count == assignments.count else {
            return .outdated
        }
        var revisions: [String: UInt64] = [:]
        for assignment in assignments { revisions[assignment.id] = assignment.revision }
        for member in snapshot.members where revisions[member.assignmentID] != member.memberRevision {
            return .outdated
        }
        return .current
    }

    public func freshness(of account: AgentAssignmentFinalAccount) -> AgentAssignmentFreshness {
        freshness(of: account.snapshot)
    }

    /// The group's one final account for its current revision. Refused while
    /// membership can still change or any member is still running: partial
    /// results are reports, not a final account.
    public func makeFinalAccount() throws -> AgentAssignmentFinalAccount {
        try validate()
        guard isSealed else {
            throw violation("The group is not sealed; the opener seals it when no more tasks are being assigned.")
        }
        guard allTerminal else {
            let pending = assignments.filter { !$0.state.isTerminal }.map { $0.id }.sorted()
            throw violation("The account is owed once every member is accepted, cancelled or failed; still open: \(pending.joined(separator: ", ")).")
        }
        let account = AgentAssignmentFinalAccount(groupID: id, groupRevision: revision, snapshot: snapshot())
        try account.validate()
        return account
    }

    // MARK: Validation

    public func validate() throws {
        guard AgentAssignment.identifier(id) else { throw violation("A group needs an identifier.") }
        guard AgentAssignment.identifier(openerSessionID) else {
            throw violation("A group names the conversation that opened it.")
        }
        guard revision > 0 else { throw violation("The group revision starts at 1.") }
        var memberIDs = Set<String>()
        var children = Set<String>()
        for assignment in assignments {
            try assignment.validate()
            guard assignment.origin.openerSessionID == openerSessionID else {
                throw violation("\(assignment.id) names another opener than its group.")
            }
            guard memberIDs.insert(assignment.id).inserted else {
                throw violation("\(assignment.id) appears twice.")
            }
            guard children.insert(assignment.origin.childSessionID).inserted else {
                throw violation("The child \(assignment.origin.childSessionID) appears twice.")
            }
        }
        guard Set(expectedAssignmentIDs).count == expectedAssignmentIDs.count,
              expectedAssignmentIDs.allSatisfy({ !$0.isEmpty }) else {
            throw violation("Expected assignment IDs are distinct and nonempty.")
        }
        if isSealed {
            guard Set(expectedAssignmentIDs) == memberIDs else {
                throw violation("A sealed group's expected IDs are exactly its members.")
            }
        } else {
            guard expectedAssignmentIDs.isEmpty else {
                throw violation("Expected IDs are recorded at the seal, not before it.")
            }
        }
    }

    // MARK: Helpers

    private func requireRevision(_ expected: UInt64) throws {
        try validate()
        guard expected == revision else {
            throw violation("Stale group revision \(expected); the group holds \(revision).")
        }
    }

    private func mutated(_ change: (inout AgentAssignmentGroup) throws -> Void) throws -> AgentAssignmentGroup {
        var next = self
        try change(&next)
        guard next.revision < UInt64.max else { throw violation("The group revision space is exhausted.") }
        next.revision += 1
        try next.validate()
        return next
    }

    private func violation(_ rule: String) -> AgentAssignmentViolation {
        AgentAssignmentViolation(subject: "group \(id)", rule: rule)
    }
}

/// A ledger of work groups and their final accounts. Recording an account is
/// idempotent by event ID, so a redelivered final event is the same fact and
/// does not grow a second entry; an account from another revision is refused
/// as outdated, and the group owes a fresh one.
///
/// Persistence, delivery and authentication belong to the host: nothing here
/// writes a file, reaches an outbox or proves who asked.
public struct AgentAssignmentLedger: Codable, Sendable, Equatable {
    public private(set) var groups: [AgentAssignmentGroup]
    public private(set) var finalAccounts: [AgentAssignmentFinalAccount]

    public init() {
        groups = []
        finalAccounts = []
    }

    public func group(_ id: String) -> AgentAssignmentGroup? {
        groups.first { $0.id == id }
    }

    public func account(_ eventID: String) -> AgentAssignmentFinalAccount? {
        finalAccounts.first { $0.eventID == eventID }
    }

    /// Recorded accounts whose group has since moved to another revision (or
    /// is gone). They stay in the record as the outdated summary they are.
    public var outdatedFinalAccounts: [AgentAssignmentFinalAccount] {
        finalAccounts.filter { account in
            guard let group = group(account.groupID) else { return true }
            return group.freshness(of: account) != .current
        }
    }

    public func adding(_ group: AgentAssignmentGroup) throws -> Self {
        try group.validate()
        guard !groups.contains(where: { $0.id == group.id }) else {
            throw AgentAssignmentViolation(subject: "group \(group.id)", rule: "The ledger already holds this group.")
        }
        var next = self
        next.groups.append(group)
        return next
    }

    /// Applies a group's next state. The expected revision guards ordering: an
    /// update computed from an older group is refused, never merged.
    public func replacing(_ group: AgentAssignmentGroup, expectedRevision: UInt64) throws -> Self {
        try group.validate()
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else {
            throw AgentAssignmentViolation(subject: "group \(group.id)", rule: "The ledger does not hold this group.")
        }
        let current = groups[index]
        guard current.revision == expectedRevision else {
            throw AgentAssignmentViolation(subject: "group \(group.id)",
                                           rule: "Stale group revision \(expectedRevision); the ledger holds \(current.revision).")
        }
        guard current.openerSessionID == group.openerSessionID else {
            throw AgentAssignmentViolation(subject: "group \(group.id)", rule: "A group keeps its opener.")
        }
        if current == group { return self }
        guard group.revision > current.revision else {
            throw AgentAssignmentViolation(subject: "group \(group.id)",
                                           rule: "An update needs a newer group revision than \(current.revision).")
        }
        var next = self
        next.groups[index] = group
        return next
    }

    /// Records the group's final account once per group revision. The same
    /// account again is a no-op; another revision's account is outdated; a
    /// rewritten account for the same revision is refused.
    public func recordingFinalAccount(_ account: AgentAssignmentFinalAccount) throws -> Self {
        try account.validate()
        guard let group = group(account.groupID) else {
            throw AgentAssignmentViolation(subject: "final account \(account.eventID)",
                                           rule: "The ledger does not hold this group.")
        }
        guard group.revision == account.groupRevision else {
            throw AgentAssignmentViolation(subject: "final account \(account.eventID)",
                                           rule: "Outdated account for revision \(account.groupRevision); the group is at \(group.revision) and owes a fresh one.")
        }
        let expected = try group.makeFinalAccount()
        guard account == expected else {
            throw AgentAssignmentViolation(subject: "final account \(account.eventID)",
                                           rule: "The account is not this group revision's snapshot.")
        }
        if let existing = finalAccounts.first(where: { $0.eventID == account.eventID }) {
            guard existing == account else {
                throw AgentAssignmentViolation(subject: "final account \(account.eventID)",
                                               rule: "An account with this ID already exists with other content.")
            }
            return self
        }
        var next = self
        next.finalAccounts.append(account)
        return next
    }

    public func validate() throws {
        var ids = Set<String>()
        for group in groups {
            try group.validate()
            guard ids.insert(group.id).inserted else {
                throw AgentAssignmentViolation(subject: "group \(group.id)", rule: "The ledger lists this group twice.")
            }
        }
        var events = Set<String>()
        for account in finalAccounts {
            try account.validate()
            guard events.insert(account.eventID).inserted else {
                throw AgentAssignmentViolation(subject: "final account \(account.eventID)", rule: "The ledger lists this event twice.")
            }
        }
    }
}

/// A ledger refusal. It names the subject and the rule; the caller decides
/// whether it is a stale report, an unauthorised review or a corrupt record.
public struct AgentAssignmentViolation: Error, LocalizedError, Sendable, Equatable {
    public var subject: String
    public var rule: String

    public init(subject: String, rule: String) {
        self.subject = subject
        self.rule = rule
    }

    public var errorDescription: String? {
        "\(subject): \(rule)"
    }
}

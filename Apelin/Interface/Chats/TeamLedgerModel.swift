import ApelinProtocol
import Foundation

/// The team of one conversation, as the host's assignment ledger holds it:
/// which conversations it opened, what each was asked to do, what each claims
/// it produced, what the host has checked, and what is still missing.
///
/// It is a reading of the ledger and nothing else. A child's turn that
/// finished is a claim (`readyForReview`), never an acceptance: only the
/// ledger's own state and verification say what was verified, and this model
/// never computes them another way.
struct TeamLedgerModel: Equatable {
    struct Check: Equatable {
        var criterion: String
        var passed: Bool
    }

    struct Member: Equatable {
        var id: String
        var childSessionID: String
        var objective: String
        var state: AgentAssignment.State
        var verification: AgentAssignment.Verification
        /// What the child says it produced, in its own words.
        var claims: [String]
        var checks: [Check]
        var missingChecks: [String]
        var blockers: [String]

        /// A conversation an agent opened is named by a session ID, and that
        /// is what opens it.
        var opens: Bool {
            UUID(uuidString: childSessionID) != nil
        }
    }

    struct Group: Equatable {
        var id: String
        var revision: UInt64
        var isSealed: Bool
        var members: [Member]

        var acceptedCount: Int {
            members.filter { $0.state == .accepted }.count
        }

        var unfinishedCount: Int {
            members.filter { !$0.state.isTerminal }.count
        }

        var unverifiedAcceptedCount: Int {
            members.filter { $0.state == .accepted && $0.verification == .unverified }.count
        }
    }

    var groups: [Group]

    /// `sessionID` is the conversation whose team this is. The host answers
    /// with its own ledger, and a group another conversation opened is not
    /// shown here — a member is never guessed from the app's local children.
    init(ledger: AgentAssignmentLedger, sessionID: String) {
        groups = ledger.groups
            .filter { $0.openerSessionID == sessionID }
            .map { group in
                Group(
                    id: group.id,
                    revision: group.revision,
                    isSealed: group.isSealed,
                    members: group.assignments.map { assignment in
                        Member(
                            id: assignment.id,
                            childSessionID: assignment.origin.childSessionID,
                            objective: assignment.objective,
                            state: assignment.state,
                            verification: assignment.verification,
                            claims: assignment.outputs.map { output in
                                output.path.map { "\(output.summary) — \($0)" } ?? output.summary
                            },
                            checks: assignment.currentChecks.map { check in
                                Check(criterion: check.criterion, passed: check.passed)
                            },
                            missingChecks: assignment.missingChecks,
                            blockers: assignment.blockers.map { blocker in
                                blocker.needs.map { "\(blocker.reason) — \($0)" } ?? blocker.reason
                            }
                        )
                    }
                )
            }
    }

    var isEmpty: Bool {
        groups.isEmpty
    }

    var memberCount: Int {
        groups.reduce(0) { $0 + $1.members.count }
    }
}

import struct ApelinProtocol.AgentQuestionAnswer
import enum ApelinProtocol.AgentQuestionRules
import Foundation
import KWWKAI

public enum ApprovalError: Error, Equatable, LocalizedError {
    case unknownRequest
    /// An answer that is not one to the request's question, or an answer
    /// to a request that asked none.
    case answerDoesNotFit
    public var errorDescription: String? {
        switch self {
        case .unknownRequest: "This approval request is no longer waiting for a decision."
        case .answerDoesNotFit: "This answer does not fit the question."
        }
    }
}

/// Holds the calls waiting for a decision. A waiting call resumes only on
/// `resolve` or cancellation (abort): an app that is not connected leaves it
/// waiting, and nothing approves by default.
actor ApprovalGate {
    private var waiting: [String: (
        request: ApprovalRequest,
        continuation: CheckedContinuation<ApprovalDecision, Never>,
    )] = [:]
    /// The answers given to questions, from `resolve` until `ask` takes them.
    private var answers: [String: AgentQuestionAnswer] = [:]
    private var sessionFingerprints: Set<String> = []
    private let emit: @Sendable (AgentSessionEvent) async -> Void

    init(emit: @escaping @Sendable (AgentSessionEvent) async -> Void) {
        self.emit = emit
    }

    var pending: [ApprovalRequest] {
        waiting.values.map(\.request).sorted { $0.id < $1.id }
    }

    func isRemembered(_ fingerprint: String) -> Bool {
        sessionFingerprints.contains(fingerprint)
    }

    /// Emits `approvalRequested` and suspends until a decision arrives.
    func request(_ request: ApprovalRequest, cancellation: CancellationHandle?) async -> ApprovalDecision {
        await emit(.approvalRequested(request))
        let id = request.id
        let registration = cancellation?.onCancel { reason in
            Task { await self.cancel(id, reason: reason ?? "aborted") }
        }
        defer { registration?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancellation?.isCancelled == true || Task.isCancelled {
                    continuation.resume(returning: .deny(reason: "aborted"))
                    Task { await self.emit(.approvalResolved(requestID: id, decision: .deny(reason: "aborted"))) }
                    return
                }
                waiting[id] = (request, continuation)
            }
        } onCancel: {
            Task { await self.cancel(id, reason: "aborted") }
        }
    }

    func resolve(_ id: String, decision: ApprovalDecision, answer: AgentQuestionAnswer? = nil) async throws {
        guard let entry = waiting[id] else { throw ApprovalError.unknownRequest }
        // A question is answered with approve and an answer that fits it,
        // or skipped with deny; nothing else carries an answer. Refused
        // before anything is taken, so the question goes on waiting.
        if case let .question(question) = entry.request.detail {
            if case .approve = decision {
                guard let answer, AgentQuestionRules.accepts(answer, for: question) else {
                    throw ApprovalError.answerDoesNotFit
                }
                answers[id] = answer
            }
        } else if answer != nil {
            throw ApprovalError.answerDoesNotFit
        }
        waiting[id] = nil
        if case .approve(.session) = decision, entry.request.allowsSessionScope {
            sessionFingerprints.insert(entry.request.fingerprint)
        }
        await emit(.approvalResolved(requestID: id, decision: decision))
        entry.continuation.resume(returning: decision)
    }

    /// Asks a question (`detail.question`) and waits: the reader's answer,
    /// or nil when they skipped it or the run was stopped.
    func ask(_ request: ApprovalRequest, cancellation: CancellationHandle?) async -> AgentQuestionAnswer? {
        let decision = await self.request(request, cancellation: cancellation)
        let answer = answers.removeValue(forKey: request.id)
        guard case .approve = decision else { return nil }
        return answer
    }

    func cancel(_ id: String, reason: String) async {
        guard let entry = waiting.removeValue(forKey: id) else { return }
        let decision = ApprovalDecision.deny(reason: reason)
        await emit(.approvalResolved(requestID: id, decision: decision))
        entry.continuation.resume(returning: decision)
    }

    func cancelAll(reason: String) async {
        for id in waiting.keys.sorted() {
            await cancel(id, reason: reason)
        }
    }
}

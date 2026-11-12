import ApelinCore
import ApelinProtocol
import Foundation

/// A choice, never credentials. Resolved only when this input starts a run.
public struct PendingModelChoice: Sendable, Hashable, Codable {
    public var provider: ProviderConfiguration
    public var wireProvider: AgentProvider?
    public var model: String?
    public var reasoningEffort: AgentReasoningEffort?
    public var serviceTier: AgentServiceTier?
    public var parameters: AgentModelParameters
    public var defaults: AgentModelDefaults?

    public init(provider: ProviderConfiguration, wireProvider: AgentProvider? = nil, model: String? = nil,
                reasoningEffort: AgentReasoningEffort? = nil, serviceTier: AgentServiceTier? = nil,
                parameters: AgentModelParameters = .init(), defaults: AgentModelDefaults? = nil) {
        self.provider = provider
        self.wireProvider = wireProvider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.parameters = parameters
        self.defaults = defaults
    }
}

public struct PendingMessage: Sendable, Hashable, Codable {
    public var id: UUID
    public var text: String
    public var attachments: [AgentAttachment]
    public var editing: Bool = false
    public var modelChoice: PendingModelChoice?
    public var sender: ConversationSender?
    public var delivery: AgentMessageDelivery?

    public init(id: UUID, text: String, attachments: [AgentAttachment], editing: Bool = false,
                sender: ConversationSender? = nil, delivery: AgentMessageDelivery? = nil, modelChoice: PendingModelChoice? = nil) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.editing = editing
        self.sender = sender
        self.delivery = delivery
        self.modelChoice = modelChoice
    }
}

/// Owned only by AgentSession. No suspension between validation, durable commit
/// and publishing the new value. A failed write leaves the old value intact.
struct PendingQueue {
    struct State: Codable, Equatable {
        var messages: [PendingMessage] = []
        var paused = false
        var seen: Set<UUID> = []
        // A crash between taking and recording a prompt must not lose the input.
        var handoffs: [PendingMessage] = []
    }

    private let root: ScopedRoot
    private(set) var state: State
    private(set) var revision: UInt64 = 0

    init(directory: URL, taken: Set<UUID>) throws {
        root = try ScopedRoot(directory)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending.json").path) {
            // Fail closed on damaged state; never replace unreadable input with an empty queue.
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: URL(fileURLWithPath: root.resolveExisting("pending.json"))))
            let ids = (state.messages + state.handoffs).map(\.id)
            guard Set(ids).count == ids.count, Set(ids).isSubset(of: state.seen) else {
                throw ApelinError(.conflict, "The saved pending queue has inconsistent message identifiers.")
            }
            let recovered = state.handoffs.filter { !taken.contains($0.id) }
            state.messages = recovered + state.messages.filter { !taken.contains($0.id) }
            // An editor belonged to the previous app/session. Keep the queue
            // paused, but do not resurrect a hold that no live sheet can release.
            for index in state.messages.indices { state.messages[index].editing = false }
            state.handoffs = []
            state.paused = !state.messages.isEmpty
            try persist(state)
        } else {
            state = State()
        }
    }

    private func persist(_ next: State) throws {
        try root.resolveForWrite("pending.json").commit(JSONEncoder().encode(next), exclusive: false)
    }

    mutating func update(_ body: (inout State) throws -> Void) throws {
        var next = state
        try body(&next)
        try persist(next)
        state = next
        revision &+= 1
    }

    mutating func enqueue(_ message: PendingMessage) throws {
        guard !state.seen.contains(message.id) else { return }
        try update {
            $0.seen.insert(message.id)
            $0.messages.append(message)
        }
    }

    /// Reserve idle reader input directly for dispatch, never in messages.
    /// The durable handoff protects a crash during preparation just as take
    /// protects a queued dispatch. Later arrivals must wait behind this one.
    mutating func beginDirect(_ message: PendingMessage) throws {
        guard state.messages.isEmpty, state.handoffs.isEmpty,
              !state.seen.contains(message.id) else {
            throw ApelinError(.conflict, "Direct input requires an empty queue and no outstanding handoff.")
        }
        try update {
            $0.seen.insert(message.id)
            $0.handoffs.append(message)
            $0.paused = false
        }
    }

    mutating func change(_ request: AgentQueueRequest) throws {
        try update { state in
            switch request.action {
            case .reorder:
                guard let order = request.order, order.count == state.messages.count,
                      Set(order).count == order.count, Set(order) == Set(state.messages.map(\.id)) else {
                    throw ApelinError(.conflict, "The pending queue changed; refresh it before reordering.")
                }
                let byID = Dictionary(uniqueKeysWithValues: state.messages.map { ($0.id, $0) })
                state.messages = order.compactMap { byID[$0] }
            case .resume where request.messageID == nil:
                state.paused = false
            case .steer:
                break // The session takes this message only after preparing it.
            case .edit, .delete, .hold, .resume:
                guard let id = request.messageID,
                      let index = state.messages.firstIndex(where: { $0.id == id }) else {
                    throw ApelinError(.conflict, "The message is no longer pending.")
                }
                switch request.action {
                case .edit:
                    guard let text = request.text, text.count <= AgentHistoryRules.maximumEditLength,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !state.messages[index].attachments.isEmpty else {
                        throw ApelinError(.badRequest, "Invalid pending message text.")
                    }
                    state.messages[index].text = text
                    state.messages[index].editing = false
                case .delete: state.messages.remove(at: index)
                case .hold: state.messages[index].editing = true
                case .resume: state.messages[index].editing = false
                default: break
                }
            }
        }
    }

    mutating func take(_ id: UUID) throws -> PendingMessage {
        guard let message = state.messages.first(where: { $0.id == id && !$0.editing }) else {
            throw ApelinError(.conflict, "The message is no longer pending.")
        }
        try update {
            $0.messages.removeAll { $0.id == id }
            $0.handoffs.append(message)
        }
        return message
    }

    mutating func acknowledge(_ id: UUID) throws {
        try update { $0.handoffs.removeAll { $0.id == id } }
    }
}

import LurosAgent
import LurosCore
import LurosProtocol
import Foundation

public extension ChannelHostBackend {
    // MARK: logs and crashes

    func readLogs(_ request: ReadLogsRequest) async throws -> ReadLogsResponse {
        let limit = min(5000, max(1, request.limit))
        let filter = LurosProtocol.LogFilter(
            subsystem: request.subsystem,
            process: request.process,
            limit: limit,
            windowSeconds: Double(min(ReadLogsRequest.maximumListenSeconds, max(1, request.listenSeconds))),
        )
        let first = try await service.logStream(LogStreamRequest(filter: filter, waitMilliseconds: 0))
        var entries: [LurosAgent.LogEntry] = []
        var truncated = false
        func take(_ event: TaskEvent) {
            switch event.kind {
            case "log":
                guard entries.count < limit else { truncated = true; return }
                if let entry = Self.logEntry(event) {
                    entries.append(entry)
                }
            case "truncated":
                truncated = true
            default:
                break
            }
        }
        first.events.forEach(take)
        if !first.finished {
            for try await event in service.events(of: TaskHandle(taskID: first.taskID, kind: .logStream), afterSeq: first.lastSeq) {
                take(event)
            }
        }
        return ReadLogsResponse(entries: entries, truncated: truncated)
    }

    internal static func logEntry(_ event: TaskEvent) -> LurosAgent.LogEntry? {
        guard let payload = event.payload, let message = payload["message"]?.stringValue else { return nil }
        let date = payload["time"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) } ?? event.time
        let subsystem = payload["subsystem"]?.stringValue
        return LurosAgent.LogEntry(
            date: date,
            process: payload["process"]?.stringValue ?? "",
            subsystem: subsystem?.isEmpty == true ? nil : subsystem,
            level: payload["level"]?.stringValue ?? "default",
            message: message,
        )
    }

    func listCrashes(_ request: ListCrashesRequest) async throws -> ListCrashesResponse {
        let list = try await service.crashList(process: request.process)
        return ListCrashesResponse(reports: list.reports.prefix(max(1, request.limit)).map {
            CrashSummary(id: $0.id, process: $0.process, date: $0.date, exceptionType: $0.exceptionType)
        })
    }

    func readCrash(_ request: ReadCrashRequest) async throws -> ReadCrashResponse {
        let (response, descriptor) = try await service.crashOpen(id: request.reportID)
        guard let descriptor else { throw LurosError(.internal, "the host returned no file for the crash report") }
        defer { descriptor.close() }
        let budget = min(max(1, request.maxBytes), 4 * 1024 * 1024)
        let data = try Self.read(descriptor.rawValue, upTo: budget)
        return ReadCrashResponse(
            reportID: request.reportID,
            text: String(decoding: data, as: UTF8.self),
            truncated: Int64(data.count) < response.size,
        )
    }

    func symbolicateCrash(_ request: SymbolicateCrashRequest) async throws -> SymbolicateCrashResponse {
        let response = try await service.crashSymbolicate(id: request.reportID, projectID: project.id)
        return SymbolicateCrashResponse(
            reportID: response.id,
            matchedImageUUID: response.matchedImageUUIDs.first,
            crashedThread: response.crashedThread.map {
                LurosAgent.SymbolicatedFrame(
                    index: $0.index,
                    image: $0.image,
                    address: $0.address,
                    symbol: $0.symbol,
                    file: $0.file,
                    line: $0.line,
                )
            },
            suspects: response.suspects,
        )
    }

    // MARK: UI

    func captureScreen(
        _ request: LurosAgent.CaptureScreenRequest,
    ) async throws -> LurosAgent.CaptureScreenResponse {
        let (response, descriptor) = try await service.captureScreen(targetID: request.targetID)
        guard let descriptor else { throw LurosError(.internal, "the host returned no file for the screenshot") }
        defer { descriptor.close() }
        let data = try Self.read(descriptor.rawValue, upTo: Self.maximumScreenshotBytes)
        return LurosAgent.CaptureScreenResponse(
            attachmentID: UUID().uuidString.lowercased(),
            mimeType: data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg",
            width: response.width,
            height: response.height,
            imageData: data,
        )
    }

    func readUITree(_ request: LurosAgent.ReadUITreeRequest) async throws -> LurosAgent.ReadUITreeResponse {
        let response = try await service.readUITree(targetID: request.targetID)
        return LurosAgent.ReadUITreeResponse(root: Self.tree(response.tree))
    }

    /// The diagnostics worker's flat element list as one root with children.
    /// An element's id is its accessibility identifier, or `text:<label>`.
    internal static func tree(_ json: LurosCore.JSONValue) -> UIElementNode {
        var children: [UIElementNode] = []
        if case let .array(elements)? = json["elements"] {
            for (index, element) in elements.enumerated() {
                let identifier = element["identifier"]?.stringValue ?? ""
                let label = element["label"]?.stringValue ?? ""
                let frame = element["frame"]
                children.append(UIElementNode(
                    id: !identifier.isEmpty ? identifier : (!label.isEmpty ? "text:\(label)" : "index:\(index)"),
                    role: element["role"]?.stringValue ?? "",
                    label: label.isEmpty ? nil : label,
                    value: element["value"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    frame: ["x", "y", "width", "height"].map { frame?[$0]?.doubleValue ?? 0 },
                ))
            }
        }
        let pid = json["pid"]?.doubleValue.map { Int($0) } ?? 0
        return UIElementNode(id: "screen", role: "application", label: pid > 0 ? "pid \(pid)" : nil, children: children)
    }

    func uiAction(_ request: LurosAgent.UIActionRequest) async throws -> LurosAgent.UIActionResponse {
        let response = try await service.uiAction(Self.action(request.action), targetID: request.targetID)
        // A wake answers the lock state, a type what it read back; no
        // action answers both.
        let message = [Self.afterWake(response), Self.readBackMessage(response)].filter { !$0.isEmpty }
        return LurosAgent.UIActionResponse(
            performed: true,
            message: message.joined(separator: " "),
            typedTextMatches: response.typedTextMatches,
            fieldValues: response.fieldValues,
        )
    }

    /// What a wake left, in words the model acts on; empty after any other
    /// action, which answers neither.
    internal static func afterWake(_ response: LurosProtocol.UIActionResponse) -> String {
        if response.screenOff == true {
            return "The screen is still off. Press wake once more; if it stays off, ask the user to wake the device."
        }
        if response.locked == true {
            return "The screen is on, but the device is still locked: a device with a passcode stays on its lock screen after a wake. For anything past the lock screen, ask the user to unlock the device, and never ask for or type the passcode."
        }
        if response.locked == false {
            return "The screen is on and the device is unlocked."
        }
        return ""
    }

    /// What to do when the text read back is not the text typed.
    internal static func readBackMessage(_ response: LurosProtocol.UIActionResponse) -> String {
        guard response.typedTextMatches == false else { return "" }
        if response.fieldValues?.isEmpty ?? true {
            return "No field changed: the text did not go in. Tap the field to focus it, then type again."
        }
        return "The fields that changed do not hold the typed text; fieldValues is what they hold now. Correct it before going on."
    }

    internal static func action(_ action: LurosAgent.UIAction) throws -> LurosProtocol.UIAction {
        switch action {
        case let .tap(x, y): return .tap(x: x, y: y)
        case let .tapElement(id):
            if id.hasPrefix("text:") {
                return .tapElement(text: String(id.dropFirst(5)), identifier: nil)
            }
            if id.hasPrefix("index:") {
                throw LurosError(
                    .badRequest,
                    "that element has no identifier or text to tap it by; tap its frame instead",
                )
            }
            return .tapElement(text: nil, identifier: id)
        case let .typeText(text): return .type(text: text)
        case let .swipe(fromX, fromY, toX, toY, durationMilliseconds):
            return .swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMilliseconds: durationMilliseconds)
        case let .pressButton(button): return .press(button: button)
        }
    }
}

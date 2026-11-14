import ApelinWeChat
import Foundation

private func storedCursor(_ store: IlinkSessionStore) -> String? {
    do {
        guard case .present(let session) = try store.read() else { return nil }
        return session.cursor
    } catch {
        return nil
    }
}

private func updatesRequests(_ transport: FakeTransport) -> [IlinkHTTPRequest] {
    transport.requests.filter { $0.url.path == "/ilink/bot/getupdates" }
}

private func cursorBody(_ request: IlinkHTTPRequest) throws -> String? {
    let body = try jsonObject(request.body)
    return body["get_updates_buf"] as? String
}

/// The long poll: delivery, the echo and duplicate filters, the cursor that
/// moves only after the batch was delivered and the file written, and a stop
/// that no later round revives.
func checkIlinkPolling() async throws {
    let folder = try makeTemporaryFolder("polling")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))
    try store.write(makeSession(cursor: "cursor-0"))

    let round = LockedBox(0)
    let transport = FakeTransport { request in
        guard request.url.path == "/ilink/bot/getupdates" else {
            throw IlinkFailure.invalidResponse("unexpected path")
        }
        let index = round.read()
        round.update { $0 += 1 }
        switch index {
        case 0:
            return httpResponse(
                200,
                #"{"ret":0,"get_updates_buf":"cursor-1","msgs":[{"from_user_id":"peer-1","to_user_id":"bot-1","message_id":7527228441904002056,"item_list":[{"type":1,"text_item":{"text":"hello"}}],"context_token":"ctx-1"},{"from_user_id":"bot-1","to_user_id":"peer-1","message_id":99,"item_list":[{"type":1,"text_item":{"text":"echo"}}]},{"from_user_id":"peer-1","to_user_id":"bot-1","message_id":7527228441904002056,"item_list":[{"type":1,"text_item":{"text":"duplicate"}}]}]}"#
            )
        case 1:
            // No get_updates_buf: the previous cursor stays.
            return httpResponse(
                200,
                #"{"ret":0,"msgs":[{"from_user_id":"peer-1","to_user_id":"bot-1","message_id":100,"item_list":[{"type":1,"text_item":{"text":"second"}}]}]}"#
            )
        default:
            return httpResponse(200, #"{"ret":0,"get_updates_buf":"cursor-2","msgs":[]}"#)
        }
    }

    let client = IlinkClient(transport: transport, store: store)
    try await client.restoreSession()
    let stream = await client.updates()
    var iterator = stream.makeAsyncIterator()
    try await client.startUpdates()

    // The rounds run as fast as the fake transport answers; the cursor rule is
    // read off the request sequence, not off an intermediate file state.
    try await waitFor("the committed cursor") {
        storedCursor(store) == "cursor-2"
    }
    let first = try await iterator.next()
    try expectEqual(first?.text, "hello", "the text is delivered")
    try expectEqual(first?.id.raw, "7527228441904002056", "the uint64 id is exact")
    try expectEqual(first?.peer.id, "peer-1", "the peer")
    let token = await client.contextToken(for: IlinkPeer(id: "peer-1"))
    try expectEqual(token, "ctx-1", "the context token is kept per peer")

    let second = try await iterator.next()
    try expectEqual(second?.text, "second", "the second message")
    let asks = updatesRequests(transport)
    guard asks.count >= 3 else {
        throw CheckFailure(message: "three rounds must have been asked")
    }
    try expectEqual(try cursorBody(asks[0]), "cursor-0", "the first round asks with the stored cursor")
    try expectEqual(try cursorBody(asks[1]), "cursor-1", "the second round asks with the committed cursor")
    try expectEqual(try cursorBody(asks[2]), "cursor-1", "a reply without get_updates_buf keeps the cursor")
    let openingBody = try jsonObject(asks[0].body)
    let base = try expectValue(openingBody["base_info"] as? [String: Any], "getupdates base_info")
    try expectEqual(base["channel_version"] as? String, "2.4.10", "getupdates channel_version")
    try expectEqual(base["bot_agent"] as? String, "apelin", "getupdates bot_agent")

    guard case .present(let saved) = try store.read() else {
        throw CheckFailure(message: "the session is still there")
    }
    try expectEqual(saved.cursor, "cursor-2", "the last cursor is committed")
    try expectEqual(saved.contextTokens["peer-1"], "ctx-1", "the context token is persisted")

    await client.stop()
    let requestsAtStop = transport.requests.count
    try await Task.sleep(nanoseconds: 150_000_000)
    try expectEqual(transport.requests.count, requestsAtStop, "a stopped poll loop is not revived")
    let stopped = await client.state
    try expectEqual(stopped, IlinkClientState.stopped, "the state after stop")

    // A restart is a new generation, and it asks with the committed cursor.
    try await client.startUpdates()
    try await waitFor("the restarted loop polls") {
        transport.requests.count > requestsAtStop
    }
    guard let restarted = updatesRequests(transport).last else {
        throw CheckFailure(message: "the restarted loop must ask")
    }
    try expectEqual(try cursorBody(restarted), "cursor-2", "the restart asks with the committed cursor")
    await client.stop()
}

/// A reply the whole-body decoder rejects still yields every message that
/// decodes on its own.
func checkIlinkParseFallback() async throws {
    let folder = try makeTemporaryFolder("fallback")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))
    try store.write(makeSession(cursor: "c0"))

    let transport = FakeTransport { request in
        httpResponse(
            200,
            #"{"ret":0,"get_updates_buf":"c1","msgs":[{"from_user_id":"peer-1","to_user_id":"bot-1","message_id":1,"item_list":"not-a-list"},{"from_user_id":"peer-1","to_user_id":"bot-1","message_id":2,"item_list":[{"type":1,"text_item":{"text":"ok"}}]}]}"#
        )
    }
    let client = IlinkClient(transport: transport, store: store)
    try await client.restoreSession()
    let stream = await client.updates()
    var iterator = stream.makeAsyncIterator()
    try await client.startUpdates()
    try await waitFor("the good message committed") {
        storedCursor(store) == "c1"
    }
    let message = try await iterator.next()
    try expectEqual(message?.text, "ok", "the readable message is delivered")
    try expectEqual(message?.id.raw, "2", "its id")
    await client.stop()
}

/// Only `ret != 0` is a failed round, the backoff doubles from 2 s, and the
/// loop stops after the configured number of failures. A read timeout is an
/// empty round instead.
func checkIlinkPollingFailures() async throws {
    let folder = try makeTemporaryFolder("failures")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))
    try store.write(makeSession(cursor: "c0"))

    let delays = LockedBox<[Int]>([])
    let failing = FakeTransport { _ in
        throw IlinkFailure.http(status: 502)
    }
    let configuration = IlinkConfiguration(
        requestTimeout: 1,
        maxConsecutiveFailures: 3,
        backoff: IlinkBackoff(initial: 2, maximum: 60)
    )
    let client = IlinkClient(
        configuration: configuration,
        transport: failing,
        store: store,
        sleeper: { duration in
            delays.update { $0.append(Int(duration.components.seconds)) }
        }
    )
    try await client.restoreSession()
    let stream = await client.updates()
    var iterator = stream.makeAsyncIterator()
    try await client.startUpdates()
    try await waitFor("the poll loop to give up") {
        let state = await client.state
        if case .failed = state { return true }
        return false
    }
    try expectEqual(delays.read(), [2, 4], "the backoff doubles from 2 s and stops before a third wait")
    let state = await client.state
    try expectEqual(state, IlinkClientState.failed(.tooManyFailures(attempts: 3)), "the state names the failure")
    do {
        _ = try await iterator.next()
        throw CheckFailure(message: "the stream must end with the failure")
    } catch let failure as IlinkFailure {
        try expectEqual(failure, .tooManyFailures(attempts: 3), "the stream carries the failure")
    }

    // A timed-out long poll is an ordinary empty round.
    let hot = LockedBox(0)
    var timedConfiguration = IlinkConfiguration(maxConsecutiveFailures: 2)
    timedConfiguration.longPollTimeout = 1
    let timedDelays = LockedBox<[Int]>([])
    let timingOut = FakeTransport { request in
        let index = hot.read()
        hot.update { $0 += 1 }
        if index < 2 { throw IlinkFailure.timedOut }
        return httpResponse(
            200,
            #"{"ret":0,"get_updates_buf":"c1","msgs":[{"from_user_id":"peer-1","to_user_id":"bot-1","message_id":7,"item_list":[{"type":1,"text_item":{"text":"after timeouts"}}]}]}"#
        )
    }
    let patient = IlinkClient(
        configuration: timedConfiguration,
        transport: timingOut,
        store: store,
        sleeper: { duration in
            timedDelays.update { $0.append(Int(duration.components.seconds)) }
        }
    )
    try await patient.restoreSession()
    let patientStream = await patient.updates()
    var patientIterator = patientStream.makeAsyncIterator()
    try await patient.startUpdates()
    try await waitFor("the message after the timeouts") {
        storedCursor(store) == "c1"
    }
    let message = try await patientIterator.next()
    try expectEqual(message?.text, "after timeouts", "a timeout did not count as a failure")
    try expect(timedDelays.read().isEmpty, "a timeout never waited out a backoff")
    let patientState = await patient.state
    try expectEqual(patientState, IlinkClientState.running, "the loop keeps running")
    await patient.stop()
}

/// A cursor is committed only once the file was written.
func checkIlinkCursorNeedsTheWrite() async throws {
    struct FailingWriteStore: IlinkSessionStore {
        let inner: IlinkFileSessionStore

        func read() throws -> IlinkStoredSession {
            try inner.read()
        }

        func write(_ session: IlinkSession) throws {
            throw IlinkFailure.sessionUnwritable(path: "denied")
        }

        func discard() throws {
            try inner.discard()
        }
    }

    let folder = try makeTemporaryFolder("cursor-write")
    defer { try? FileManager.default.removeItem(at: folder) }
    let inner = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))
    try inner.write(makeSession(cursor: "cursor-0"))
    let store = FailingWriteStore(inner: inner)

    let transport = FakeTransport { _ in
        httpResponse(
            200,
            #"{"ret":0,"get_updates_buf":"cursor-1","msgs":[{"from_user_id":"peer-1","to_user_id":"bot-1","message_id":5,"item_list":[{"type":1,"text_item":{"text":"hello"}}]}]}"#
        )
    }
    let client = IlinkClient(transport: transport, store: store)
    try await client.restoreSession()
    let stream = await client.updates()
    var iterator = stream.makeAsyncIterator()
    try await client.startUpdates()
    let message = try await iterator.next()
    try expectEqual(message?.text, "hello", "the message is delivered even when the file cannot be written")
    try await waitFor("a second round") {
        updatesRequests(transport).count >= 2
    }
    for request in updatesRequests(transport).dropFirst() {
        try expectEqual(try cursorBody(request), "cursor-0", "the cursor did not move without a write")
    }
    try expectEqual(storedCursor(inner), "cursor-0", "the file still holds the old cursor")
    await client.stop()
}

/// `ret` is the only failure field: a non-zero `errcode` in a normal reply is
/// not one, and `ret != 0` is.
func checkIlinkRetSemantics() async throws {
    let folder = try makeTemporaryFolder("ret")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = IlinkFileSessionStore(fileURL: folder.appendingPathComponent("session.json"))
    try store.write(makeSession(cursor: "c0"))

    let normal = FakeTransport { _ in
        httpResponse(200, #"{"ret":0,"errcode":9,"errmsg":"a notice","get_updates_buf":"c1","msgs":[]}"#)
    }
    let client = IlinkClient(transport: normal, store: store)
    try await client.restoreSession()
    try await client.startUpdates()
    try await waitFor("a couple of normal rounds") {
        storedCursor(store) == "c1" && updatesRequests(normal).count >= 2
    }
    let running = await client.state
    try expectEqual(running, IlinkClientState.running, "a non-zero errcode with ret 0 is a normal round")
    await client.stop()

    let delays = LockedBox<[Int]>([])
    let rejected = FakeTransport { _ in
        httpResponse(200, #"{"ret":7,"errcode":0,"errmsg":"refused"}"#)
    }
    let failing = IlinkClient(
        configuration: IlinkConfiguration(maxConsecutiveFailures: 2),
        transport: rejected,
        store: store,
        sleeper: { duration in
            delays.update { $0.append(Int(duration.components.seconds)) }
        }
    )
    try await failing.restoreSession()
    try await failing.startUpdates()
    try await waitFor("the ret failure") {
        let state = await failing.state
        if case .failed = state { return true }
        return false
    }
    let failedState = await failing.state
    try expectEqual(
        failedState,
        IlinkClientState.failed(.tooManyFailures(attempts: 2)),
        "ret != 0 counts as a failed round"
    )
    try expectEqual(delays.read(), [2], "the single wait before the last round")
}

/// A file that does not read is reported, not taken for a logout, and only
/// `discardSession()` clears it.
func checkIlinkUnreadableSession() async throws {
    let folder = try makeTemporaryFolder("unreadable")
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("session.json")
    let broken = Data("not a session".utf8)
    try broken.write(to: url)
    let store = IlinkFileSessionStore(fileURL: url)
    let client = IlinkClient(transport: FakeTransport { _ in httpResponse(200, "{}") }, store: store)

    do {
        try await client.restoreSession()
        throw CheckFailure(message: "an unreadable session must be reported")
    } catch let failure as IlinkFailure {
        guard case .sessionUnreadable = failure else { throw failure }
    }
    try expectEqual(try Data(contentsOf: url), broken, "the file is left as it was")
    do {
        _ = try await client.send(text: "hi", to: IlinkPeer(id: "peer-1"))
        throw CheckFailure(message: "an unreadable session is not a login")
    } catch let failure as IlinkFailure {
        try expectEqual(failure, IlinkFailure.notLoggedIn, "sending without a session is refused")
    }

    try await client.discardSession()
    guard case .absent = try store.read() else {
        throw CheckFailure(message: "discardSession clears the file")
    }
    try expectEqual(try await client.restoreSession(), false, "nothing to restore afterwards")
}

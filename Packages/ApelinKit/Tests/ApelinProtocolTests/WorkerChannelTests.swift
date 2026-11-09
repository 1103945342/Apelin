import ApelinCore
@testable import ApelinProtocol
import Darwin
import Foundation
import XCTest

final class WorkerChannelTests: XCTestCase {
    func testAnErrorReplyKeepsItsReason() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        let worker = WorkerChannel(adopting: b)
        defer { host.close(); worker.close() }
        host.onRequest { request in
            let reasoned = request.request.requestID == "with-reason"
            let error = reasoned ? RunCodeApproval.presetRefusal : ApelinError(.denied, "no reason")
            return (.failure(request.request.requestID, error), [])
        }
        host.start()
        worker.start()

        var request = try WireRequest(ProjectCheckRequest(projectID: "p"))
        request.requestID = "with-reason"
        let (reasoned, _) = try await worker.call(request)
        XCTAssertEqual(reasoned.result.failureValue?.reason, .notAPreset)
        XCTAssertEqual(reasoned.result.failureValue?.code, .denied)
        request.requestID = "without"
        let (plain, _) = try await worker.call(request)
        XCTAssertNil(plain.result.failureValue?.reason)

        // A peer that predates the field, and one that names a reason this
        // build does not know, both still decode.
        let old = try JSONCoding.decode(ApelinError.self, from: Data(#"{"code":"denied","message":"m"}"#.utf8))
        XCTAssertEqual(old, ApelinError(.denied, "m"))
        let newer = try JSONCoding.decode(
            ApelinError.self,
            from: Data(#"{"code":"denied","message":"m","reason":"later"}"#.utf8),
        )
        XCTAssertEqual(newer.reason?.rawValue, "later")
        XCTAssertFalse(try String(decoding: JSONCoding.encode(old), as: UTF8.self).contains("reason"))
    }

    func testRequestReplyWithDescriptorsBothWays() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        let worker = WorkerChannel(adopting: b)
        defer { host.close(); worker.close() }

        worker.onRequest { request in
            // Read what the host passed, answer with a descriptor of our own.
            var byte: UInt8 = 0
            let fd = request.descriptors.first?.rawValue ?? -1
            lseek(fd, 0, SEEK_SET)
            _ = read(fd, &byte, 1)
            let pipeEnds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
            defer { pipeEnds.deallocate() }
            pipe(pipeEnds)
            var reply: UInt8 = byte + 1
            _ = write(pipeEnds[1], &reply, 1)
            close(pipeEnds[1])
            return (.success(request.request.requestID, ProjectCheckResponse(passed: request.taskID == TaskID("t1"))), [OwnedDescriptor(adopting: pipeEnds[0])])
        }
        host.start()
        worker.start()

        let path = NSTemporaryDirectory() + "apelin-channel-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: path, contents: Data([41]))
        defer { unlink(path) }
        let file = OwnedDescriptor(adopting: open(path, O_RDONLY))

        let request = try WireRequest(ProjectCheckRequest(projectID: "p"))
        let (reply, descriptors) = try await host.call(request, descriptors: [file], taskID: TaskID("t1"))
        let response = try JSONCoding.decode(ProjectCheckResponse.self, from: reply.result.get())
        XCTAssertTrue(response.passed)
        XCTAssertEqual(descriptors.count, 1)
        var byte: UInt8 = 0
        XCTAssertEqual(read(descriptors[0].rawValue, &byte, 1), 1)
        XCTAssertEqual(byte, 42)
    }

    func testUnhandledRequestIsUnimplementedAndEventsArrive() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        let worker = WorkerChannel(adopting: b)
        defer { host.close(); worker.close() }
        let received = expectation(description: "event")
        host.onEvent { frame in
            XCTAssertEqual(frame.header.name, "log")
            XCTAssertEqual(frame.header.taskID, TaskID("t"))
            XCTAssertEqual(try? JSONCoding.decode(JSONValue.self, from: frame.body), .string("hi"))
            received.fulfill()
        }
        host.start()
        worker.start()

        let (reply, _) = try await host.call(WireRequest(SDKListRequest()))
        guard case let .failure(error) = reply.result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, .unimplemented)

        try worker.sendEvent(taskID: TaskID("t"), kind: "log", payload: .string("hi"))
        await fulfillment(of: [received], timeout: 5)
    }

    func testCancellationReleasesWaitWithoutClosingChannel() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        let worker = WorkerChannel(adopting: b)
        defer { host.close(); worker.close() }
        let entered = expectation(description: "peer received the request")
        let cancelled = expectation(description: "caller ended before peer answered")
        let gate = ChannelReplyGate()
        worker.onRequest { request in
            if request.request.requestID == "held" {
                entered.fulfill()
                await gate.wait()
            }
            return (.success(request.request.requestID, ProjectCheckResponse(passed: true)), [])
        }
        host.start()
        worker.start()
        var request = try WireRequest(ProjectCheckRequest(projectID: "p"))
        request.requestID = "held"
        let held = request
        let call = Task {
            do {
                _ = try await host.call(held)
                XCTFail("a cancelled wait must not wait for the reply")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        call.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        // Release even on failure: the old implementation must fail, not hang
        // the suite. The late response must not resume a continuation twice.
        await gate.release()
        await call.value
        let (reply, _) = try await host.call(WireRequest(ProjectCheckRequest(projectID: "p")), deadline: .seconds(2))
        XCTAssertTrue(try JSONCoding.decode(ProjectCheckResponse.self, from: reply.result.get()).passed)
        XCTAssertFalse(host.isClosed)
    }

    func testAlreadyCancelledCallSendsNothing() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        let worker = WorkerChannel(adopting: b)
        defer { host.close(); worker.close() }
        let sent = expectation(description: "cancelled request is not sent")
        sent.isInverted = true
        worker.onRequest { request in
            sent.fulfill()
            return (.success(request.request.requestID, ProjectCheckResponse(passed: true)), [])
        }
        host.start()
        worker.start()
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await host.call(WireRequest(ProjectCheckRequest(projectID: "p")), deadline: .seconds(1))
                XCTFail("a pre-cancelled call must throw")
            } catch is CancellationError {
                // The onCancel callback ran before continuation registration.
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        await call.value
        await fulfillment(of: [sent], timeout: 0.1)
    }

    func testCancellationRacingReplyAndCloseResumesOnce() async throws {
        for _ in 0 ..< 50 {
            let (a, b) = try WorkerChannel.makePair()
            let host = WorkerChannel(adopting: a)
            let worker = WorkerChannel(adopting: b)
            worker.onRequest { request in
                return (.success(request.request.requestID, ProjectCheckResponse(passed: true)), [])
            }
            host.start()
            worker.start()
            let call = Task {
                try await host.call(WireRequest(ProjectCheckRequest(projectID: "p")), deadline: .seconds(1))
            }
            let cancellation = Task.detached { call.cancel() }
            let closing = Task.detached { host.close() }
            do {
                _ = try await call.value
            } catch is CancellationError {
                // Cancellation won.
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .unavailable) // Close won, never timeout.
            }
            await cancellation.value
            await closing.value
            worker.close()
        }
    }

    func testClosedChannelFailsPendingCalls() async throws {
        let (a, b) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: a)
        host.start()
        close(b)
        do {
            _ = try await host.call(WireRequest(SDKListRequest()))
            XCTFail("expected unavailable")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .unavailable)
        }
    }
}

private actor ChannelReplyGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private extension Result {
    var failureValue: Failure? {
        if case let .failure(error) = self {
            return error
        }
        return nil
    }
}

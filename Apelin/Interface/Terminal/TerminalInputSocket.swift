import ApelinProtocol
import Darwin
import Foundation

/// A terminal's keyboard socket, written from whichever thread ghostty calls
/// back on.
///
/// The host hands the app one end of a `socketpair`; bytes written here are the
/// user's typing. Writes are serialised on one queue and see the whole of a
/// partial write through — `send(2)` may take half a paste — retry `EINTR`,
/// wait out `EAGAIN` on the descriptor itself rather than spinning, and treat a
/// closed peer as final. `SO_NOSIGPIPE` is set as soon as the descriptor is
/// adopted, so a shell that has gone cannot kill the app with `SIGPIPE`.
final class TerminalInputSocket: @unchecked Sendable {
    /// A paste larger than this is truncated: the shell reads at its own pace,
    /// and a queue with no bound is a leak wearing a keyboard.
    static let maximumPendingBytes = 4 << 20

    private let queue = DispatchQueue(label: "wiki.qaq.apelin.terminal.input")
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var closed = false
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var draining = false

    func adopt(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        lock.lock()
        closeLocked()
        self.descriptor = descriptor
        closed = false
        lock.unlock()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !closed, descriptor >= 0 else {
            lock.unlock()
            return
        }
        pending.append(data)
        pendingBytes += data.count
        while pendingBytes > Self.maximumPendingBytes, pending.count > 1 {
            pendingBytes -= pending.removeFirst().count
        }
        let alreadyDraining = draining
        draining = true
        lock.unlock()
        guard !alreadyDraining else { return }
        queue.async { [weak self] in self?.drain() }
    }

    func close() {
        lock.lock()
        closeLocked()
        closed = true
        lock.unlock()
    }

    private func closeLocked() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        pending.removeAll()
        pendingBytes = 0
    }

    /// Runs on `queue`: keeps one write in flight and stops when nothing is
    /// queued or the peer is gone.
    private func drain() {
        while true {
            lock.lock()
            let descriptor = self.descriptor
            guard !closed, descriptor >= 0, !pending.isEmpty else {
                draining = false
                lock.unlock()
                return
            }
            let chunk = pending.removeFirst()
            pendingBytes -= chunk.count
            lock.unlock()

            guard writeAll(chunk, to: descriptor) else {
                close()
                return
            }
        }
    }

    /// Every byte, or false once the peer is gone. A shell that keeps its
    /// buffer full for longer than the bound is treated as gone rather than
    /// allowed to wedge every later keystroke behind it.
    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var sent = 0
        var waited: TimeInterval = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return send(descriptor, base.advanced(by: sent), bytes.count - sent, 0)
            }
            if count > 0 {
                sent += count
                // Progress: the peer is reading, however slowly. The bound below
                // is for a stall, not for a slow consumer — a shell printing
                // while it reads must not be cut off at five seconds.
                waited = 0
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                // Not writable right now: wait on the descriptor itself rather
                // than spinning, and give up only once the wait has run out —
                // a single 200 ms timeout is not a closed peer.
                if !waitWritable(descriptor, timeout: 0.2) {
                    waited += 0.2
                    if waited >= 5 {
                        return false
                    }
                }
                continue
            }
            // EPIPE, ENOTCONN, EBADF: the other end is gone.
            return false
        }
        return true
    }

    private func waitWritable(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        var entry = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let result = poll(&entry, 1, Int32(timeout * 1000))
        if result > 0 {
            return entry.revents & Int16(POLLOUT) != 0
        }
        return false
    }
}

/// A grid size, so two updates can be compared without a tuple's spelling.
struct TerminalGridSize: Equatable, Sendable {
    var columns: Int
    var rows: Int

    init(columns: Int, rows: Int) {
        self.columns = max(1, min(1000, columns))
        self.rows = max(1, min(1000, rows))
    }
}

/// `ptyResize` for the library's resize callback, which runs on its own thread
/// and fires far more often than a PTY should be told: pixel-only updates are
/// already suppressed by the session, and equal grids are dropped here. One
/// request is in flight at a time and the newest waits behind it, so a live
/// drag settles on its final size instead of queueing every step.
final class TerminalResizeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var service: ApelinService?
    private var sessionID: String?
    private var lastSent: TerminalGridSize?
    private var pending: TerminalGridSize?
    private var inFlight = false

    func configure(service: ApelinService, sessionID: String) {
        lock.lock()
        self.service = service
        self.sessionID = sessionID
        lastSent = nil
        pending = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        service = nil
        sessionID = nil
        pending = nil
        lock.unlock()
    }

    func request(columns: Int, rows: Int) {
        let size = TerminalGridSize(columns: columns, rows: rows)
        lock.lock()
        if lastSent == size, pending == nil {
            lock.unlock()
            return
        }
        pending = size
        let shouldStart = !inFlight
        inFlight = true
        let service = self.service
        let sessionID = self.sessionID
        lock.unlock()
        guard shouldStart else { return }
        guard let service, let sessionID else {
            lock.lock()
            inFlight = false
            lock.unlock()
            return
        }
        Task.detached { [weak self] in
            guard let self else { return }
            while let next = takeNext() {
                try? await service.ptyResize(
                    sessionID: sessionID,
                    columns: next.columns,
                    rows: next.rows
                )
            }
        }
    }

    /// The next size to send, or nil once nothing is queued. Non-async so the
    /// lock is taken outside an async context.
    private func takeNext() -> TerminalGridSize? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = pending else {
            inFlight = false
            return nil
        }
        pending = nil
        lastSent = next
        return next
    }
}

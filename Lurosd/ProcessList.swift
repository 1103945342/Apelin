import Darwin
import Foundation

// The daemon's own view of the machine's processes: private in the iOS SDK
// headers, public in libSystem on every iOS this app supports. Read here and
// not beside the XPC declarations, since the install tests build this file
// with the device toolchain, whose SDK cannot import XPC.

@_silgen_name("proc_pidpath")
func daemonProcPIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

@_silgen_name("proc_listpids")
func daemonProcListPIDs(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

/// `PROC_ALL_PIDS`.
let procAllPIDs: UInt32 = 1

/// The canonical path of a running process's executable.
func executablePath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = buffer.withUnsafeMutableBytes { daemonProcPIDPath(pid, $0.baseAddress!, UInt32($0.count)) }
    return length > 0 ? canonicalPath(String(cString: buffer)) : nil
}

/// Every process ID the system lists, the caller's own included.
func processIDs() -> [Int32] {
    // Enough for any iOS device several times over; a buffer too small is
    // answered with what fits, which is still every process here.
    let capacity = 8192
    var buffer = [Int32](repeating: 0, count: capacity)
    let bytes = buffer.withUnsafeMutableBytes {
        daemonProcListPIDs(procAllPIDs, 0, $0.baseAddress, Int32($0.count))
    }
    guard bytes > 0 else { return [] }
    return buffer.prefix(Int(bytes) / MemoryLayout<Int32>.size).filter { $0 > 0 }
}

/// Every process running a program from under `path` — the app itself and the
/// extensions it loaded from `PlugIns` — by its executable's canonical path.
func processIDs(runningFrom path: String) -> [Int32] {
    let prefix = path.hasSuffix("/") ? path : path + "/"
    return processIDs().filter { pid in
        pid != getpid() && executablePath(pid: pid).map { $0.hasPrefix(prefix) } == true
    }
}

/// `realpath(3)`; nil for a path with an embedded NUL or one that does not resolve.
func canonicalPath(_ path: String) -> String? {
    guard !path.utf8.contains(0), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

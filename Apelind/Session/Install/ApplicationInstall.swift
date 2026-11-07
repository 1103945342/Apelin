import ApelinCore
import Darwin
import Foundation

/// An app onto the device the way the bootstrap's own tools put one there:
/// the bundle copied under `Applications`, every Mach-O signed with `ldid`,
/// and `uicache` registering or unregistering it.
///
/// Nothing here links libarchive or MobileInstallation: the daemon links no
/// third-party code (`AGENTS.md`), and the three tools a roothide or rootless
/// bootstrap already ships do the work, run as root by the host that owns
/// these paths. The tools see the bootstrap as `/` on roothide, so every path
/// handed to one goes through `toolPath(_:)`.
enum ApplicationInstall {
    struct Layout: Sendable {
        /// The bootstrap root: `/var/jb` on rootless, the `.jbroot-…` folder on roothide.
        var installRoot: String
        /// `<install root>/Applications`, where a private app lives.
        var applications: String
        var ldid: String
        var uicache: String

        init(installRoot: String) {
            self.installRoot = installRoot
            let root = installRoot == "/" ? "" : installRoot
            applications = root + "/Applications"
            ldid = root + "/usr/bin/ldid"
            uicache = root + "/usr/bin/uicache"
        }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case io(String)
        case unsupported(String)
        case tool(String)

        var description: String {
            switch self {
            case let .io(message): message
            case let .unsupported(what): what
            case let .tool(message): message
            }
        }
    }

    static let ignoredNames: Set<String> = ["_CodeSignature", "embedded.mobileprovision"]

    /// The path a bootstrap tool understands: on roothide the tool's `/` is
    /// the bootstrap root, so the root's own name comes off.
    static func toolPath(_ path: String, installRoot: String) -> String {
        guard installRoot != "/", let below = BootstrapRootPath.belowRoot(path) else { return path }
        return "/" + below
    }

    // MARK: Copying

    /// The whole bundle at `source` into `destination`, which must not exist.
    /// A signature and a provisioning profile are left behind: the copy is
    /// signed again, and both would describe bytes that are no longer there.
    static func copy(_ source: URL, to destination: URL) throws {
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0 else {
            throw Failure.io("\(source.lastPathComponent) could not be read")
        }
        let type = metadata.st_mode & S_IFMT
        switch type {
        case S_IFDIR:
            do {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755]
                )
            } catch {
                throw Failure.io("\(destination.lastPathComponent) could not be made")
            }
            _ = chown(destination.path, 0, 0)
            for child in (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
                where !ignoredNames.contains(child.lastPathComponent)
            {
                try copy(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        case S_IFREG:
            guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else {
                throw Failure.io("\(source.lastPathComponent) could not be copied")
            }
            _ = chown(destination.path, 0, 0)
            _ = chmod(destination.path, metadata.st_mode & 0o777)
        default:
            throw Failure.unsupported("\(source.lastPathComponent) is not a file or a folder")
        }
    }

    // MARK: Signing

    /// Every Mach-O in the bundle, signed ad-hoc with the entitlements it
    /// carried: a third-party certificate is not trusted on this device, and
    /// the bootstrap's own private apps are signed the same way. Answers the
    /// files it signed, for the task log.
    @discardableResult
    static func sign(
        _ bundle: URL, layout: Layout, scratch: URL,
        runTool: (String, [String]) throws -> ToolResult = run
    ) throws -> [String] {
        var signed: [String] = []
        for file in try MachO.files(in: bundle) {
            // ldid is a bootstrap tool: it reads the path the bootstrap
            // shows, so the root's own name comes off first.
            let shown = toolPath(file, installRoot: layout.installRoot)
            let entitlements = (try? runTool(layout.ldid, ["-e", shown]))?.output ?? ""
            let arguments: [String]
            var entitlementFile: URL?
            // The file must outlive the if branch: ldid opens it below.
            // Clean up once this binary's signing attempt ends, even on throw.
            defer { if let entitlementFile { unlink(entitlementFile.path) } }
            if entitlements.contains("<plist"), !entitlements.isEmpty {
                let path = scratch.appendingPathComponent(UUID().uuidString + ".plist")
                entitlementFile = path
                guard (try? entitlements.write(to: path, atomically: true, encoding: .utf8)) != nil else {
                    throw Failure.io("\(path.lastPathComponent) could not be written")
                }
                arguments = ["-S" + toolPath(path.path, installRoot: layout.installRoot), shown]
            } else {
                arguments = ["-S", shown]
            }
            let result = try runTool(layout.ldid, arguments)
            guard result.status == 0 else {
                throw Failure.tool("ldid refused \(file.split(separator: "/").suffix(2).joined(separator: "/")): \(result.output)")
            }
            signed.append(file)
        }
        return signed
    }

    // MARK: Registering

    static func register(_ bundle: URL, layout: Layout, installRoot: String) throws {
        try uicache(["-p", toolPath(bundle.path, installRoot: installRoot)], layout: layout)
    }

    /// Takes the bundle at `path` out of LaunchServices; the files are the
    /// caller's to delete.
    static func unregister(_ path: String, layout: Layout, installRoot: String) throws {
        try uicache(["-u", toolPath(path, installRoot: installRoot)], layout: layout)
    }

    private static func uicache(_ arguments: [String], layout: Layout) throws {
        let result = try run(layout.uicache, arguments)
        guard result.status == 0 else {
            throw Failure.tool("uicache answered \(result.status): \(result.output)")
        }
    }

    // MARK: Running a tool

    struct ToolResult: Sendable {
        var status: Int32
        var output: String
    }

    /// Runs `executable` as this process's user (root) with `arguments`,
    /// answering its exit status and the first 64 KiB it printed.
    static func run(_ executable: String, _ arguments: [String]) throws -> ToolResult {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Failure.io("a pipe could not be made") }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], 1)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], 2)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var pid: pid_t = 0
        let status = withCStrings([executable] + arguments) { argv in
            withCStrings(["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root"]) { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            }
        }
        close(descriptors[1])
        guard status == 0 else {
            close(descriptors[0])
            throw Failure.tool("\(executable) could not start (\(String(cString: strerror(status))))")
        }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptors[0], &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            if collected.count < 64 << 10 {
                collected.append(buffer, count: min(count, (64 << 10) - collected.count))
            }
        }
        close(descriptors[0])
        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) == -1, errno == EINTR {}
        return ToolResult(
            status: Self.exitStatus(waitStatus),
            output: String(decoding: collected, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        guard signal == 0 else { return 128 &+ signal }
        return (status >> 8) & 0xFF
    }

    private static func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// The Mach-O files inside a bundle: the main executable and every framework,
/// dylib and helper that carries its own code signature.
enum MachO {
    private static let magics: Set<UInt32> = [
        0xFEED_FACF, // 64-bit
        0xFEED_FACE, // 32-bit
        0xCEFA_EDFE, // 64-bit, other byte order
        0xCAFE_BABE, // universal
        0xCFFA_EDFE,
    ]

    static func files(in bundle: URL) throws -> [String] {
        var found: [String] = []
        try walk(bundle, into: &found)
        return found
    }

    private static func walk(_ url: URL, into found: inout [String]) throws {
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            var metadata = stat()
            guard lstat(child.path, &metadata) == 0 else { continue }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                try walk(child, into: &found)
            case S_IFREG where metadata.st_size >= 4:
                if isMachO(child.path) { found.append(child.path) }
            default:
                continue
            }
        }
    }

    static func isMachO(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var bytes: [UInt8] = [0, 0, 0, 0]
        guard read(descriptor, &bytes, 4) == 4 else { return false }
        let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return magics.contains(value)
    }
}

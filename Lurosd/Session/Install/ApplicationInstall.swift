import LurosCore
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

    // MARK: Preparing

    /// A signature and a provisioning profile that arrived with the `.ipa`
    /// describe bytes the host is about to change: every Mach-O is signed
    /// again, and both would vouch for what is no longer there. They go before
    /// the first `ldid` run, at every level a framework may carry one.
    static func stripSignatures(_ bundle: URL) {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: bundle,
            includingPropertiesForKeys: nil
        )) ?? []
        for child in children {
            if ignoredNames.contains(child.lastPathComponent) {
                try? FileManager.default.removeItem(at: child)
            } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                stripSignatures(child)
            }
        }
    }

    // MARK: Checking

    /// A bundle read back from where it is going in from: the identifier its
    /// `Info.plist` claims, an executable that is there, and Mach-O code.
    /// `AppBundle.find` checked the `.ipa`'s own copy before anything ran;
    /// this checks the copy staging signed, so a copy that did not survive
    /// cannot take the place of an app that worked. `uicache` is no check:
    /// it answers zero for a folder that holds no app at all.
    static func validate(_ bundle: URL, expecting bundleID: String) throws {
        guard let info = AppBundle.describe(bundleAt: bundle.path) else {
            throw Failure.io("\(bundle.lastPathComponent) holds no readable Info.plist")
        }
        guard info.bundleID == bundleID else {
            throw Failure.io("\(bundle.lastPathComponent) claims \(info.bundleID), not \(bundleID)")
        }
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let executable = (plist["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespaces),
              !executable.isEmpty, !executable.contains("/")
        else {
            throw Failure.io("\(bundle.lastPathComponent) names no executable")
        }
        var metadata = stat()
        guard lstat(bundle.appendingPathComponent(executable).path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size > 0
        else {
            throw Failure.io("\(bundle.lastPathComponent) has no executable \(executable)")
        }
        guard try !MachO.files(in: bundle).isEmpty else {
            throw Failure.io("\(bundle.lastPathComponent) holds no Mach-O")
        }
    }

    // MARK: Placing

    /// A bundle put in place, and the bundles it took the place of.
    struct Placed: Sendable, Equatable {
        struct Displaced: Sendable, Equatable {
            /// Where the bundle was.
            var original: URL
            /// Where it waits while the new one settles.
            var aside: URL
        }

        var destination: URL
        var displaced: [Displaced]
        /// True when the bundle was copied beside the destination first,
        /// because staging is on another volume.
        var copied: Bool?
    }

    /// Whether two paths live on one volume: a rename between them is one
    /// step on the same volume, and `EXDEV` across two.
    static func sameVolume(_ one: String, _ two: String) -> Bool {
        var a = stat()
        var b = stat()
        guard stat(one, &a) == 0, stat(two, &b) == 0 else { return false }
        return a.st_dev == b.st_dev
    }

    /// A path the bundle can be renamed into `destination` from: itself when
    /// it is on the destination's volume, a copy beside the destination when
    /// it is not. roothide has put `Applications` on a volume of its own, so
    /// the staging folder a bundle is signed in need not share one, and a
    /// rename across that boundary is `EXDEV` — a placement the device
    /// refuses, never something to retry later.
    ///
    /// `copying` forces the decision: nil reads the two devices, and the tests
    /// take each side without depending on how the device is mounted today.
    static func importBeside(
        _ incoming: URL,
        at destination: URL,
        copying: Bool? = nil
    ) throws -> (bundle: URL, copied: Bool) {
        let parent = destination.deletingLastPathComponent()
        guard copying ?? !sameVolume(incoming.path, parent.path) else { return (incoming, false) }
        let staging = URL(fileURLWithPath: destination.path + ".luros-incoming-" + UUID().uuidString.lowercased())
        do {
            try FileManager.default.copyItem(at: incoming, to: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure.io("\(destination.lastPathComponent) could not be copied beside the app folder")
        }
        return (staging, true)
    }

    /// The bundle `incoming`, in root's staging, at `destination` — with
    /// `others` and whatever is at the destination renamed aside first. A
    /// bundle on another volume is copied beside the destination first, so
    /// every step that moves something is a rename on one volume: what the
    /// device holds is the old bundle or the new one, never half of each, and
    /// `withdraw` puts the old one back.
    ///
    /// An app of the same identifier may already be at another path, its
    /// record written when the display name was different: `others` names it
    /// so the device does not end up with two bundles of one ID.
    static func place(
        _ incoming: URL,
        at destination: URL,
        displacing others: [URL] = [],
        copying: Bool? = nil
    ) throws -> Placed {
        let parent = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            throw Failure.io("\(parent.lastPathComponent) could not be made")
        }
        let imported = try importBeside(incoming, at: destination, copying: copying)
        var displaced: [Placed.Displaced] = []
        func putBack() {
            for entry in displaced { _ = rename(entry.aside.path, entry.original.path) }
            if imported.copied { try? FileManager.default.removeItem(at: imported.bundle) }
        }
        for original in [destination] + others
            where isPresent(original) && !displaced.contains(where: { $0.original.path == original.path })
        {
            let aside = URL(fileURLWithPath: original.path + ".luros-outgoing-" + UUID().uuidString.lowercased())
            guard rename(original.path, aside.path) == 0 else {
                let reason = String(cString: strerror(errno))
                putBack()
                throw Failure.io("\(original.lastPathComponent) could not be moved aside: \(reason)")
            }
            displaced.append(Placed.Displaced(original: original, aside: aside))
        }
        guard rename(imported.bundle.path, destination.path) == 0 else {
            let reason = String(cString: strerror(errno))
            putBack()
            throw Failure.io("\(destination.lastPathComponent) could not be put in place: \(reason)")
        }
        return Placed(destination: destination, displaced: displaced, copied: imported.copied)
    }

    /// The install that put `placed` there did not finish: the new bundle
    /// goes, what it displaced comes back, and LaunchServices is told about
    /// each bundle that came back. Answers what could not be undone, for the
    /// task's last words.
    static func withdraw(_ placed: Placed, layout: Layout) -> [String] {
        var problems: [String] = []
        let failed = URL(fileURLWithPath: placed.destination.path + ".luros-failed-" + UUID().uuidString.lowercased())
        if rename(placed.destination.path, failed.path) != 0 {
            problems.append(
                "\(placed.destination.lastPathComponent) could not be moved away (\(String(cString: strerror(errno))))"
            )
        }
        for entry in placed.displaced {
            guard rename(entry.aside.path, entry.original.path) == 0 else {
                problems.append(
                    "\(entry.original.lastPathComponent) could not be put back (\(String(cString: strerror(errno))))"
                )
                continue
            }
            // The app that was here is registered by the path the system
            // names — with the root it went in under.
            if AppBundle.describe(bundleAt: entry.original.path) != nil {
                try? register(entry.original, layout: layout, installRoot: layout.installRoot)
            }
        }
        try? FileManager.default.removeItem(at: failed)
        return problems
    }

    /// `<name>.app.luros-outgoing-…` and `…-failed-…` folders a host that
    /// stopped mid-install left beside the bundle: the next install of this
    /// app takes them away first.
    static func removeLeftovers(beside destination: URL) {
        let parent = destination.deletingLastPathComponent()
        let stem = destination.lastPathComponent + ".luros-"
        let children = (try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        )) ?? []
        for child in children where child.lastPathComponent.hasPrefix(stem) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    private static func isPresent(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    // MARK: Ending what runs

    /// Ends every process running a program from under `bundle` — the app and
    /// the extensions it loaded from `PlugIns` — and answers their IDs, waiting
    /// up to a moment for each to go. iOS ends an app whose bundle is renamed
    /// away, but not always before the rename lands, and a process still
    /// holding the old binary is what a replacement must not leave behind.
    static func terminate(_ bundle: URL) -> [Int32] {
        let pids = processIDs(runningFrom: bundle.path)
        guard !pids.isEmpty else { return [] }
        for pid in pids { kill(pid, SIGKILL) }
        let deadline = Date().addingTimeInterval(2)
        while true {
            let alive = pids.filter { kill($0, 0) == 0 }
            if alive.isEmpty || Date() > deadline { break }
            usleep(5000)
        }
        return pids
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

    /// The same for a bundle whose files may already be gone. roothide's
    /// `uicache` has its root put in front of the paths it is given, so the
    /// path it understands for a bundle that is there is the bootstrap's;
    /// a registration left behind by a bundle that is no longer there is
    /// keyed by the real path instead, which only `/rootfs/…` names. The real
    /// path is tried first — it names the registration whichever root the
    /// bootstrap had when it was made — and the bootstrap's second.
    static func unregisterAnywhere(_ path: String, layout: Layout, installRoot: String) throws {
        var refusal: Failure?
        for argument in ["/rootfs" + path, toolPath(path, installRoot: installRoot)] {
            do {
                try uicache(["-u", argument], layout: layout)
                return
            } catch let failure as Failure {
                refusal = failure
            }
        }
        if let refusal { throw refusal }
    }

    private static func uicache(_ arguments: [String], layout: Layout) throws {
        let result = try run(layout.uicache, arguments)
        // A path it cannot match is printed as an error under a zero status.
        guard result.status == 0, !result.output.hasPrefix("Error") else {
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

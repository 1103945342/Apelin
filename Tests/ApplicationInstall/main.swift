import LurosCore
import Darwin
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ApplicationInstall.Failure.io("test: " + message) }
}

/// A bundle as `AppBundle.find` reads one: an `Info.plist` claiming an ID and
/// an executable that is Mach-O, which is all `validate` and `place` look at.
func writeApp(at bundle: URL, bundleID: String, version: String, executable: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleID,
        "CFBundleExecutable": executable,
        "CFBundleShortVersionString": version,
        "CFBundleName": bundle.deletingPathExtension().lastPathComponent,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: bundle.appendingPathComponent("Info.plist"))
    try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: bundle.appendingPathComponent(executable))
}

func check() throws {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
    // The data folder may use the AppGroup alias of the bootstrap, while the
    // executable uses its Bundle/Application spelling. Use the data's spelling.
    var ancestor = base
    var hostingRoot: String?
    while ancestor.path != "/" {
        if ancestor.lastPathComponent.hasPrefix(".jbroot-") { hostingRoot = ancestor.path; break }
        ancestor.deleteLastPathComponent()
    }
    let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>get-task-allow</key><true/></dict></plist>"

    // Literal paths exercise the native rootless spelling independently of the
    // bootstrap hosting this test (which may itself be roothide).
    let rootless = ApplicationInstall.Layout(installRoot: "/var/jb")
    try require(rootless.ldid == "/var/jb/usr/bin/ldid", "rootless ldid location")
    for path in ["/var/jb/Applications/Hello World.app/Hello World", "/var/jb/var/lib/luros/staging/test.plist"] {
        try require(ApplicationInstall.toolPath(path, installRoot: rootless.installRoot) == path, "rootless path stays absolute")
    }
    let hiddenRoot = "/private/var/containers/Bundle/Application/.jbroot-0102030405060700"
    try require(ApplicationInstall.toolPath(hiddenRoot + "/var/lib/luros/staging/test.plist", installRoot: hiddenRoot) == "/var/lib/luros/staging/test.plist", "roothide strips bootstrap root")

    // Synthetic trees, never installed. The runner must read -S's file while it
    // is called. '/' selects the same identity mapping rootless uses, even when
    // this test's physical scratch folder is inside a real roothide bootstrap.
    for flavor in ["roothide", "rootless"] {
        let root = base.appendingPathComponent(flavor == "roothide" ? ".jbroot-0102030405060700" : "var/jb")
        let bundle = root.appendingPathComponent("Applications/Hello World.app")
        let scratch = root.appendingPathComponent("var/lib/luros/staging/test")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        for name in ["Hello World", "Helper"] {
            try Data([0xFE, 0xED, 0xFA, 0xCF]).write(to: bundle.appendingPathComponent(name))
        }
        let activeRoot = flavor == "roothide"
            ? (hostingRoot ?? root.path) : "/"
        let layout = ApplicationInstall.Layout(installRoot: activeRoot)
        func shown(_ path: String) -> String {
            flavor == "roothide" ? String(path.dropFirst(activeRoot.count)) : path
        }
        try require(ApplicationInstall.toolPath(scratch.path, installRoot: activeRoot) == shown(scratch.path), "\(flavor): scratch path (actual=\(ApplicationInstall.toolPath(scratch.path, installRoot: activeRoot)), expected=\(shown(scratch.path)), root=\(activeRoot))")
        for mode in ["success", "refused", "throws", "no-entitlements"] {
            var calls = 0
            var temporaryPaths: [String] = []
            var caught: Error?
            do {
                let signed = try ApplicationInstall.sign(bundle, layout: layout, scratch: scratch) { executable, args in
                    try require(executable == layout.ldid, "ldid executable")
                    try require(args.count == 2, "argument count")
                    let leaf = URL(fileURLWithPath: args[1]).lastPathComponent
                    try require(args[1] == shown(bundle.appendingPathComponent(leaf).path), "\(flavor): binary path")
                    if args[0] == "-e" {
                        return .init(status: 0, output: mode == "no-entitlements" ? "" : plist)
                    }
                    calls += 1
                    // Every preceding binary's plist has already been removed.
                    for previous in temporaryPaths {
                        try require(!fm.fileExists(atPath: previous), "previous plist leaked")
                    }
                    if mode == "no-entitlements" {
                        try require(args[0] == "-S", "plain ad-hoc signing")
                    } else {
                        try require(args[0].hasPrefix("-S"), "entitlements argument")
                        let toolPath = String(args[0].dropFirst(2))
                        let nativePath = flavor == "roothide" ? activeRoot + toolPath : toolPath
                        try require(toolPath.hasPrefix(shown(scratch.path) + "/"), "\(flavor): plist path")
                        let contents = try String(contentsOfFile: nativePath, encoding: .utf8)
                        try require(contents == plist, "entitlements changed")
                        temporaryPaths.append(nativePath)
                    }
                    if mode == "throws" { throw ApplicationInstall.Failure.tool("injected spawn failure") }
                    return .init(status: mode == "refused" ? 1 : 0, output: "injected result")
                }
                try require(signed.count == 2, "both Mach-O files signed")
            } catch { caught = error }
            if mode == "refused" || mode == "throws" {
                guard let failure = caught as? ApplicationInstall.Failure,
                      case .tool = failure else {
                    throw ApplicationInstall.Failure.io("\(flavor)/\(mode): expected tool failure, got \(String(describing: caught))")
                }
            } else if let caught { throw caught }
            try require(calls == ((mode == "refused" || mode == "throws") ? 1 : 2), "sign call count")
            let leftovers = try fm.contentsOfDirectory(atPath: scratch.path)
            try require(leftovers.isEmpty, "\(flavor)/\(mode): temporary plist leaked")
            print("ok: \(flavor) \(mode)")
        }
    }

    // Placing: a bundle from staging takes another's place by renames, and a
    // failed install puts back exactly what it displaced.
    do {
        let apps = base.appendingPathComponent("Placement/Applications")
        let staging = base.appendingPathComponent("Placement/staging")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = apps.appendingPathComponent("Swap.app")
        try writeApp(at: destination, bundleID: "local.apelin.swap", version: "1.0", executable: "Swap")
        let incoming = staging.appendingPathComponent("Swap.app")
        try writeApp(at: incoming, bundleID: "local.apelin.swap", version: "2.0", executable: "Swap")
        try ApplicationInstall.validate(incoming, expecting: "local.apelin.swap")
        try require(AppBundle.describe(bundleAt: incoming.path)?.name == "Swap", "the incoming app describes itself")

        let placed = try ApplicationInstall.place(incoming, at: destination)
        try require(placed.displaced.count == 1, "the old bundle was moved aside")
        try require(!fm.fileExists(atPath: incoming.path), "the staged bundle was moved, not copied")
        try require(AppBundle.describe(bundleAt: destination.path)?.version == "2.0", "the new bundle is in place")

        // A failed install: the new one goes, the old one comes back untouched.
        try require(ApplicationInstall.withdraw(placed, layout: rootless).isEmpty, "withdraw reports no problems")
        try require(AppBundle.describe(bundleAt: destination.path)?.version == "1.0", "the old bundle is back")
        try require(!fm.fileExists(atPath: placed.displaced[0].aside.path), "the failed copy was taken away")

        // An install that finishes keeps the new bundle and drops the old one.
        let second = staging.appendingPathComponent("Swap.app")
        try writeApp(at: second, bundleID: "local.apelin.swap", version: "3.0", executable: "Swap")
        let kept = try ApplicationInstall.place(second, at: destination)
        for entry in kept.displaced { try fm.removeItem(at: entry.aside) }
        try require(AppBundle.describe(bundleAt: destination.path)?.version == "3.0", "the third version stays")
        let beside = try fm.contentsOfDirectory(atPath: apps.path)
        try require(beside == ["Swap.app"], "nothing is left beside the app")

        // What a host that stopped mid-install left: the next install of the
        // same app takes it away.
        try fm.createDirectory(
            at: apps.appendingPathComponent("Swap.app.luros-outgoing-1234"),
            withIntermediateDirectories: true
        )
        ApplicationInstall.removeLeftovers(beside: destination)
        let afterCleanup = try fm.contentsOfDirectory(atPath: apps.path)
        try require(afterCleanup == ["Swap.app"], "leftovers are removed")

        // A bundle that is not the app it claims never goes in place.
        let wrong = staging.appendingPathComponent("Wrong.app")
        try writeApp(at: wrong, bundleID: "local.apelin.other", version: "1.0", executable: "Wrong")
        do {
            try ApplicationInstall.validate(wrong, expecting: "local.apelin.swap")
            try require(false, "a bundle claiming another ID is refused")
        } catch let failure as ApplicationInstall.Failure {
            try require(failure.description.contains("local.apelin.other"), "the refusal names the ID (\(failure))")
        }
        print("ok: placement replaces in place and rolls back")
    }

    // Staging on another volume: the bundle is copied beside the destination
    // and renamed from there, and a failure still puts the old one back.
    do {
        let apps = base.appendingPathComponent("Copy/Applications")
        let staging = base.appendingPathComponent("Copy/staging")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = apps.appendingPathComponent("Copy.app")
        try writeApp(at: destination, bundleID: "local.apelin.copy", version: "1.0", executable: "Copy")
        let incoming = staging.appendingPathComponent("Copy.app")
        try writeApp(at: incoming, bundleID: "local.apelin.copy", version: "2.0", executable: "Copy")
        try require(ApplicationInstall.sameVolume(destination.path, apps.path), "one folder is one volume")

        let placed = try ApplicationInstall.place(incoming, at: destination, copying: true)
        try require(placed.copied == true, "the placement says it copied")
        try require(fm.fileExists(atPath: incoming.path), "the staged copy stays where it was signed")
        try require(AppBundle.describe(bundleAt: destination.path)?.version == "2.0", "the copied bundle is in place")
        try require(placed.displaced.count == 1, "the old bundle waits aside until the install finishes")

        // Withdrawing puts the old one back and takes both the copy it made
        // and the failed bundle away.
        try require(ApplicationInstall.withdraw(placed, layout: rootless).isEmpty, "withdraw after a copy reports no problems")
        try require(
            AppBundle.describe(bundleAt: destination.path)?.version == "1.0",
            "the old bundle is back after a copied placement"
        )
        let beside = try fm.contentsOfDirectory(atPath: apps.path).sorted()
        try require(beside == ["Copy.app"], "nothing is left beside it (\(beside))")
        print("ok: placement across volumes copies, places and rolls back")
    }

    // What runs from a bundle is ended before the bundle is replaced: a copy of
    // the system's sleep is started from inside a bundle and ended by the
    // installer's own scan.
    // The script builds a program that stays up (`sleep` is the system's, not
    // the bootstrap's, and neither root has one this process can reach).
    if let sleeper = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : nil,
       fm.isExecutableFile(atPath: sleeper)
    {
        let bundle = base.appendingPathComponent("Ending/End.app")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let copy = bundle.appendingPathComponent("sleep")
        try fm.copyItem(atPath: sleeper, toPath: copy.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        var pid: pid_t = 0
        let arguments = [strdup(copy.path), strdup("30"), nil]
        defer { for argument in arguments { free(argument) } }
        let started = arguments.withUnsafeBufferPointer {
            posix_spawn(&pid, copy.path, nil, nil, $0.baseAddress, environ)
        }
        try require(started == 0, "the sleeper started from the bundle")
        defer { kill(pid, SIGKILL) }
        var running: [Int32] = []
        for _ in 0 ..< 100 {
            running = processIDs(runningFrom: bundle.path)
            if !running.isEmpty { break }
            usleep(20_000)
        }
        try require(running == [pid], "the child runs from the bundle (\(running) vs \(pid))")
        let ended = ApplicationInstall.terminate(bundle)
        try require(ended == running, "terminate answers what it ended (\(ended) vs \(running))")
        try require(processIDs(runningFrom: bundle.path).isEmpty, "nothing runs from the bundle any more")
        print("ok: a process running from the bundle is ended")
    } else {
        print("skip: no sleep binary to start from a bundle")
    }

    // Optional on-device integration: a copy of a signed fixture, never installed
    // or executed. This calls the production posix_spawn runner and real ldid.
    if CommandLine.arguments.count >= 5 {
        let root = CommandLine.arguments[2]
        let ldid = CommandLine.arguments[3]
        let fixture = URL(fileURLWithPath: CommandLine.arguments[4])
        let bundle = base.appendingPathComponent("Live.app")
        let scratch = base.appendingPathComponent("live-scratch")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let binary = bundle.appendingPathComponent("HelloWorld")
        try fm.copyItem(at: fixture, to: binary)
        var layout = ApplicationInstall.Layout(installRoot: root)
        layout.ldid = ldid
        let path = ApplicationInstall.toolPath(binary.path, installRoot: root)
        let before = try ApplicationInstall.run(ldid, ["-e", path])
        try require(before.status == 0 && before.output.contains("get-task-allow"), "fixture has entitlements")
        let signed = try ApplicationInstall.sign(bundle, layout: layout, scratch: scratch)
        let after = try ApplicationInstall.run(ldid, ["-e", path])
        try require(signed == [binary.path] && after.status == 0 && before.output == after.output, "real ldid preserves entitlements")
        let leftovers = try fm.contentsOfDirectory(atPath: scratch.path)
        try require(leftovers.isEmpty, "real ldid plist cleanup")
        print("ok: real ldid signed the fixture and preserved its entitlements")
    }
}

do { try check() } catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}

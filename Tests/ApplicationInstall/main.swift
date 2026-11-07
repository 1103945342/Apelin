import ApelinCore
import Darwin
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ApplicationInstall.Failure.io("test: " + message) }
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
    for path in ["/var/jb/Applications/Hello World.app/Hello World", "/var/jb/var/lib/apelin/staging/test.plist"] {
        try require(ApplicationInstall.toolPath(path, installRoot: rootless.installRoot) == path, "rootless path stays absolute")
    }
    let hiddenRoot = "/private/var/containers/Bundle/Application/.jbroot-0102030405060700"
    try require(ApplicationInstall.toolPath(hiddenRoot + "/var/lib/apelin/staging/test.plist", installRoot: hiddenRoot) == "/var/lib/apelin/staging/test.plist", "roothide strips bootstrap root")

    // Synthetic trees, never installed. The runner must read -S's file while it
    // is called. '/' selects the same identity mapping rootless uses, even when
    // this test's physical scratch folder is inside a real roothide bootstrap.
    for flavor in ["roothide", "rootless"] {
        let root = base.appendingPathComponent(flavor == "roothide" ? ".jbroot-0102030405060700" : "var/jb")
        let bundle = root.appendingPathComponent("Applications/Hello World.app")
        let scratch = root.appendingPathComponent("var/lib/apelin/staging/test")
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

    // Optional on-device integration: a copy of a signed fixture, never installed
    // or executed. This calls the production posix_spawn runner and real ldid.
    if CommandLine.arguments.count == 5 {
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

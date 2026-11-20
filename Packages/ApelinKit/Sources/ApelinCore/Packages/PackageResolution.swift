import Foundation

/// What installing a package from a repository needs, read from the indexes
/// the device already has: the packages a `Packages` stanza names, Debian
/// version ordering, `Depends` relations with their alternatives, and the
/// order a dependency closure installs in. Pure text in, values out: the host
/// reads `<install root>/var/lib/apt/lists/*_Packages` and
/// `<install root>/var/lib/dpkg/status` and hands the text here, so every rule
/// below is testable off a device.
///
/// This is a resolver, not a package manager. It does not verify a repository
/// signature: it trusts the index as the last `apt update` on the device left
/// it. The `.deb` it names is checked against that index's `SHA256` and `Size`
/// before anything hands it to irisind.

// MARK: - Versions

/// Debian's version ordering: `[epoch:]upstream[-revision]`, where `~` sorts
/// before everything, digits compare by value and letters by ASCII.
public struct DebianVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let epoch: Int
    public let upstream: String
    public let revision: String

    public init(_ text: String) throws {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { throw ResolutionError.badVersion(text) }
        var epoch = 0
        if let colon = rest.firstIndex(of: ":") {
            guard let parsed = Int(rest[rest.startIndex ..< colon]), parsed >= 0 else {
                throw ResolutionError.badVersion(text)
            }
            epoch = parsed
            rest = String(rest[rest.index(after: colon)...])
        }
        self.epoch = epoch
        if let dash = rest.lastIndex(of: "-") {
            upstream = String(rest[rest.startIndex ..< dash])
            revision = String(rest[rest.index(after: dash)...])
        } else {
            upstream = rest
            revision = ""
        }
        guard !upstream.isEmpty else { throw ResolutionError.badVersion(text) }
    }

    public var description: String {
        var text = epoch > 0 ? "\(epoch):" : ""
        text += upstream
        if !revision.isEmpty { text += "-" + revision }
        return text
    }

    public static func < (left: DebianVersion, right: DebianVersion) -> Bool {
        if left.epoch != right.epoch { return left.epoch < right.epoch }
        if let order = compare(left.upstream, right.upstream), order != 0 { return order < 0 }
        if let order = compare(left.revision, right.revision), order != 0 { return order < 0 }
        return false
    }

    /// dpkg's rule for one part: a `~` sorts before the end of the string and
    /// before anything else, digits run by value and letters by ASCII.
    static func compare(_ left: String, _ right: String) -> Int? {
        func rank(_ character: Character) -> Int {
            if character == "~" { return -1 }
            if character.isNumber { return 0 }
            if let ascii = character.asciiValue { return Int(ascii) + 256 }
            return 0
        }
        let a = Array(left), b = Array(right)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            while (i < a.count && !a[i].isNumber) || (j < b.count && !b[j].isNumber) {
                let l = i < a.count ? rank(a[i]) : 0
                let r = j < b.count ? rank(b[j]) : 0
                if l != r { return l < r ? -1 : 1 }
                if i < a.count { i += 1 }
                if j < b.count { j += 1 }
            }
            var leftDigits = "", rightDigits = ""
            while i < a.count, a[i].isNumber { leftDigits.append(a[i]); i += 1 }
            while j < b.count, b[j].isNumber { rightDigits.append(b[j]); j += 1 }
            if leftDigits.isEmpty, rightDigits.isEmpty { break }
            let l = Int(leftDigits) ?? 0, r = Int(rightDigits) ?? 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

// MARK: - Relations

/// One `Depends` alternative: a package name, and the version it must be.
public struct PackageRelation: Hashable, Sendable {
    public enum Op: String, Sendable {
        case any = ""
        case lt = "<<"
        case le = "<="
        case eq = "="
        case ge = ">="
        case gt = ">>"
    }

    public var name: String
    public var op: Op
    public var version: String

    public init(name: String, op: Op = .any, version: String = "") {
        self.name = name
        self.op = op
        self.version = version
    }

    public func accepts(_ candidate: String) -> Bool {
        guard op != .any else { return true }
        guard let wanted = try? DebianVersion(version), let given = try? DebianVersion(candidate) else { return false }
        switch op {
        case .any: return true
        case .lt: return given < wanted
        case .le: return given <= wanted
        case .eq: return given == wanted
        case .ge: return given >= wanted
        case .gt: return given > wanted
        }
    }

    /// `libssl3 (>= 3.0.0)`, `default-mta`, or `libc6:any`. An architecture
    /// qualifier and a build profile are dropped: this device asks for its own.
    public static func parse(_ text: String) -> PackageRelation? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var op = Op.any
        var version = ""
        if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close {
            let inside = rest[rest.index(after: open) ..< close].trimmingCharacters(in: .whitespaces)
            rest = String(rest[rest.startIndex ..< open]).trimmingCharacters(in: .whitespaces)
            for candidate in [Op.lt, .le, .eq, .ge, .gt] where inside.hasPrefix(candidate.rawValue) {
                op = candidate
                version = String(inside.dropFirst(candidate.rawValue.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            if op == .any { return nil }
        }
        if let bracket = rest.firstIndex(of: "[") { rest = String(rest[rest.startIndex ..< bracket]) }
        if let colon = rest.firstIndex(of: ":") { rest = String(rest[rest.startIndex ..< colon]) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !rest.contains(" ") else { return nil }
        return PackageRelation(name: rest, op: op, version: version)
    }

    /// `libssl3 (>= 3.0) | libssl1.1, zlib1g` as the groups a package needs,
    /// each group met by any one of its alternatives.
    public static func groups(_ text: String) -> [[PackageRelation]] {
        text.split(separator: ",").compactMap { clause in
            let alternatives = clause.split(separator: "|").compactMap { parse(String($0)) }
            return alternatives.isEmpty ? nil : alternatives
        }
    }
}

// MARK: - Index

/// One package a repository index offers.
public struct IndexedPackage: Hashable, Sendable {
    public var name: String
    public var version: String
    public var architecture: String
    /// Inside the repository, as the stanza spells it: `./Pool/…/x.deb`.
    public var filename: String
    public var size: Int
    public var sha256: String
    public var depends: [[PackageRelation]]
    public var preDepends: [[PackageRelation]]
    public var provides: [String]
    /// The repository the stanza came from, so the host knows where to fetch it.
    public var source: String

    public init(
        name: String,
        version: String,
        architecture: String,
        filename: String,
        size: Int,
        sha256: String,
        depends: [[PackageRelation]] = [],
        preDepends: [[PackageRelation]] = [],
        provides: [String] = [],
        source: String = ""
    ) {
        self.name = name
        self.version = version
        self.architecture = architecture
        self.filename = filename
        self.size = size
        self.sha256 = sha256.lowercased()
        self.depends = depends
        self.preDepends = preDepends
        self.provides = provides
        self.source = source
    }

    /// Every stanza in one `Packages` file this device could install: its own
    /// architecture, or `all`.
    public static func parse(_ text: String, architecture: String, source: String) -> [IndexedPackage] {
        stanzas(text).compactMap { stanza in
            guard
                let name = stanza["Package"],
                let version = stanza["Version"],
                let filename = stanza["Filename"],
                let sha256 = stanza["SHA256"],
                let size = Int(stanza["Size"] ?? "")
            else { return nil }
            let arch = stanza["Architecture"] ?? ""
            guard arch == architecture || arch == "all" else { return nil }
            return IndexedPackage(
                name: name,
                version: version,
                architecture: arch,
                filename: filename,
                size: size,
                sha256: sha256,
                depends: PackageRelation.groups(stanza["Depends"] ?? ""),
                preDepends: PackageRelation.groups(stanza["Pre-Depends"] ?? ""),
                provides: (stanza["Provides"] ?? "").split(separator: ",").compactMap {
                    let provided = String($0).split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    return provided.isEmpty ? nil : provided
                },
                source: source
            )
        }
    }

    /// `Name: value` fields, a stanza at a time. A blank line ends one, and a
    /// line without `Name:` is skipped rather than ending the stanza.
    static func stanzas(_ text: String) -> [[String: String]] {
        var stanzas: [[String: String]] = []
        var current: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if !current.isEmpty {
                    stanzas.append(current)
                    current = [:]
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":"), let first = line.first, first.isLetter else { continue }
            current[String(line[line.startIndex ..< colon])] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        if !current.isEmpty { stanzas.append(current) }
        return stanzas
    }
}

// MARK: - Installed

/// The packages `dpkg` says are installed, and what each of them provides.
public struct InstalledPackages: Sendable, Equatable {
    /// Name to version.
    public var versions: [String: String] = [:]
    /// A provided name (a virtual package) to the version it came with.
    public var provided: [String: String] = [:]

    public init() {}

    public init(status text: String) {
        for stanza in IndexedPackage.stanzas(text) {
            guard stanza["Status"]?.hasSuffix(" installed") == true, let name = stanza["Package"] else { continue }
            let version = stanza["Version"] ?? "0"
            versions[name] = version
            for line in (stanza["Provides"] ?? "").split(separator: ",") {
                let provided = String(line).split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !provided.isEmpty { self.provided[provided] = version }
            }
        }
    }

    public func satisfies(_ relation: PackageRelation) -> Bool {
        if let version = versions[relation.name], relation.accepts(version) { return true }
        if let version = provided[relation.name], relation.accepts(version) { return true }
        return false
    }
}

// MARK: - Planning

public enum ResolutionError: Error, Equatable, CustomStringConvertible {
    case badVersion(String)
    case unknownPackage(String)
    case unsatisfiable(package: String, relation: String)

    public var description: String {
        switch self {
        case let .badVersion(text): "\(text) is not a Debian version"
        case let .unknownPackage(name): "no repository index offers \(name)"
        case let .unsatisfiable(package, relation): "\(package) needs \(relation), and nothing offers it"
        }
    }
}

/// What to install, in the order that puts every dependency first.
public struct PackagePlan: Sendable, Equatable {
    public var install: [IndexedPackage]
    public var alreadyInstalled: [String]

    public init(install: [IndexedPackage] = [], alreadyInstalled: [String] = []) {
        self.install = install
        self.alreadyInstalled = alreadyInstalled
    }
}

public struct PackagePlanner: Sendable {
    /// Name to the package that would be installed, the newest version.
    public var candidates: [String: IndexedPackage] = [:]
    /// Virtual names to the package that provides them, first in index order.
    public var providers: [String: String] = [:]
    public var installed: InstalledPackages

    public init(index: [IndexedPackage], installed: InstalledPackages) {
        self.installed = installed
        for package in index {
            guard let version = try? DebianVersion(package.version) else { continue }
            if let current = candidates[package.name],
               let currentVersion = try? DebianVersion(current.version),
               currentVersion >= version
            {
                continue
            }
            candidates[package.name] = package
        }
        for package in index where providers[package.name] == nil {
            providers[package.name] = package.name
        }
        for package in index {
            for provided in package.provides where providers[provided] == nil {
                providers[provided] = package.name
            }
        }
    }

    /// Everything `names` needs, dependencies first. A package already
    /// installed at a version the relation accepts is left alone; one
    /// installed but too old is replaced by the index's.
    public func plan(installing names: [String]) throws -> PackagePlan {
        var plan = PackagePlan()
        var planned: Set<String> = []
        var visiting: Set<String> = []

        /// `reason` is the package that needs `name`, for the error.
        func visit(_ name: String, because reason: String?) throws {
            if planned.contains(name) { return }
            if installed.satisfies(PackageRelation(name: name)) {
                plan.alreadyInstalled.append(name)
                planned.insert(name)
                return
            }
            guard let package = candidates[name] else {
                throw reason.map { ResolutionError.unsatisfiable(package: $0, relation: name) }
                    ?? ResolutionError.unknownPackage(name)
            }
            guard visiting.insert(name).inserted else { return }
            for group in package.preDepends + package.depends {
                try satisfy(group, because: package.name)
            }
            visiting.remove(name)
            planned.insert(name)
            plan.install.append(package)
        }

        /// A group is met by the first alternative already installed or that
        /// can be installed; the others are not needed.
        func satisfy(_ group: [PackageRelation], because package: String) throws {
            if let met = group.first(where: { installed.satisfies($0) }) {
                if !planned.contains(met.name) {
                    plan.alreadyInstalled.append(met.name)
                    planned.insert(met.name)
                }
                return
            }
            if group.contains(where: { planned.contains($0.name) }) { return }
            for relation in group {
                if let candidate = providers[relation.name], candidates[candidate] != nil {
                    try visit(candidate, because: package)
                    return
                }
            }
            throw ResolutionError.unsatisfiable(package: package, relation: group.map(\.name).joined(separator: " | "))
        }

        for name in names { try visit(name, because: nil) }
        return plan
    }
}

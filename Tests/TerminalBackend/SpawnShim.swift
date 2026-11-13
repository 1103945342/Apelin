// Stand-ins for the two types Apelind/Spawn.swift declares, which the checks
// do not compile: that file's privilege check needs Apelind/System.swift,
// which imports XPC and does not build for iOS. Nothing here is exercised by
// the checks — the shells they start run with no identity drop.

import ApelinProtocol
import Darwin

struct SpawnIdentity {
    var uid: uid_t
    var gid: gid_t

    static let mobile = SpawnIdentity(uid: uid_t(WorkerRole.mobileUID), gid: gid_t(WorkerRole.mobileGID))
}

struct ProcessCredentials {
    var uid: uid_t
    var gid: gid_t

    init?(pid: pid_t) {
        guard pid == getpid() else { return nil }
        uid = getuid()
        gid = getgid()
    }
}

enum SpawnError: Error {
    case privilegesKept(pid_t)
}

func verifyDropped(_ pid: pid_t, to _: SpawnIdentity) throws {
    throw SpawnError.privilegesKept(pid)
}

import Foundation

// The iLink protocol's own checks: the trust policy, the session file, the
// inbound filter, login, the long poll, and sends. Nothing here touches the
// network; the checks answer from a transport of their own.
//
// `Scripts/test-wechat.sh` compiles the package's sources, these checks and
// this file into one program, and runs it on the Mac or, with `--device`, on
// the phone after signing it.

try checkIlinkTrustPolicy()
try checkIlinkSessionStore()
try checkIlinkInboundFilter()
try await checkIlinkLoginFlow()
try await checkIlinkLoginRedirects()
try await checkIlinkLoginCodeReplacement()
try await checkIlinkPolling()
try await checkIlinkParseFallback()
try await checkIlinkPollingFailures()
try await checkIlinkRetSemantics()
try await checkIlinkCursorNeedsTheWrite()
try await checkIlinkUnreadableSession()
try await checkIlinkSending()
print("ok: the iLink protocol's trust, login, polling, sends and session file")

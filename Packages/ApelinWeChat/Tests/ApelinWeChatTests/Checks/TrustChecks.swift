import ApelinWeChat
import Foundation

/// The addresses the token may go to, the IDC moves the server may ask for,
/// and the client version header.
func checkIlinkTrustPolicy() throws {
    let trust = IlinkTrustPolicy.wechat
    let api = URL(string: "https://ilinkai.weixin.qq.com/ilink/bot/getupdates")!

    try expect(trust.permits(api), "the API root is permitted")
    try expect(!trust.permits(URL(string: "http://ilinkai.weixin.qq.com/x")!), "plain HTTP is refused")
    try expect(!trust.permits(URL(string: "https://example.com/x")!), "another host is refused")
    try expect(!trust.permits(URL(string: "https://ilinkai.weixin.qq.com:8443/x")!), "a non-default port is refused")
    try expect(!trust.permits(URL(string: "https://ilinkai.weixin.qq.com.evil.com/x")!), "a suffix trick is refused")
    try expect(!trust.permits(URL(string: "https://weixin.qq.com.evil.com/x")!), "weixin.qq.com as a prefix is refused")
    try expect(!trust.permits(URL(string: "https://user:pass@ilinkai.weixin.qq.com/x")!), "userinfo is refused")
    try expect(trust.permits(URL(string: "https://idc.weixin.qq.com/x")!), "a weixin IDC host is permitted")

    try expect(trust.baseURL(from: "https://idc.weixin.qq.com") != nil, "a permitted baseurl is accepted")
    try expect(trust.baseURL(from: "http://idc.weixin.qq.com") == nil, "an HTTP baseurl is refused")
    try expect(trust.baseURL(from: "https://evil.example") == nil, "a foreign baseurl is refused")
    try expect(trust.baseURL(from: "https://idc.weixin.qq.com/some/path")?.path == "", "the baseurl keeps only the host")

    let sameHost = URL(string: "https://ilinkai.weixin.qq.com/other")!
    let crossHost = URL(string: "https://idc.weixin.qq.com/other")!
    try expectEqual(
        trust.redirectDecision(from: api, to: sameHost, carriesCredential: true, hop: 1, maximum: 3),
        IlinkRedirectDecision.follow,
        "a same-host redirect is followed"
    )
    try expectEqual(
        trust.redirectDecision(from: api, to: crossHost, carriesCredential: true, hop: 1, maximum: 3),
        IlinkRedirectDecision.crossHostCredential,
        "the token never follows a cross-host redirect"
    )
    try expectEqual(
        trust.redirectDecision(from: api, to: crossHost, carriesCredential: false, hop: 1, maximum: 3),
        IlinkRedirectDecision.follow,
        "a request without the token may move"
    )
    try expectEqual(
        trust.redirectDecision(
            from: api,
            to: URL(string: "http://ilinkai.weixin.qq.com/x")!,
            carriesCredential: false,
            hop: 1,
            maximum: 3
        ),
        IlinkRedirectDecision.insecureScheme,
        "an HTTPS downgrade is refused"
    )
    try expectEqual(
        trust.redirectDecision(from: api, to: sameHost, carriesCredential: false, hop: 4, maximum: 3),
        IlinkRedirectDecision.tooManyRedirects,
        "the hop limit is enforced"
    )

    try expectEqual(IlinkConfiguration.clientVersion(from: "2.4.10"), 132106, "2.4.10 is 0x0002040A")
    try expect(IlinkConfiguration.clientVersion(from: "2.4") == nil, "a short version is refused")
    try expect(IlinkConfiguration.clientVersion(from: "2.300.1") == nil, "an out-of-range part is refused")
    try expectEqual(IlinkConfiguration().clientVersion, 132106, "the default configuration carries 132106")
}

import Foundation

/// Everything a client is set up with. The defaults are the protocol's own.
public struct IlinkConfiguration: Sendable, Equatable {
    /// The API root the adapter fixes. It is an API, not the documentation page.
    public static let defaultBaseURL = URL(string: "https://ilinkai.weixin.qq.com")!
    public static let defaultChannelVersion = "2.4.10"
    /// `0x00MMNNPP` of 2.4.10.
    public static let defaultClientVersion = 132106

    public var apiBaseURL: URL
    /// The `iLink-App-Id` header.
    public var appID: String
    /// `base_info.channel_version`.
    public var channelVersion: String
    /// The `iLink-App-ClientVersion` header: `0x00MMNNPP` in decimal.
    public var clientVersion: Int
    /// `base_info.bot_agent`.
    public var agent: String
    /// The read timeout of one `getupdates` round. A timeout is a normal empty
    /// round and does not count as a failure.
    public var longPollTimeout: TimeInterval
    /// The read timeout of every other request.
    public var requestTimeout: TimeInterval
    /// How long a QR code is offered locally.
    public var qrLifetime: TimeInterval
    /// How often a caller may poll a QR code before the server answers.
    public var qrPollInterval: TimeInterval
    /// How long a verify-code entry stays open.
    public var verifyCodeLifetime: TimeInterval
    /// How many QR codes one login may use.
    public var maxQRCodes: Int
    /// Consecutive failed `getupdates` rounds before polling stops.
    public var maxConsecutiveFailures: Int
    public var backoff: IlinkBackoff
    public var trust: IlinkTrustPolicy

    public init(
        apiBaseURL: URL = IlinkConfiguration.defaultBaseURL,
        appID: String = "bot",
        channelVersion: String = IlinkConfiguration.defaultChannelVersion,
        agent: String = "apelin",
        longPollTimeout: TimeInterval = 35,
        requestTimeout: TimeInterval = 15,
        qrLifetime: TimeInterval = 300,
        qrPollInterval: TimeInterval = 1,
        verifyCodeLifetime: TimeInterval = 120,
        maxQRCodes: Int = 3,
        maxConsecutiveFailures: Int = 8,
        backoff: IlinkBackoff = IlinkBackoff(),
        trust: IlinkTrustPolicy = .wechat
    ) {
        self.apiBaseURL = apiBaseURL
        self.appID = appID
        self.channelVersion = channelVersion
        self.agent = agent
        self.longPollTimeout = longPollTimeout
        self.requestTimeout = requestTimeout
        self.qrLifetime = qrLifetime
        self.qrPollInterval = qrPollInterval
        self.verifyCodeLifetime = verifyCodeLifetime
        self.maxQRCodes = maxQRCodes
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.backoff = backoff
        self.trust = trust
        self.clientVersion = IlinkConfiguration.clientVersion(from: channelVersion)
            ?? IlinkConfiguration.defaultClientVersion
    }

    /// `"2.4.10"` → `0x0002040A` → 132106.
    public static func clientVersion(from version: String) -> Int? {
        let parts = version.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0, number <= 255 else { return nil }
            numbers.append(number)
        }
        return (numbers[0] << 16) | (numbers[1] << 8) | numbers[2]
    }
}

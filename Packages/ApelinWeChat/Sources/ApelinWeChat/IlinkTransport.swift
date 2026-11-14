import Foundation

/// One HTTP exchange, as the client hands it to a transport.
///
/// Its descriptions carry the method, the host, the path and the header names —
/// never a header value, a body or the query string — so printing a request
/// can never print a token or a login id.
public struct IlinkHTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    /// The bot token is in this request's headers. A redirect from it never
    /// leaves the host it was sent to.
    public var carriesCredential: Bool

    public init(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval,
        carriesCredential: Bool
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.carriesCredential = carriesCredential
    }
}

extension IlinkHTTPRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let host = url.host ?? "?"
        return "IlinkHTTPRequest(\(method) \(host)\(url.path), headers: \(headers.keys.sorted()), body: \(body?.count ?? 0) bytes)"
    }

    public var debugDescription: String { description }
}

public struct IlinkHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// The HTTP layer, replaceable: the checks drive the protocol with their own,
/// and another process can put its own network in front of the client.
public protocol IlinkTransport: Sendable {
    func send(_ request: IlinkHTTPRequest) async throws -> IlinkHTTPResponse
}

/// URLSession with the trust policy in front of the request and of every
/// redirect hop.
public final class URLSessionIlinkTransport: @unchecked Sendable, IlinkTransport {
    private let session: URLSession
    private let trust: IlinkTrustPolicy
    private let maximumRedirects: Int

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        trust: IlinkTrustPolicy = .wechat,
        maximumRedirects: Int = 3
    ) {
        self.trust = trust
        self.maximumRedirects = maximumRedirects
        let sessionConfiguration = configuration.copy() as? URLSessionConfiguration ?? configuration
        sessionConfiguration.timeoutIntervalForResource = 120
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func send(_ request: IlinkHTTPRequest) async throws -> IlinkHTTPResponse {
        guard trust.permits(request.url) else {
            throw IlinkFailure.untrustedURL(request.url)
        }
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: request.timeout
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let guardrail = IlinkRedirectGuard(
            trust: trust,
            origin: request.url,
            carriesCredential: request.carriesCredential,
            maximum: maximumRedirects
        )
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: guardrail)
            if let refusal = guardrail.refusal {
                throw refusal
            }
            guard let http = response as? HTTPURLResponse else {
                throw IlinkFailure.transport("not an HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let text = value as? String {
                    headers[name] = text
                }
            }
            return IlinkHTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let failure as IlinkFailure {
            throw failure
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw IlinkFailure.timedOut
            case .cancelled:
                throw IlinkFailure.cancelled
            default:
                throw IlinkFailure.transport("url-error-\(error.code.rawValue)")
            }
        } catch is CancellationError {
            throw IlinkFailure.cancelled
        } catch {
            throw IlinkFailure.transport("transport")
        }
    }
}

/// One redirect per task: the policy is asked about each hop, and a refusal is
/// remembered for the caller, since the delegate cannot throw.
private final class IlinkRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trust: IlinkTrustPolicy
    private let origin: URL
    private let carriesCredential: Bool
    private let maximum: Int
    private let lock = NSLock()
    private var hops = 0
    private var storedRefusal: IlinkFailure?

    init(trust: IlinkTrustPolicy, origin: URL, carriesCredential: Bool, maximum: Int) {
        self.trust = trust
        self.origin = origin
        self.carriesCredential = carriesCredential
        self.maximum = maximum
    }

    var refusal: IlinkFailure? {
        lock.lock()
        defer { lock.unlock() }
        return storedRefusal
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let target = request.url ?? origin
        lock.lock()
        hops += 1
        let decision = trust.redirectDecision(
            from: origin,
            to: target,
            carriesCredential: carriesCredential,
            hop: hops,
            maximum: maximum
        )
        if decision == .follow {
            lock.unlock()
            completionHandler(request)
            return
        }
        storedRefusal = IlinkFailure.redirectRefused(to: target, reason: decision)
        lock.unlock()
        completionHandler(nil)
    }
}

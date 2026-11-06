import Foundation
import KWWKAI

/// web_search: search the web for current information using Parallel AI's MCP
/// search service. The worker fetches results itself, as mobile, through a
/// session that keeps no cookie, cache or credential. Search queries are sent
/// to the service, which returns structured results with summaries, URLs and
/// snippets.
struct WebSearch: Sendable {
    static let timeoutSeconds = 30
    static let mcpURL = "https://search.parallel.ai/mcp"
    
    static let shared = WebSearch()
    
    private let session: URLSession
    
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(Self.timeoutSeconds)
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Apelin",
            "Accept": "application/json, text/event-stream",
        ]
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }
    
    /// Search for `query` and return structured results.
    func search(_ arguments: JSONValue) async throws -> WebSearchResult {
        let query = try arguments.requireString("query")
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolArgumentError("query cannot be empty")
        }
        
        return try await Self.withinTimeout { try await self.performSearch(query: query) }
    }
    
    private func performSearch(query: String) async throws -> WebSearchResult {
        let requestBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "web_search",
                "arguments": [
                    "objective": query,
                    "search_queries": [query],
                    "session_id": "apelin-ios"
                ]
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw ToolDeniedError(message: "failed to encode search request")
        }
        
        guard let url = URL(string: Self.mcpURL) else {
            throw ToolDeniedError(message: "invalid MCP URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolDeniedError(message: "search service did not answer over HTTP")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ToolDeniedError(message: "search service returned HTTP \(httpResponse.statusCode)")
        }
        
        return try Self.parseResponse(data, query: query)
    }
    
    /// Parse MCP response, handling both JSON and SSE formats.
    private static func parseResponse(_ data: Data, query: String) throws -> WebSearchResult {
        // Try to parse as text first (for SSE format)
        if let text = String(data: data, encoding: .utf8) {
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            
            for line in lines {
                let jsonStr: String
                if line.hasPrefix("data: ") {
                    jsonStr = String(line.dropFirst(6))
                } else if line.hasPrefix("{") {
                    jsonStr = line
                } else {
                    continue
                }
                
                guard let jsonData = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let content = result["content"] as? [[String: Any]],
                      let firstContent = content.first,
                      let resultText = firstContent["text"] as? String else {
                    continue
                }
                
                // Try to parse the result text as JSON for structured results
                if let resultData = resultText.data(using: .utf8),
                   let resultJSON = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                   let rawResults = resultJSON["results"] as? [[String: Any]] {
                    // Convert [[String: Any]] to [[String: String]]
                    let stringResults = rawResults.map { dict -> [String: String] in
                        dict.compactMapValues { value in
                            if let str = value as? String {
                                return str
                            } else if let num = value as? CustomStringConvertible {
                                return num.description
                            }
                            return nil
                        }
                    }
                    return WebSearchResult(query: query, results: stringResults, raw: resultText)
                }
                
                // If not structured, return as plain text
                return WebSearchResult(query: query, results: nil, raw: resultText)
            }
        }
        
        throw ToolDeniedError(message: "search service returned no readable results")
    }
    
    private static func withinTimeout(_ body: @escaping @Sendable () async throws -> WebSearchResult) async throws -> WebSearchResult {
        try await withThrowingTaskGroup(of: WebSearchResult.self) { group in
            group.addTask(operation: body)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw ToolTimeoutError(message: "search did not complete within \(timeoutSeconds) seconds")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

/// Search results from the MCP service.
struct WebSearchResult: Sendable {
    var query: String
    /// Structured results if available: each with title, url, snippet
    var results: [[String: String]]?
    /// Raw text response from the service
    var raw: String
    
    /// Format as markdown for the model to read.
    var answer: String {
        var lines: [String] = []
        lines.append("Search results for: \(query)")
        lines.append("")
        
        if let results = results, !results.isEmpty {
            lines.append("Found \(results.count) result\(results.count == 1 ? "" : "s"):")
            lines.append("")
            
            for (index, result) in results.enumerated() {
                lines.append("\(index + 1). **\(result["title"] ?? "Untitled")**")
                if let url = result["url"] {
                    lines.append("   \(url)")
                }
                if let snippet = result["snippet"], !snippet.isEmpty {
                    lines.append("   \(snippet)")
                }
                lines.append("")
            }
        } else {
            // Plain text result
            lines.append(raw)
        }
        
        return lines.joined(separator: "\n")
    }
}

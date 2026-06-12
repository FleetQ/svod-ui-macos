import Foundation

// MARK: - LiveSvodClient
//
// URLSession HTTP + WebSocket implementation of SvodClient. Talks only to the
// loopback App API. Status-code mapping follows the contract: 404 → notFound,
// 409 → conflict(ConflictBody), 400 → badRequest, connection failure → offline.

public final class LiveSvodClient: SvodClient, @unchecked Sendable {

    public let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL = URL(string: "http://127.0.0.1:7517")!,
                session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.waitsForConnectivity = false
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: lifecycle
    public func health() async throws -> Health { try await get("/health") }
    public func ready() async throws -> Ready { try await get("/ready") }

    // MARK: files
    public func tree() async throws -> TreeNode { try await get("/api/v1/tree") }

    public func readFile(path: String) async throws -> FileContent {
        try await get("/api/v1/file", query: [.init(name: "path", value: path)])
    }

    @discardableResult
    public func writeFile(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        try await send("/api/v1/file", method: "PUT",
                       query: [.init(name: "path", value: path)],
                       body: WriteRequest(content: content, expectedRevision: expectedRevision))
    }

    @discardableResult
    public func deleteFile(path: String, expectedRevision: String?) async throws -> WriteResult {
        var q = [URLQueryItem(name: "path", value: path)]
        if let expectedRevision { q.append(.init(name: "expectedRevision", value: expectedRevision)) }
        return try await sendNoBody("/api/v1/file", method: "DELETE", query: q)
    }

    @discardableResult
    public func moveFile(from: String, to: String, expectedRevision: String?) async throws -> MoveResult {
        try await send("/api/v1/file/move", method: "POST",
                       body: MoveRequest(from: from, to: to, expectedRevision: expectedRevision))
    }

    @discardableResult
    public func restoreFile(trashPath: String, to: String?) async throws -> WriteResult {
        try await send("/api/v1/file/restore", method: "POST",
                       body: RestoreRequest(trashPath: trashPath, to: to))
    }

    // MARK: history
    public func history(path: String, max: Int?) async throws -> [CommitInfo] {
        var q = [URLQueryItem(name: "path", value: path)]
        if let max { q.append(.init(name: "max", value: String(max))) }
        struct Wrapper: Decodable { let commits: [CommitInfo] }
        let w: Wrapper = try await get("/api/v1/file/history", query: q)
        return w.commits
    }

    public func diff(path: String, from: String, to: String) async throws -> DiffResult {
        try await get("/api/v1/file/diff", query: [
            .init(name: "path", value: path),
            .init(name: "from", value: from),
            .init(name: "to", value: to),
        ])
    }

    public func revision(path: String, revision: String) async throws -> FileContent {
        try await get("/api/v1/file/revision", query: [
            .init(name: "path", value: path),
            .init(name: "revision", value: revision),
        ])
    }

    // MARK: graph / links
    public func fileLinks(path: String) async throws -> FileLinks {
        try await get("/api/v1/file/links", query: [.init(name: "path", value: path)])
    }
    public func graph() async throws -> Graph { try await get("/api/v1/graph") }

    // MARK: search
    public func search(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?) async throws -> SearchResult {
        var q = [URLQueryItem(name: "q", value: query),
                 URLQueryItem(name: "mode", value: mode.rawValue)]
        if let limit { q.append(.init(name: "limit", value: String(limit))) }
        for t in tags { q.append(.init(name: "tags", value: t)) }
        if let pathPrefix, !pathPrefix.isEmpty { q.append(.init(name: "pathPrefix", value: pathPrefix)) }
        return try await get("/api/v1/search", query: q)
    }

    // MARK: meta
    public func tags() async throws -> Tags { try await get("/api/v1/tags") }
    public func settings() async throws -> Settings { try await get("/api/v1/settings") }
    public func indexStatus() async throws -> IndexStatus { try await get("/api/v1/index/status") }
    public func metrics() async throws -> Metrics { try await get("/api/v1/metrics") }
    public func conflicts() async throws -> Conflicts { try await get("/api/v1/conflicts") }

    // MARK: events (WebSocket)
    public func events() -> AsyncThrowingStream<SvodEvent, Error> {
        let wsURL = Self.websocketURL(from: baseURL)
        let task = session.webSocketTask(with: wsURL)
        let decoder = self.decoder
        return AsyncThrowingStream { continuation in
            task.resume()
            func receive() {
                task.receive { result in
                    switch result {
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    case .success(let message):
                        let data: Data?
                        switch message {
                        case .string(let s): data = s.data(using: .utf8)
                        case .data(let d):   data = d
                        @unknown default:    data = nil
                        }
                        if let data, let ev = try? decoder.decode(SvodEvent.self, from: data) {
                            continuation.yield(ev)
                        }
                        receive()   // keep listening
                    }
                }
            }
            receive()
            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    static func websocketURL(from base: URL) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/api/v1/events"
        return comps.url!
    }

    // MARK: - HTTP plumbing
    private func makeURL(_ path: String, query: [URLQueryItem]) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(""), resolvingAgainstBaseURL: false)!
        comps.path = path
        comps.queryItems = query.isEmpty ? nil : query
        return comps.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var req = URLRequest(url: makeURL(path, query: query))
        req.httpMethod = "GET"
        return try await perform(req)
    }

    private func send<T: Decodable, B: Encodable>(_ path: String, method: String,
                                                  query: [URLQueryItem] = [], body: B) async throws -> T {
        var req = URLRequest(url: makeURL(path, query: query))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        return try await perform(req)
    }

    private func sendNoBody<T: Decodable>(_ path: String, method: String, query: [URLQueryItem] = []) async throws -> T {
        var req = URLRequest(url: makeURL(path, query: query))
        req.httpMethod = method
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlErr as URLError {
            switch urlErr.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .timedOut:
                throw SvodClientError.offline
            default:
                throw SvodClientError.transport(urlErr.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw SvodClientError.invalidResponse }

        switch http.statusCode {
        case 200...299:
            do { return try decoder.decode(T.self, from: data) }
            catch { throw SvodClientError.decoding(String(describing: error)) }
        case 404:
            throw SvodClientError.notFound
        case 409:
            if let body = try? decoder.decode(ConflictBody.self, from: data) {
                throw SvodClientError.conflict(body)
            }
            throw SvodClientError.http(status: 409, message: "Conflict")
        case 400:
            throw SvodClientError.badRequest(Self.message(from: data, decoder: decoder))
        default:
            throw SvodClientError.http(status: http.statusCode, message: Self.message(from: data, decoder: decoder))
        }
    }

    private static func message(from data: Data, decoder: JSONDecoder) -> String? {
        (try? decoder.decode(APIErrorBody.self, from: data))?.message
    }
}

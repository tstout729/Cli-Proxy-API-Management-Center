import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ConnectionConfiguration: Sendable {
    public let baseURL: URL
    public let keyPath: String
    public init(baseURL: String = "http://127.0.0.1:8318", keyPath: String? = nil) throws {
        guard let parts = URLComponents(string: baseURL), let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host)),
              let url = parts.url else { throw UsageFailure.configuration }
        self.baseURL = url
        self.keyPath = keyPath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cliproxyapi-custom/management-key").path
    }
    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        try Self(baseURL: environment["AI_USAGE_BASE_URL"] ?? "http://127.0.0.1:8318", keyPath: environment["AI_USAGE_KEY_PATH"])
    }
}

public enum ManagementKey {
    public static func read(path: String) throws -> String {
        // Open once without following a final symlink; validate the opened file, avoiding a stat/read race.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw UsageFailure.keyUnavailable }
        defer { _ = close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw UsageFailure.keyUnavailable }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == getuid(),
              (info.st_mode & 0o7777) == 0o600 else { throw UsageFailure.keyPermissions }
        guard info.st_size > 0, info.st_size <= 16_384 else { throw UsageFailure.keyUnavailable }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Darwin)
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
                #else
                Glibc.read(descriptor, bytes.baseAddress!, bytes.count)
                #endif
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw UsageFailure.keyUnavailable
            }
            if received == 0 { break }
            data.append(contentsOf: buffer.prefix(received))
            guard data.count <= 16_384 else { throw UsageFailure.keyUnavailable }
        }
        guard let raw = String(data: data, encoding: .utf8) else { throw UsageFailure.keyUnavailable }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { throw UsageFailure.keyUnavailable }
        return key
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public protocol ManagementTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

// Stateless delegate: reject redirects so a management key can never follow one to another origin.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class URLSessionTransport: ManagementTransport, Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 2_097_152 else {
                throw UsageFailure.invalidResponse
            }
            return HTTPResponse(status: response.statusCode, data: data)
        } catch let failure as UsageFailure { throw failure }
        catch { throw UsageFailure.connection } // Never expose URLSession error descriptions/URLs.
    }
}

public struct UsageCall: Encodable, Sendable {
    public let auth_index: String
    public let method = "GET"
    public let url: String
    public let header: [String: String]

    // Only these two usage URLs can enter an api-call. There is no arbitrary URL or method input.
    public init(provider: Provider, authIndex: String, chatGPTAccountID: String? = nil) {
        self.auth_index = authIndex
        var headers = ["Authorization": "Bearer $TOKEN$", "Content-Type": "application/json"]
        switch provider {
        case .claude:
            url = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
            headers["anthropic-beta"] = "oauth-2025-04-20"
            headers["User-Agent"] = "claude-cli/2.1.280 (external, cli)"
        case .codex:
            url = "https://chatgpt.com/backend-api/wham/usage"
            if let chatGPTAccountID { headers["Chatgpt-Account-Id"] = chatGPTAccountID }
            headers["User-Agent"] = "codex-tui/0.149.1 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.149.1)"
        }
        header = headers
    }
}

public struct ManagementClient: Sendable {
    private let configuration: ConnectionConfiguration
    private let transport: any ManagementTransport
    public init(configuration: ConnectionConfiguration, transport: any ManagementTransport = URLSessionTransport()) {
        self.configuration = configuration; self.transport = transport
    }
    public func credentials(key: String) async throws -> [Credential] {
        let response = try await request(path: "credentials", key: key)
        return try UsageParser.credentials(response)
    }
    public func usage(for credential: Credential, key: String, now: Date? = nil) async throws -> UsageReading {
        guard let authIndex = credential.authIndex else { throw UsageFailure.missingAuthIndex }
        let body = try JSONEncoder().encode(UsageCall(provider: credential.provider, authIndex: authIndex,
                                                    chatGPTAccountID: credential.chatGPTAccountID))
        let response = try await request(path: "requests/api-call", key: key, body: body)
        let wrapper = try JSONValue.parse(response)
        guard let code = wrapper["status_code"].number, code.rounded() == code,
              (100...599).contains(code) else { throw UsageFailure.invalidResponse }
        if code == 401 { throw UsageFailure.providerUnauthorized }
        guard (200..<300).contains(code) else { throw UsageFailure.upstreamUnavailable }
        guard let text = wrapper["body"].string else { throw UsageFailure.invalidResponse }
        let reading = try UsageParser.reading(provider: credential.provider, body: Data(text.utf8), now: now ?? Date())
        guard reading.hasUsage || reading.resets != nil else { throw UsageFailure.notReported }
        return reading
    }
    private func request(path: String, key: String, body: Data? = nil) async throws -> Data {
        // Private endpoint construction; no credentials/download, grants/redeem, spend, or provider access.
        let url = configuration.baseURL.appendingPathComponent("v8/management/\(path)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch let failure as UsageFailure { throw failure }
        catch { throw UsageFailure.connection }
        if response.status == 401 { throw UsageFailure.managementUnauthorized }
        guard (200..<300).contains(response.status) else { throw UsageFailure.connection }
        return response.data
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import UsageCore

private func response(_ status: Int = 200, _ text: String) -> HTTPResponse {
    HTTPResponse(status: status, data: Data(text.utf8))
}
private func wrapped(_ body: String, status: Int = 200) throws -> HTTPResponse {
    HTTPResponse(status: 200, data: try JSONEncoder().encode(JSONValue.object([
        "status_code": .number(Double(status)), "body": .string(body)
    ])))
}
private let syntheticBody = #"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2030-01-02T00:00:00Z"}}"#

// A controllable barrier, rather than wall-clock sleeps, makes concurrency assertions deterministic.
private actor RequestGate {
    let target: Int
    private var arrivals = 0
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var reached: CheckedContinuation<Void, Never>?
    init(target: Int) { self.target = target }
    func enter() async {
        arrivals += 1
        if arrivals >= target { reached?.resume(); reached = nil }
        if released { return }
        await withCheckedContinuation { held.append($0) }
    }
    func waitUntilReached() async {
        if arrivals >= target { return }
        await withCheckedContinuation { reached = $0 }
    }
    func release() {
        released = true
        let waiting = held; held = []
        for continuation in waiting { continuation.resume() }
    }
}

private actor StubTransport: ManagementTransport {
    private var inventory: [HTTPResponse]
    private var usage: [String: [HTTPResponse]]
    private let gate: RequestGate?
    private var requests: [URLRequest] = []
    private var active = 0
    private var peak = 0
    init(inventory: [HTTPResponse], usage: [String: [HTTPResponse]], gate: RequestGate? = nil) {
        self.inventory = inventory; self.usage = usage; self.gate = gate
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.httpMethod == "GET" {
            guard let first = inventory.first else { return response(500, "{}") }
            if inventory.count > 1 { inventory.removeFirst() }
            return first
        }
        let body = try JSONValue.parse(request.httpBody ?? Data())
        let index = body["auth_index"].string ?? ""
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if let gate { await gate.enter() }
        guard let first = usage[index]?.first else { return response(500, "{}") }
        if (usage[index]?.count ?? 0) > 1 { usage[index]?.removeFirst() }
        return first
    }
    func recorded() -> [URLRequest] { requests }
    func maximumConcurrency() -> Int { peak }
}

// XCTest controls test lifetime; all test properties are immutable and transport mutation is actor-isolated.
final class ClientTests: XCTestCase, @unchecked Sendable {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func configuration() throws -> ConnectionConfiguration {
        try ConnectionConfiguration(baseURL: "http://127.0.0.1:8318", keyPath: "/synthetic-test-only")
    }
    private func engine(_ transport: StubTransport) throws -> RefreshEngine {
        try RefreshEngine(configuration: configuration(), transport: transport, keyLoader: { _ in "synthetic-management-only" })
    }
    func inventory(_ indices: [String]) throws -> HTTPResponse {
        let files = indices.map { JSONValue.object([
            "provider": .string("claude"), "auth_index": .string($0), "label": .string("Synthetic \($0)")
        ]) }
        return HTTPResponse(status: 200, data: try JSONEncoder().encode(JSONValue.object(["files": .array(files)])))
    }

    func testFixedReadOnlyV8RequestsAndLiteralProxyToken() async throws {
        let transport = StubTransport(inventory: [try inventory(["a"])], usage: ["a": [try wrapped(syntheticBody)]])
        let result = try await engine(transport).refresh(now: now)
        XCTAssertEqual(result.usageSuccesses, 1)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/v8/management/credentials")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[1].url?.path, "/v8/management/requests/api-call")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-management-only")
        let call = try JSONValue.parse(XCTUnwrap(requests[1].httpBody))
        XCTAssertEqual(call["method"].string, "GET")
        XCTAssertEqual(call["auth_index"].string, "a")
        XCTAssertEqual(call["url"].string, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        XCTAssertEqual(call["header"]["Authorization"].string, "Bearer $TOKEN$")
        XCTAssertEqual(call["header"]["anthropic-beta"].string, "oauth-2025-04-20")
        XCTAssertFalse(String(data: requests[1].httpBody!, encoding: .utf8)!.contains("synthetic-management-only"))
        let codex = UsageCall(provider: .codex, authIndex: "b")
        XCTAssertEqual(codex.url, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(codex.header["User-Agent"], "codex-tui/0.149.1 (Mac OS 26.5.2; arm64) iTerm.app/3.6.11 (codex-tui; 0.149.1)")
    }

    func testProxy401AndUpstream401HaveDifferentMeaning() async throws {
        let upstream = StubTransport(inventory: [try inventory(["a"])], usage: ["a": [try wrapped("{}", status: 401)]])
        let providerResult = try await engine(upstream).refresh(now: now)
        XCTAssertEqual(providerResult.accounts.first?.failure, .providerUnauthorized)
        XCTAssertNil(providerResult.connectionFailure)
        XCTAssertEqual(providerResult.accounts.first?.status(at: now), .loginNeeded)
        let proxy = StubTransport(inventory: [response(401, "synthetic error")], usage: [:])
        let proxyResult = try await engine(proxy).refresh(now: now)
        XCTAssertEqual(proxyResult.connectionFailure, .managementUnauthorized)
        XCTAssertTrue(proxyResult.accounts.isEmpty)
        let perAccountProxy = StubTransport(inventory: [try inventory(["a"])], usage: ["a": [response(401, "{}")]])
        let proxyUsageResult = try await engine(perAccountProxy).refresh(now: now)
        XCTAssertEqual(proxyUsageResult.accounts.first?.status(at: now), .connectionError)
        XCTAssertEqual(proxyUsageResult.connectionFailure, .managementUnauthorized)
    }

    func testFailedAndNotReportedRefreshRetainsLastGoodReading() async throws {
        let transport = StubTransport(inventory: [try inventory(["a"])], usage: ["a": [
            try wrapped(syntheticBody), response(500, "synthetic"),
            try wrapped(#"{"five_hour":null,"seven_day":null}"#)
        ]])
        let refreshEngine = try engine(transport)
        let first = await refreshEngine.refresh(now: now)
        let failed = await refreshEngine.refresh(now: now.addingTimeInterval(30))
        XCTAssertEqual(failed.accounts.first?.reading, first.accounts.first?.reading)
        XCTAssertTrue(try XCTUnwrap(failed.accounts.first).isStale(at: now.addingTimeInterval(30)))
        XCTAssertEqual(failed.usageErrors, 1)
        let missing = await refreshEngine.refresh(now: now.addingTimeInterval(60))
        XCTAssertEqual(missing.accounts.first?.reading, first.accounts.first?.reading)
        XCTAssertEqual(missing.accounts.first?.failure, .notReported)
        XCTAssertEqual(missing.accounts.first?.status(at: now.addingTimeInterval(60)), .stale)
    }

    func testInventoryFailureRetainsAccountsAndMarksHistorical() async throws {
        let transport = StubTransport(inventory: [try inventory(["a"]), response(401, "synthetic")],
                                      usage: ["a": [try wrapped(syntheticBody)]])
        let refreshEngine = try engine(transport)
        let first = await refreshEngine.refresh(now: now)
        let second = await refreshEngine.refresh(now: now.addingTimeInterval(60))
        XCTAssertEqual(second.accounts.first?.reading, first.accounts.first?.reading)
        XCTAssertEqual(second.inventoryUpdatedAt, now)
        XCTAssertEqual(second.attemptedAt, now.addingTimeInterval(60))
        XCTAssertEqual(second.connectionFailure, .managementUnauthorized)
        XCTAssertTrue(try XCTUnwrap(second.accounts.first).isStale(at: now))
    }

    func testOneAccountFailureDoesNotEraseOthersAndSummaryHasOnlyCounts() async throws {
        let transport = StubTransport(inventory: [try inventory(["a", "b", "c"])], usage: [
            "a": [try wrapped(syntheticBody)], "b": [try wrapped("{}", status: 401)],
            "c": [response(200, #"{"status_code":200,"body":"not JSON"}"#)]
        ])
        let result = try await engine(transport).refresh(now: now)
        XCTAssertEqual(result.accounts.count, 3)
        XCTAssertEqual(result.usageSuccesses, 1)
        XCTAssertEqual(result.usageErrors, 2)
        XCTAssertEqual(result.accounts.first { $0.credential.authIndex == "a" }?.reading?.windows.first?.usedPercent, 25)
        XCTAssertEqual(result.checkSummary, "claude_count=3 codex_count=0 usage_success_count=1 usage_error_count=2")
    }

    func testDisabledSkippedAndMissingIndexFailsLocally() async throws {
        let inv = response(200, #"{"files":[{"provider":"claude","auth_index":"disabled","disabled":true},{"provider":"codex","id":"synthetic-missing"}]}"#)
        let transport = StubTransport(inventory: [inv], usage: [:])
        let result = try await engine(transport).refresh(now: now)
        XCTAssertEqual(result.accounts.count, 2)
        XCTAssertEqual(result.accounts.first { $0.credential.disabled }?.status(at: now), .disabled)
        XCTAssertEqual(result.usageErrors, 1)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testBoundedConcurrencyAndRefreshCoalescing() async throws {
        let indices = ["a", "b", "c", "d", "e", "f"]
        let gate = RequestGate(target: 3)
        let usage = Dictionary(uniqueKeysWithValues: try indices.map { ($0, [try wrapped(syntheticBody)]) })
        let transport = StubTransport(inventory: [try inventory(indices)], usage: usage, gate: gate)
        let refreshEngine = try engine(transport)
        let firstTask = Task { await refreshEngine.refresh(now: now) }
        await gate.waitUntilReached()
        // Start another caller while all three workers are held at the barrier.
        let secondTask = Task { await refreshEngine.refresh(now: now) }
        // Release the held requests after scheduling the second caller.
        let releaseTask = Task { await gate.release() }
        let second = await secondTask.value
        let first = await firstTask.value
        await releaseTask.value
        XCTAssertEqual(first.usageSuccesses, 6)
        XCTAssertEqual(second.usageSuccesses, 6)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 1)
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 6)
        let maximum = await transport.maximumConcurrency()
        XCTAssertEqual(maximum, 3)
    }

    func testReportedCreditsDoNotImplyKnownQuota() async throws {
        let body = #"{"five_hour":null,"seven_day":null,"cedar_ember":{"eligible":true,"at_limit":false,"grants":[]}}"#
        let transport = StubTransport(inventory: [try inventory(["a"])], usage: ["a": [try wrapped(body)]])
        let result = try await engine(transport).refresh(now: now)
        let account = try XCTUnwrap(result.accounts.first)
        XCTAssertEqual(account.status(at: now), .unknown)
        XCTAssertEqual(account.reading?.resets?.available, 0)
        XCTAssertNil(account.reading?.windows.first?.usedPercent)
    }

    func testConfigurationRejectsUnsafeOrigins() throws {
        for base in ["http://example.test", "https://synthetic:placeholder@example.test", "https://example.test/path",
                     "https://example.test?key=synthetic", "file:///tmp/synthetic", "https://example.test/#fragment"] {
            XCTAssertThrowsError(try ConnectionConfiguration(baseURL: base))
        }
        XCTAssertNoThrow(try ConnectionConfiguration(baseURL: "http://127.0.0.1:9999"))
        XCTAssertNoThrow(try ConnectionConfiguration(baseURL: "https://management.example.test"))
    }
}

import Foundation

public enum Provider: String, CaseIterable, Sendable {
    case claude, codex
    public var title: String { self == .claude ? "Claude" : "Codex" }
}

public enum UsageFailure: String, Error, Sendable, Equatable {
    case configuration, keyUnavailable, keyPermissions, connection, managementUnauthorized
    case providerUnauthorized, upstreamUnavailable, invalidResponse, missingAuthIndex, notReported

    public var message: String {
        switch self {
        case .configuration: "Connection configuration is invalid."
        case .keyUnavailable: "Management key could not be read."
        case .keyPermissions: "Management key must be an owned regular file with permissions 0600."
        case .connection: "Proxy connection failed."
        case .managementUnauthorized: "Proxy rejected the management key."
        case .providerUnauthorized: "Provider login needed."
        case .upstreamUnavailable: "Provider usage request failed."
        case .invalidResponse: "Usage response was invalid."
        case .missingAuthIndex: "Credential has no auth index."
        case .notReported: "Usage was not reported."
        }
    }
    public var isConnection: Bool {
        switch self {
        case .configuration, .keyUnavailable, .keyPermissions, .connection, .managementUnauthorized: true
        default: false
        }
    }
}

public struct Credential: Identifiable, Sendable, Equatable {
    public let id: String
    public let authIndex: String?
    public let provider: Provider
    public let label: String
    public let disabled: Bool
    public let unavailable: Bool
    public let loginNeeded: Bool
    public let chatGPTAccountID: String?

    public init(id: String, authIndex: String?, provider: Provider, label: String,
                disabled: Bool = false, unavailable: Bool = false, loginNeeded: Bool = false,
                chatGPTAccountID: String? = nil) {
        self.id = id; self.authIndex = authIndex; self.provider = provider; self.label = label
        self.disabled = disabled; self.unavailable = unavailable; self.loginNeeded = loginNeeded
        self.chatGPTAccountID = chatGPTAccountID
    }
}

public enum WindowPeriod: Sendable, Equatable {
    case fiveHour, weekly, monthly, other(Double), unknown
    public var title: String {
        switch self {
        case .fiveHour: "5-hour"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .other(let seconds): "\(Int(seconds / 3600))h window"
        case .unknown: "Unknown window"
        }
    }
    public static func classify(seconds: Double?) -> Self {
        guard let seconds, seconds > 0, seconds <= 366 * 86400 else { return .unknown }
        if seconds == 18000 { return .fiveHour }
        if seconds == 604800 { return .weekly }
        if (28 * 86400...31 * 86400).contains(seconds) { return .monthly }
        return .other(seconds)
    }
}

public struct UsageWindow: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let period: WindowPeriod
    public let usedPercent: Double?
    public let resetAt: Date?
    public let isOverall: Bool
    public init(id: String, label: String, period: WindowPeriod, usedPercent: Double?, resetAt: Date?, isOverall: Bool) {
        self.id = id; self.label = label; self.period = period; self.usedPercent = usedPercent
        self.resetAt = resetAt; self.isOverall = isOverall
    }
    public func resetPassed(at now: Date) -> Bool { resetAt.map { $0 <= now } ?? false }
}

public struct ResetAvailability: Sendable, Equatable {
    public let available: Int?
    public let usableNow: Int?
    // The earliest expiry/boundary prevents a cached count from being presented as current.
    public let validUntil: Date?
    public init(available: Int?, usableNow: Int?, validUntil: Date? = nil) {
        self.available = available; self.usableNow = usableNow; self.validUntil = validUntil
    }
}

public struct UsageReading: Sendable, Equatable {
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    public let overallLimitReached: Bool
    public let limitedScopes: [String]
    public let resets: ResetAvailability?
    public init(windows: [UsageWindow], fetchedAt: Date, overallLimitReached: Bool = false,
                limitedScopes: [String] = [], resets: ResetAvailability? = nil) {
        self.windows = windows; self.fetchedAt = fetchedAt; self.overallLimitReached = overallLimitReached
        self.limitedScopes = limitedScopes; self.resets = resets
    }
    public var hasUsage: Bool { windows.contains { $0.usedPercent != nil } || overallLimitReached || !limitedScopes.isEmpty }
}

public enum AccountStatus: String, Sendable {
    case reported = "Usage reported", exhausted = "Limit reached", modelLimited = "Model limit reached"
    case loginNeeded = "Login needed", disabled = "Disabled", unavailable = "Unavailable"
    case unknown = "Unknown", stale = "Stale", connectionError = "Connection error"
}

public struct AccountState: Identifiable, Sendable, Equatable {
    public var credential: Credential
    public var reading: UsageReading?
    public var failure: UsageFailure?
    public var id: String { credential.id }
    public init(credential: Credential, reading: UsageReading? = nil, failure: UsageFailure? = nil) {
        self.credential = credential; self.reading = reading; self.failure = failure
    }
    public func isStale(at now: Date) -> Bool {
        guard let reading else { return false }
        return failure != nil || now.timeIntervalSince(reading.fetchedAt) > 600
            || reading.windows.contains { $0.resetPassed(at: now) }
    }
    public func status(at now: Date) -> AccountStatus {
        if credential.disabled { return .disabled }
        if credential.loginNeeded || failure == .providerUnauthorized { return .loginNeeded }
        if failure?.isConnection == true { return .connectionError }
        if isStale(at: now) { return .stale }
        guard let reading, failure == nil else { return credential.unavailable ? .unavailable : .unknown }
        if reading.overallLimitReached || reading.windows.contains(where: { $0.isOverall && $0.usedPercent == 100 }) { return .exhausted }
        if credential.unavailable { return .unavailable }
        if !reading.limitedScopes.isEmpty || reading.windows.contains(where: { !$0.isOverall && $0.usedPercent == 100 }) { return .modelLimited }
        // Neither a missing weekly window nor an unknown reset implies usable capacity.
        let overall = reading.windows.filter(\.isOverall)
        let hasFive = overall.contains { $0.period == .fiveHour && $0.usedPercent != nil && $0.resetAt != nil }
        let hasWeekly = overall.contains { $0.period == .weekly && $0.usedPercent != nil && $0.resetAt != nil }
        return hasFive && hasWeekly ? .reported : .unknown
    }
}

public struct RefreshSnapshot: Sendable {
    public var accounts: [AccountState]
    public var attemptedAt: Date?
    public var inventoryUpdatedAt: Date?
    public var connectionFailure: UsageFailure?
    public var usageSuccesses: Int
    public var usageErrors: Int
    public init(accounts: [AccountState] = [], attemptedAt: Date? = nil, inventoryUpdatedAt: Date? = nil,
                connectionFailure: UsageFailure? = nil, usageSuccesses: Int = 0, usageErrors: Int = 0) {
        self.accounts = accounts; self.attemptedAt = attemptedAt; self.inventoryUpdatedAt = inventoryUpdatedAt
        self.connectionFailure = connectionFailure; self.usageSuccesses = usageSuccesses; self.usageErrors = usageErrors
    }
    public var checkSummary: String {
        let claude = accounts.filter { $0.credential.provider == .claude }.count
        let codex = accounts.filter { $0.credential.provider == .codex }.count
        return "claude_count=\(claude) codex_count=\(codex) usage_success_count=\(usageSuccesses) usage_error_count=\(usageErrors)"
    }
}

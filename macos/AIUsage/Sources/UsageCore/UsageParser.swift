import Foundation

public enum UsageParser {
    public static func credentials(_ data: Data) throws -> [Credential] {
        let payload = try JSONValue.parse(data)
        guard let files = payload["files"].array else { throw UsageFailure.invalidResponse }
        var seen = Set<String>()
        return files.enumerated().compactMap { index, file in
            let kind = file["provider"].string ?? file["type"].string ?? ""
            guard let provider = Provider(rawValue: kind.lowercased()) else { return nil }
            let authIndex = file["auth_index"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
            let validIndex = authIndex.flatMap { $0.isEmpty ? nil : $0 }
            let identity = validIndex ?? file["id"].string ?? file["name"].string ?? "missing-\(index)"
            let id = "\(provider.rawValue):\(identity)"
            guard seen.insert(id).inserted else { return nil }
            let label = ["label", "email", "name"].compactMap { file[$0].string }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let status = file["status"].string?.lowercased() ?? ""
            // Only explicit auth signals imply re-login. A quota error is not an auth error.
            let message = file["status_message"].string?.lowercased() ?? ""
            let authSignals = ["invalid_grant", "invalid_token", "unauthorized", "authentication_error",
                               "authentication failed", "login required", "re-login", "token has expired",
                               "refresh token expired", "refresh_token_reused", "refresh_token_invalidated"]
            let login = authSignals.contains { message.contains($0) || status.contains($0) }
            // The inventory exposes parsed ID claims, never the OAuth token itself.
            let accountID = file["chatgpt_account_id"].string ?? file["id_token"]["chatgpt_account_id"].string
            let validAccountID = accountID.flatMap { value -> String? in
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && value.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
                } ? value : nil
            }
            return Credential(id: id, authIndex: validIndex, provider: provider,
                              label: safeLabel(label, fallback: "\(provider.title) account \(index + 1)"),
                              disabled: file["disabled"].bool == true || status == "disabled",
                              unavailable: file["unavailable"].bool == true || status == "error",
                              loginNeeded: login, chatGPTAccountID: provider == .codex ? validAccountID : nil)
        }
    }

    public static func reading(provider: Provider, body: Data, now: Date) throws -> UsageReading {
        let payload = try JSONValue.parse(body)
        guard payload.object != nil else { throw UsageFailure.invalidResponse }
        switch provider {
        case .claude: return try claude(payload, now: now)
        case .codex: return try codex(payload, now: now)
        }
    }

    public static func percent(_ value: JSONValue) -> Double? {
        guard let number = value.number, (0...100).contains(number) else { return nil }
        return number
    }

    public static func count(_ value: JSONValue) -> Int? {
        guard let number = value.number, number >= 0, number <= 1_000_000,
              number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }

    public static func isoDate(_ value: JSONValue) -> Date? {
        guard let text = value.string, text.contains("T") else { return nil }
        // Providers can send nanoseconds; normalize for Foundation on all supported OS versions.
        let normalized = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    private static func claude(_ payload: JSONValue, now: Date) throws -> UsageReading {
        let fields: [(String, String, WindowPeriod)] = [
            ("five_hour", "5-hour", .fiveHour), ("seven_day", "Weekly", .weekly),
            ("seven_day_opus", "Opus · Weekly", .weekly),
            ("seven_day_sonnet", "Sonnet · Weekly", .weekly),
            ("seven_day_oauth_apps", "OAuth apps · Weekly", .weekly),
            ("seven_day_cowork", "Cowork · Weekly", .weekly),
            ("iguana_necktie", "Fable · Weekly", .weekly)
        ]
        guard fields.contains(where: { payload.object?[$0.0] != nil }) || payload["limits"].array != nil || payload["cedar_ember"].object != nil else {
            throw UsageFailure.invalidResponse
        }
        let scoped = (payload["limits"].array ?? []).enumerated().filter {
            $0.element["kind"].string == "weekly_scoped" && $0.element["is_active"].bool == true
        }
        let hasScopedFable = scoped.contains {
            let model = $0.element["scope"]["model"]
            return (model["id"].string ?? "").lowercased().contains("fable")
                || (model["display_name"].string ?? "").lowercased().contains("fable")
        }
        var windows: [UsageWindow] = fields.compactMap { key, label, period in
            if key == "iguana_necktie" && hasScopedFable { return nil }
            // Keep the two headline slots even when absent. Optional absent model limits stay hidden.
            if key != "five_hour" && key != "seven_day" && payload[key].isNull { return nil }
            let value = payload[key]
            return UsageWindow(id: key, label: label, period: period,
                               usedPercent: percent(value["utilization"]), resetAt: isoDate(value["resets_at"]),
                               isOverall: key == "five_hour" || key == "seven_day")
        }
        for (index, item) in scoped {
            let model = item["scope"]["model"]
            let label = safeLabel(model["display_name"].string ?? model["id"].string, fallback: "Model")
            windows.append(UsageWindow(id: "scoped-\(index)", label: "\(label) · Weekly", period: .weekly,
                                       usedPercent: percent(item["percent"]), resetAt: isoDate(item["resets_at"]),
                                       isOverall: false))
        }
        return UsageReading(windows: windows, fetchedAt: now, resets: claudeGrants(payload["cedar_ember"], now: now))
    }

    private static func codex(_ payload: JSONValue, now: Date) throws -> UsageReading {
        guard payload["rate_limit"].object != nil || payload["code_review_rate_limit"].object != nil
                || payload["additional_rate_limits"].array != nil || payload["rate_limit_reset_credits"].object != nil else { throw UsageFailure.invalidResponse }
        var windows: [UsageWindow] = []
        var limitedScopes: [String] = []
        func addRate(_ rate: JSONValue, prefix: String, label: String?, overall: Bool) {
            guard rate.object != nil else { return }
            if !overall && (rate["allowed"].bool == false || rate["limit_reached"].bool == true) {
                limitedScopes.append(label ?? "Model")
            }
            for key in ["primary_window", "secondary_window"] {
                let window = rate[key]
                guard window.object != nil else { continue }
                let period = WindowPeriod.classify(seconds: window["limit_window_seconds"].number)
                let title = label.map { "\($0) · \(period.title)" } ?? period.title
                windows.append(UsageWindow(id: "\(prefix)-\(key)", label: title, period: period,
                                           usedPercent: percent(window["used_percent"]),
                                           resetAt: codexReset(window, now: now), isOverall: overall))
            }
        }
        let main = payload["rate_limit"]
        addRate(main, prefix: "main", label: nil, overall: true)
        addRate(payload["code_review_rate_limit"], prefix: "review", label: "Code review", overall: false)
        for (index, rate) in (payload["additional_rate_limits"].array ?? []).enumerated() {
            let label = safeLabel(rate["limit_name"].string, fallback: "Model \(index + 1)")
            addRate(rate["rate_limit"], prefix: "additional-\(index)", label: label, overall: false)
        }
        // Never infer a 5h or weekly slot from primary/secondary ordering, including monthly plans.
        for period in [WindowPeriod.fiveHour, .weekly] where !windows.contains(where: { $0.isOverall && $0.period == period }) {
            windows.append(UsageWindow(id: "missing-\(period.title)", label: period.title, period: period,
                                       usedPercent: nil, resetAt: nil, isOverall: true))
        }
        windows.sort { rank($0) < rank($1) }
        let credits = payload["rate_limit_reset_credits"]
        let available = count(credits["available_count"])
        var applicable = count(credits["applicable_available_count"])
        if let a = available, let b = applicable, b > a { applicable = nil }
        let resets = available == nil && applicable == nil ? nil : ResetAvailability(available: available, usableNow: applicable)
        return UsageReading(windows: windows, fetchedAt: now,
                            overallLimitReached: main["allowed"].bool == false || main["limit_reached"].bool == true,
                            limitedScopes: limitedScopes, resets: resets)
    }

    private static func rank(_ window: UsageWindow) -> Int {
        let scope = window.isOverall ? 0 : 10
        switch window.period {
        case .fiveHour: return scope
        case .weekly: return scope + 1
        case .monthly: return scope + 2
        default: return scope + 3
        }
    }

    private static func codexReset(_ value: JSONValue, now: Date) -> Date? {
        if !value["reset_at"].isNull {
            // Contract is epoch SECONDS. Invalid values stay unknown, with no unit guessing.
            guard let seconds = value["reset_at"].number, seconds > 0, seconds < 32_503_680_000 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let seconds = value["reset_after_seconds"].number, seconds >= 0, seconds <= 366 * 86400 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    private static func claudeGrants(_ block: JSONValue, now: Date) -> ResetAvailability? {
        guard let eligible = block["eligible"].bool, let grants = block["grants"].array else { return nil }
        guard block["at_limit"].isNull || block["at_limit"].bool != nil else { return nil }
        let atLimit = block["at_limit"].bool == true
        var available = 0, usable = 0
        var seen = Set<String>()
        var boundaries: [Date] = []
        let cooldown = isoDate(block["cooldown_until"])
        if !block["cooldown_until"].isNull && cooldown == nil { return nil }
        if let cooldown, cooldown > now { boundaries.append(cooldown) }
        for grant in grants {
            guard let id = grant["id"].string, !id.isEmpty, seen.insert(id).inserted,
                  let total = count(grant["resets_total"]), let left = count(grant["resets_left"]), left <= total else { return nil }
            for key in ["paused", "usable_now", "use_requires_limit"] {
                if !grant[key].isNull && grant[key].bool == nil { return nil }
            }
            let start = isoDate(grant["starts_at"]), end = isoDate(grant["ends_at"])
            if !grant["starts_at"].isNull && start == nil { return nil }
            if !grant["ends_at"].isNull && end == nil { return nil }
            if let start, let end, start >= end { return nil }
            if !grant["clears"].isNull && grant["clears"].array == nil { return nil }
            if let start, start > now { boundaries.append(start) }
            if let end, end > now { boundaries.append(end) }
            let active = (start == nil || start! <= now) && (end == nil || end! > now)
            guard eligible && active && grant["paused"].bool != true else { continue }
            available += left
            let requiresLimit = grant["use_requires_limit"].bool != false
            if grant["usable_now"].bool == true && (!requiresLimit || atLimit) && (cooldown == nil || cooldown! <= now) {
                usable += left
            }
            guard available <= 1_000_000, usable <= 1_000_000 else { return nil }
        }
        return ResetAvailability(available: available, usableNow: usable, validUntil: boundaries.min())
    }
}

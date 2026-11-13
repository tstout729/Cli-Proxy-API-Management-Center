import Foundation

public enum DemoData {
    // Entirely synthetic. Uses the production inventory and quota parsers and the same AccountState/UI.
    public static func snapshot(now: Date = Date()) -> RefreshSnapshot {
        let reset = now.addingTimeInterval(7200)
        let iso = ISO8601DateFormatter().string(from: reset)
        var files: [JSONValue] = []
        for index in 1...8 {
            files.append(.object([
                "provider": .string("claude"), "auth_index": .string("demo-claude-\(index)"),
                "label": .string(index <= 4 ? "Personal \(index)" : "Team \(index - 4)")
            ]))
        }
        for index in 1...5 {
            files.append(.object([
                "provider": .string("codex"), "auth_index": .string("demo-codex-\(index)"),
                "label": .string("Coding \(index)")
            ]))
        }
        do {
            let data = try JSONEncoder().encode(JSONValue.object(["files": .array(files)]))
            let inventory = try UsageParser.credentials(data)
            let accounts = try inventory.enumerated().map { index, credential -> AccountState in
                if (4...6).contains(index) || index == 9 {
                    return AccountState(credential: credential, failure: .providerUnauthorized)
                }
                let body: String
                if credential.provider == .claude {
                    let used = index < 4 ? 100 : 48
                    body = """
                    {"five_hour":{"utilization":24,"resets_at":"\(iso)"},
                    "seven_day":{"utilization":\(used),"resets_at":"\(iso)"},
                    "seven_day_opus":{"utilization":72,"resets_at":"\(iso)"},
                    "cedar_ember":{"eligible":true,"at_limit":true,"grants":[
                      {"id":"synthetic-grant","resets_total":2,"resets_left":1,"usable_now":true}]}}
                    """
                } else if index == 10 {
                    body = """
                    {"rate_limit":{"primary_window":{"used_percent":null,"limit_window_seconds":18000},"secondary_window":null}}
                    """
                } else {
                    let secondary = index == 12 ? 2592000 : 604800
                    body = """
                    {"rate_limit":{"allowed":true,"limit_reached":false,
                     "primary_window":{"used_percent":32,"limit_window_seconds":18000,"reset_at":\(reset.timeIntervalSince1970)},
                     "secondary_window":{"used_percent":81,"limit_window_seconds":\(secondary),"reset_at":\(reset.timeIntervalSince1970)}},
                     "rate_limit_reset_credits":{"available_count":2,"applicable_available_count":1}}
                    """
                }
                let reading = try UsageParser.reading(provider: credential.provider, body: Data(body.utf8),
                                                      now: index == 11 ? now.addingTimeInterval(-900) : now)
                return AccountState(credential: credential, reading: reading, failure: index == 11 ? .connection : nil)
            }
            return RefreshSnapshot(accounts: accounts, attemptedAt: now, inventoryUpdatedAt: now,
                                   usageSuccesses: 9, usageErrors: 4)
        } catch {
            // Synthetic construction failure is visible, never a reason to attempt a live connection.
            return RefreshSnapshot(connectionFailure: .invalidResponse)
        }
    }
}

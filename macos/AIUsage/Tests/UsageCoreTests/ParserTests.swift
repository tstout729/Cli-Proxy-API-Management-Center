import Foundation
import XCTest
@testable import UsageCore

final class ParserTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let futureISO = "2030-01-02T03:04:05.123456789Z"
    func parse(_ provider: Provider, _ body: String) throws -> UsageReading {
        try UsageParser.reading(provider: provider, body: Data(body.utf8), now: now)
    }
    func credential(_ provider: Provider = .claude, unavailable: Bool = false, login: Bool = false) -> Credential {
        Credential(id: "synthetic", authIndex: "synthetic", provider: provider, label: "Synthetic account",
                   unavailable: unavailable, loginNeeded: login)
    }

    func testNullAndMissingNeverBecomeZero() throws {
        let reading = try parse(.claude, #"{"five_hour":null,"seven_day":{"utilization":null,"resets_at":null},"seven_day_opus":null}"#)
        XCTAssertEqual(reading.windows.count, 2)
        XCTAssertTrue(reading.windows.allSatisfy { $0.usedPercent == nil && $0.resetAt == nil })
        XCTAssertEqual(AccountState(credential: credential(), reading: reading).status(at: now), .unknown)
        XCTAssertFalse(reading.hasUsage)
        let zero = try parse(.claude, #"{"five_hour":{"utilization":0},"seven_day":null}"#)
        XCTAssertEqual(zero.windows.first?.usedPercent, 0)
    }

    func testMalformedObjectsAndOutOfRangeValuesStayUnknown() throws {
        for text in ["null", "[]", "garbage", "{}", #"{"error":{"message":"synthetic"}}"#] {
            XCTAssertThrowsError(try parse(.claude, text))
        }
        let result = try parse(.claude, #"{"five_hour":{"utilization":101,"resets_at":"bad"},"seven_day":{"utilization":-1},"seven_day_opus":{"utilization":"50"}}"#)
        XCTAssertTrue(result.windows.allSatisfy { $0.usedPercent == nil })
        XCTAssertNil(result.windows.first?.resetAt)
        XCTAssertNil(UsageParser.percent(.bool(true)))
        XCTAssertNil(UsageParser.percent(.number(.infinity)))
        XCTAssertNil(UsageParser.percent(.number(.nan)))
    }

    func testFractionalISOAndExplicitOffset() throws {
        let fractional = try XCTUnwrap(UsageParser.isoDate(.string(futureISO)))
        let basic = try XCTUnwrap(UsageParser.isoDate(.string("2030-01-02T03:04:05Z")))
        XCTAssertEqual(fractional.timeIntervalSince(basic), 0.123, accuracy: 0.001)
        let offset = try XCTUnwrap(UsageParser.isoDate(.string("2030-01-01T19:04:05-08:00")))
        XCTAssertEqual(offset, basic)
        XCTAssertNil(UsageParser.isoDate(.string("2030-01-02")))
    }

    func testPacificDatesAndDaylightSavingTime() throws {
        let winter = try XCTUnwrap(UsageParser.isoDate(.string("2030-01-02T03:04:05Z")))
        let summer = try XCTUnwrap(UsageParser.isoDate(.string("2030-07-02T03:04:05Z")))
        XCTAssertTrue(DisplayTime.absolute(winter).contains("Jan 1, 2030"))
        XCTAssertTrue(DisplayTime.absolute(winter).contains("PST"))
        XCTAssertTrue(DisplayTime.absolute(summer).contains("Jul 1, 2030"))
        XCTAssertTrue(DisplayTime.absolute(summer).contains("PDT"))
        XCTAssertEqual(DisplayTime.countdown(to: now.addingTimeInterval(3660), now: now), "in 1h 1m")
    }

    func testPastResetAndAgedReadingsAreStaleWithoutZeroing() throws {
        let reading = try parse(.claude, #"{"five_hour":{"utilization":100,"resets_at":"2020-01-01T00:00:00Z"},"seven_day":null}"#)
        let state = AccountState(credential: credential(), reading: reading)
        XCTAssertEqual(state.status(at: now), .stale)
        XCTAssertEqual(state.reading?.windows.first?.usedPercent, 100)
        XCTAssertEqual(DisplayTime.countdown(to: now, now: now), "Reset time passed · refresh needed")
        let aged = UsageReading(windows: [], fetchedAt: now.addingTimeInterval(-601))
        XCTAssertTrue(AccountState(credential: credential(), reading: aged).isStale(at: now))
    }

    func testCodexSwappedDurationsAndMonthlyAreNeverWeeklyFallback() throws {
        let swapped = try parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":120},"secondary_window":{"used_percent":13,"limit_window_seconds":18000,"reset_after_seconds":60}}}"#)
        XCTAssertEqual(swapped.windows.filter { $0.period == .fiveHour }.first?.usedPercent, 13)
        XCTAssertEqual(swapped.windows.filter { $0.period == .weekly }.first?.usedPercent, 82)
        let monthly = try parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":82,"limit_window_seconds":604800},"secondary_window":{"used_percent":13,"limit_window_seconds":2592000}}}"#)
        XCTAssertEqual(monthly.windows.filter { $0.period == .weekly }.count, 1)
        XCTAssertEqual(monthly.windows.filter { $0.period == .monthly }.first?.usedPercent, 13)
        XCTAssertNil(monthly.windows.first { $0.period == .fiveHour }?.usedPercent)
        let unknown = try parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":12},"secondary_window":{"used_percent":34,"limit_window_seconds":2592000}}}"#)
        XCTAssertNil(unknown.windows.first { $0.period == .weekly }?.usedPercent)
        XCTAssertNil(unknown.windows.first { $0.period == .fiveHour }?.usedPercent)
        XCTAssertEqual(unknown.windows.first { $0.period == .unknown }?.usedPercent, 12)
    }

    func testCodexInvalidResetDoesNotFallBackOrClamp() throws {
        let value = try parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":200,"limit_window_seconds":18000,"reset_at":-1,"reset_after_seconds":60},"secondary_window":{"used_percent":50,"limit_window_seconds":604800,"reset_at":1800000000000}}}"#)
        XCTAssertNil(value.windows.first { $0.period == .fiveHour }?.usedPercent)
        XCTAssertTrue(value.windows.allSatisfy { $0.resetAt == nil })
        let relative = try parse(.codex, #"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":120}}}"#)
        XCTAssertEqual(relative.windows.first { $0.period == .fiveHour }?.resetAt, now.addingTimeInterval(120))
    }

    func testModelScopedLimitsAndFablePrecedence() throws {
        let value = try parse(.claude, """
        {"five_hour":null,"seven_day":null,"iguana_necktie":{"utilization":10},
         "limits":[
           {"kind":"weekly_scoped","is_active":true,"percent":100,"resets_at":"\(futureISO)","scope":{"model":{"id":"fable-5","display_name":"Fable 5"}}},
           {"kind":"weekly_scoped","is_active":false,"percent":88,"scope":{"model":{"display_name":"Inactive"}}}]}
        """)
        XCTAssertFalse(value.windows.contains { $0.id == "iguana_necktie" })
        XCTAssertEqual(value.windows.filter { !$0.isOverall }.count, 1)
        XCTAssertEqual(value.windows.last?.label, "Fable 5 · Weekly")
        XCTAssertEqual(AccountState(credential: credential(), reading: value).status(at: now), .modelLimited)
        let codex = try parse(.codex, #"{"rate_limit":{"allowed":true},"additional_rate_limits":[{"limit_name":"Synthetic model","rate_limit":{"limit_reached":true,"primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_after_seconds":600}}}],"code_review_rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":604800}}}"#)
        XCTAssertFalse(codex.overallLimitReached)
        XCTAssertEqual(codex.limitedScopes, ["Synthetic model"])
        XCTAssertTrue(codex.windows.contains { $0.label == "Code review · Weekly" })
    }

    func testAuthExhaustionUnavailableAndUnknownAreDistinct() throws {
        let exhausted = try parse(.claude, """
        {"five_hour":{"utilization":12,"resets_at":"\(futureISO)"},"seven_day":{"utilization":100,"resets_at":"\(futureISO)"}}
        """)
        XCTAssertEqual(AccountState(credential: credential(), reading: exhausted).status(at: now), .exhausted)
        XCTAssertEqual(AccountState(credential: credential(login: true), reading: exhausted).status(at: now), .loginNeeded)
        XCTAssertEqual(AccountState(credential: credential(), reading: exhausted, failure: .providerUnauthorized).status(at: now), .loginNeeded)
        XCTAssertEqual(AccountState(credential: credential(), reading: exhausted, failure: .managementUnauthorized).status(at: now), .connectionError)
        XCTAssertEqual(AccountState(credential: credential(), reading: exhausted, failure: .invalidResponse).status(at: now), .stale)
        XCTAssertEqual(AccountState(credential: credential(unavailable: true)).status(at: now), .unavailable)
        XCTAssertEqual(AccountState(credential: credential()).status(at: now), .unknown)
        let flags = try parse(.codex, #"{"rate_limit":{"allowed":false,"primary_window":{"used_percent":null,"limit_window_seconds":18000}}}"#)
        XCTAssertTrue(flags.overallLimitReached)
        XCTAssertNil(flags.windows.first?.usedPercent)
        XCTAssertEqual(AccountState(credential: credential(.codex), reading: flags).status(at: now), .exhausted)
        let reported = try parse(.claude, """
        {"five_hour":{"utilization":12,"resets_at":"\(futureISO)"},"seven_day":{"utilization":22,"resets_at":"\(futureISO)"}}
        """)
        XCTAssertEqual(AccountState(credential: credential(), reading: reported).status(at: now), .reported)
    }

    func testInventoryIgnoresOtherProvidersAndSeparatesAuthFromQuota() throws {
        let data = Data(#"{"files":[{"provider":"claude","auth_index":"one","label":"Synthetic 1","status":"error","status_message":"weekly quota exhausted","unavailable":true},{"type":"codex","auth_index":"two","status_message":"refresh_token_reused"},{"provider":"claude","name":"synthetic-disabled","disabled":true},{"provider":"gemini","auth_index":"ignored"}]}"#.utf8)
        let files = try UsageParser.credentials(data)
        XCTAssertEqual(files.count, 3)
        XCTAssertFalse(files[0].loginNeeded)
        XCTAssertTrue(files[0].unavailable)
        XCTAssertTrue(files[1].loginNeeded)
        XCTAssertTrue(files[2].disabled)
        XCTAssertNil(files[2].authIndex)
        XCTAssertThrowsError(try UsageParser.credentials(Data(#"{"files":null}"#.utf8)))
    }

    func testReadOnlyCreditCountsValidateIntegersAndRelationships() throws {
        let good = try parse(.codex, #"{"rate_limit":{},"rate_limit_reset_credits":{"available_count":3,"applicable_available_count":1}}"#)
        XCTAssertEqual(good.resets?.available, 3)
        XCTAssertEqual(good.resets?.usableNow, 1)
        let bad = try parse(.codex, #"{"rate_limit":{},"rate_limit_reset_credits":{"available_count":-1,"applicable_available_count":1.5}}"#)
        XCTAssertNil(bad.resets)
        let inconsistent = try parse(.codex, #"{"rate_limit":{},"rate_limit_reset_credits":{"available_count":1,"applicable_available_count":2}}"#)
        XCTAssertEqual(inconsistent.resets?.available, 1)
        XCTAssertNil(inconsistent.resets?.usableNow)
    }

    func testCodexUsageIsScopedToTheCredentialAccount() throws {
        let files = try UsageParser.credentials(Data(#"{"files":[{"provider":"codex","auth_index":"one","id_token":{"chatgpt_account_id":"synthetic-account"}},{"provider":"claude","auth_index":"two","chatgpt_account_id":"ignored"},{"provider":"codex","auth_index":"three","chatgpt_account_id":"invalid\r\nheader"}]}"#.utf8))
        XCTAssertEqual(files[0].chatGPTAccountID, "synthetic-account")
        XCTAssertNil(files[1].chatGPTAccountID)
        XCTAssertNil(files[2].chatGPTAccountID)
        let call = UsageCall(provider: .codex, authIndex: "one", chatGPTAccountID: files[0].chatGPTAccountID)
        XCTAssertEqual(call.header["Chatgpt-Account-Id"], "synthetic-account")
        XCTAssertNil(UsageCall(provider: .claude, authIndex: "two", chatGPTAccountID: "ignored").header["Chatgpt-Account-Id"])
    }

    func testGrantCountsAreConservativeAndMalformedBlocksHidden() throws {
        let body = """
        {"five_hour":null,"cedar_ember":{"eligible":true,"at_limit":true,"grants":[
          {"id":"synthetic-active","resets_total":3,"resets_left":2,"usable_now":true,"ends_at":"\(futureISO)"},
          {"id":"synthetic-paused","resets_total":5,"resets_left":5,"paused":true,"usable_now":true},
          {"id":"synthetic-expired","resets_total":4,"resets_left":4,"ends_at":"2020-01-01T00:00:00Z","usable_now":true},
          {"id":"synthetic-unknown-usability","resets_total":1,"resets_left":1}]}}
        """
        let value = try parse(.claude, body)
        XCTAssertEqual(value.resets?.available, 3)
        XCTAssertEqual(value.resets?.usableNow, 2)
        XCTAssertNotNil(value.resets?.validUntil)
        let invalid = body.replacingOccurrences(of: "\"resets_left\":2", with: "\"resets_left\":9")
        XCTAssertNil(try parse(.claude, invalid).resets)
        let ineligible = body.replacingOccurrences(of: "\"eligible\":true", with: "\"eligible\":false")
        XCTAssertEqual(try parse(.claude, ineligible).resets?.available, 0)
        let noLimit = body.replacingOccurrences(of: "\"at_limit\":true", with: "\"at_limit\":false")
        XCTAssertEqual(try parse(.claude, noLimit).resets?.usableNow, 0)
        let cooldown = body.replacingOccurrences(of: "\"at_limit\":true", with: "\"at_limit\":true,\"cooldown_until\":\"\(futureISO)\"")
        XCTAssertEqual(try parse(.claude, cooldown).resets?.usableNow, 0)
    }

    func testDemoIsSyntheticAndModelsExpectedRiskStates() {
        let snapshot = DemoData.snapshot(now: now)
        XCTAssertEqual(snapshot.accounts.filter { $0.credential.provider == .claude }.count, 8)
        XCTAssertEqual(snapshot.accounts.filter { $0.credential.provider == .codex }.count, 5)
        XCTAssertEqual(snapshot.accounts.filter { $0.status(at: now) == .loginNeeded }.count, 4)
        XCTAssertEqual(snapshot.accounts.filter { $0.status(at: now) == .exhausted }.count, 4)
        XCTAssertFalse(snapshot.checkSummary.contains("Personal"))
    }
}

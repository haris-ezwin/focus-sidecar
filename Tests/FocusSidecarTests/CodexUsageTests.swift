import Foundation

@main
struct CodexUsageTests {
    static func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(condition(), "Usage test failed", file: file, line: line)
    }

    static func main() throws {
        firstReadingDoesNotCountEarlierWeeklyUsage()
        resetRetainsTodaysUsage()
        correctionDoesNotSubtractUsage()
        midnightUsesMalaysiaTime()
        overnightGapDoesNotAttributeUnknownUsageToToday()
        accountChangeStartsFresh()
        try legacyCountStartsFresh()
        changedResetDoesNotCountWeeklyTotal()
        try historySurvivesRelaunch()
        try selectsWeeklyWindowAndMainCodexBucket()
        missingWeeklyQuotaIsUnavailable()
        try liveUsageConnectionWhenRequested()
        print("Codex usage checks passed (11 accounting/parser checks; optional live connection).")
    }
    private static func sample(_ used: Double, _ date: String = "2026-09-10T04:00:00Z", reset: Double = 2_000_000_000, account: String = "a") -> CodexUsageSample {
        CodexUsageSample(accountKey: account, date: ISO8601DateFormatter().date(from: date)!, usedPercent: used, resetsAt: reset)
    }

    static func firstReadingDoesNotCountEarlierWeeklyUsage() {
        var history = CodexUsageHistory()
        history.record(sample(16))
        expect(history.days[0].usedPercent == 0)
        expect(history.days[0].isPartial)
        history.record(sample(24, "2026-09-10T05:00:00Z"))
        expect(history.days[0].usedPercent == 8)
    }

    static func resetRetainsTodaysUsage() {
        var history = CodexUsageHistory()
        history.record(sample(90))
        history.record(sample(95, "2026-09-10T05:00:00Z"))
        history.record(sample(3, "2026-09-10T06:00:00Z", reset: 2_000_600_000))
        expect(history.days[0].usedPercent == 5)
        expect(history.days[0].isPartial)
    }

    static func correctionDoesNotSubtractUsage() {
        var history = CodexUsageHistory()
        history.record(sample(16))
        history.record(sample(24))
        history.record(sample(20))
        history.record(sample(22))
        expect(history.days[0].usedPercent == 8)
    }

    static func midnightUsesMalaysiaTime() {
        var history = CodexUsageHistory()
        history.record(sample(16, "2026-09-10T15:59:30Z"))
        history.record(sample(17, "2026-09-10T16:00:30Z"))
        expect(history.days[1].id == "2026-09-11")
        expect(history.days[1].usedPercent == 0)
        expect(history.days[1].isPartial)
    }

    static func overnightGapDoesNotAttributeUnknownUsageToToday() {
        var history = CodexUsageHistory()
        history.record(sample(16, "2026-09-10T12:00:00Z"))
        history.record(sample(26, "2026-09-11T02:00:00Z"))
        expect(history.days[1].usedPercent == 0)
        expect(history.days[1].isPartial)
    }

    static func accountChangeStartsFresh() {
        var history = CodexUsageHistory()
        history.record(sample(16))
        history.record(sample(26))
        history.record(sample(80, account: "b"))
        expect(history.days.count == 1)
        expect(history.days[0].usedPercent == 0)
    }

    static func legacyCountStartsFresh() throws {
        let data = Data(#"{"days":[{"id":"2026-09-10","usedPercent":46,"isPartial":true}]}"#.utf8)
        var history = try JSONDecoder().decode(CodexUsageHistory.self, from: data)
        let baseline = sample(22)
        history.record(baseline)
        expect(history.days[0].usedPercent == 0)
        expect(history.days[0].startedAt == baseline.date)
        expect(history.days[0].baselineUsedPercent == 22)
        history.record(sample(25))
        expect(history.days[0].usedPercent == 3)
    }

    static func changedResetDoesNotCountWeeklyTotal() {
        var history = CodexUsageHistory()
        history.record(sample(22))
        history.record(sample(22, reset: 2_000_000_001))
        expect(history.days[0].usedPercent == 0)
        history.record(sample(25, reset: 2_000_000_001))
        expect(history.days[0].usedPercent == 3)
    }

    static func historySurvivesRelaunch() throws {
        var history = CodexUsageHistory()
        history.record(sample(16))
        history.record(sample(24))
        var restored = try JSONDecoder().decode(CodexUsageHistory.self, from: JSONEncoder().encode(history))
        restored.record(sample(28))
        expect(restored.days[0].usedPercent == 12)
    }

    static func selectsWeeklyWindowAndMainCodexBucket() throws {
        let result: [String: Any] = ["rateLimitsByLimitId": [
            "codex": [
                "primary": ["usedPercent": 99, "windowDurationMins": 300, "resetsAt": 2_000_000_000],
                "secondary": ["usedPercent": 16, "windowDurationMins": 10080, "resetsAt": 2_000_000_000]
            ],
            "codex_bengalfox": ["primary": ["usedPercent": 90, "windowDurationMins": 10080, "resetsAt": 2_000_000_000]]
        ]]
        let reading = try CodexUsageClient.sample(from: result, accountKey: "a", date: Date())
        expect(reading.usedPercent == 16)
    }

    static func missingWeeklyQuotaIsUnavailable() {
        do {
            _ = try CodexUsageClient.sample(from: [:], accountKey: "a", date: Date())
            preconditionFailure("Missing quota must fail")
        } catch {
            expect(error is CodexUsageError)
        }
    }

    static func liveUsageConnectionWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["FOCUS_CODEX_LIVE_TEST"] == "1" else { return }
        let sample = try CodexUsageClient.read()
        expect((0...100).contains(sample.usedPercent))
        expect(!sample.accountKey.isEmpty)
        print("Live Codex weekly usage: \(sample.usedPercent)%")
    }
}

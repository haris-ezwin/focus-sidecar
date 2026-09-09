import Foundation

struct CodexUsageSample: Codable, Sendable {
    let accountKey: String
    let date: Date
    let usedPercent: Double
    let resetsAt: TimeInterval
}

struct CodexUsageDay: Codable, Identifiable, Sendable {
    var id: String
    var usedPercent: Double = 0
    var isPartial = false
}

struct CodexUsageHistory: Codable, Sendable {
    static let dailyTarget = 100.0 / 7.0
    var lastSample: CodexUsageSample?
    var days: [CodexUsageDay] = []

    static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    mutating func record(_ sample: CodexUsageSample) {
        if let previous = lastSample, previous.accountKey != sample.accountKey {
            days = []
            lastSample = nil
        }
        let key = Self.dayKey(sample.date)
        if !days.contains(where: { $0.id == key }) {
            days.append(CodexUsageDay(id: key))
        }
        let index = days.firstIndex(where: { $0.id == key })!
        if let previous = lastSample, sample.date >= previous.date {
            let sameDay = Self.dayKey(previous.date) == key
            let nearMidnight = sample.date.timeIntervalSince(previous.date) <= 150
            if sameDay || nearMidnight {
                if previous.resetsAt != sample.resetsAt {
                    // Keep the amount already counted today; start counting the new quota window.
                    days[index].usedPercent += sample.usedPercent
                    days[index].isPartial = true // Usage just before the reset may be unobserved.
                } else if sample.usedPercent >= previous.usedPercent {
                    days[index].usedPercent += sample.usedPercent - previous.usedPercent
                } else {
                    // Corrections or unannounced resets must never subtract from today's usage.
                    days[index].isPartial = true
                }
            } else {
                // After an overnight gap, the delta cannot be attributed to a particular day.
                days[index].isPartial = true
            }
        } else {
            days[index].isPartial = true
        }
        lastSample = sample
        days = Array(days.sorted { $0.id < $1.id }.suffix(7))
    }

    func today(at date: Date = Date()) -> CodexUsageDay? {
        days.first { $0.id == Self.dayKey(date) }
    }
}

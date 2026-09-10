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
    var startedAt: Date?
    var baselineUsedPercent: Double?
}

struct CodexUsageHistory: Codable, Sendable {
    static let dailyTarget = 100.0 / 7.0
    var lastSample: CodexUsageSample?
    var highWaterUsedPercent: Double?
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
        if let previous = lastSample, sample.date < previous.date { return }
        if days[index].startedAt == nil || lastSample.map({ Self.dayKey($0.date) != key }) ?? true {
            // Old totals lack a trustworthy baseline. Migrate today's count on a fresh reading.
            days[index].usedPercent = 0
            days[index].startedAt = sample.date
            days[index].baselineUsedPercent = sample.usedPercent
            days[index].isPartial = true
            highWaterUsedPercent = sample.usedPercent
        } else if let previous = lastSample {
            let highWater = highWaterUsedPercent ?? previous.usedPercent
            if previous.resetsAt != sample.resetsAt {
                // A changed reset time is not proof of consumption. Establish a new baseline.
                highWaterUsedPercent = sample.usedPercent
                days[index].isPartial = true
            } else {
                days[index].usedPercent += max(0, sample.usedPercent - highWater)
                highWaterUsedPercent = max(highWater, sample.usedPercent)
                if sample.usedPercent < previous.usedPercent { days[index].isPartial = true }
            }
        }
        lastSample = sample
        days = Array(days.sorted { $0.id < $1.id }.suffix(7))
    }

    func today(at date: Date = Date()) -> CodexUsageDay? {
        days.first { $0.id == Self.dayKey(date) }
    }
}

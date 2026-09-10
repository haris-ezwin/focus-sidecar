import AppKit
import SwiftUI

struct CodexUsageBar: View {
    @ObservedObject var store: CodexUsageStore
    @State private var showsDetails = false
    @State private var thresholdDraft = ""
    @AppStorage("codex.dailyThreshold") private var savedThreshold = CodexUsageHistory.dailyTarget

    private var dailyThreshold: Double {
        savedThreshold.isFinite && (0.1...100).contains(savedThreshold) ? savedThreshold : CodexUsageHistory.dailyTarget
    }

    private var proposedThreshold: Double? {
        guard let value = Double(thresholdDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (0.1...100).contains(value) else { return nil }
        return value
    }

    private static let codexIcon: NSImage? = Bundle.main.url(forResource: "CodexIcon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let today = store.history.today(at: context.date)
            let amount = today?.usedPercent ?? 0
            let fraction = amount / dailyThreshold
            let stale = store.errorMessage != nil || store.history.lastSample.map {
                context.date.timeIntervalSince($0.date) > 180
            } ?? true
            let weeklyFraction = store.history.lastSample.map { $0.usedPercent / 100 }

            Button {
                thresholdDraft = dailyThreshold.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...1)))
                showsDetails.toggle()
            } label: {
                HStack(spacing: 6) {
                    Group {
                        if let icon = Self.codexIcon {
                            Image(nsImage: icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: "terminal").resizable().scaledToFit()
                        }
                    }
                    .frame(width: 22, height: 22)
                    .frame(width: 44, height: 84)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        countdownRow("Daily", fraction: today == nil ? nil : fraction, stale: stale, reset: nextMidnight(after: context.date), now: context.date)
                        countdownRow("Weekly", fraction: weeklyFraction, stale: stale, reset: store.history.lastSample.map { Date(timeIntervalSince1970: $0.resetsAt) }, now: context.date)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 84)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Codex daily and weekly usage")
            .accessibilityValue("Daily: \(today == nil ? "unavailable" : "\(Int(fraction * 100)) percent of target"). Weekly: \(weeklyFraction.map { "\(Int($0 * 100)) percent used" } ?? "unavailable").\(stale ? " Last known reading." : "")")
            .help("Weekly shows allowance used. Daily 100% = \(dailyThreshold.formatted(.number.precision(.fractionLength(0...1))))% of your weekly allowance. Click to set your daily threshold.\(stale ? " Waiting for a fresh reading." : "")")
        }
        .padding(.horizontal, 14)
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Codex usage").font(.headline)
                    Spacer()
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                    .help("Refresh usage")
                }
                if let day = store.history.today(), let startedAt = day.startedAt {
                    Text("Used since \(startedAt.formatted(.dateTime.hour().minute().timeZone(.specificName(.short)))): \(day.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% of weekly allowance")
                    if let baseline = day.baselineUsedPercent {
                        Text("Starting weekly usage: \(baseline.formatted())%")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Daily threshold")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("14.3", text: $thresholdDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 65)
                        .accessibilityLabel("Daily threshold")
                        .onSubmit { saveThreshold() }
                    Text("% of weekly allowance")
                    Spacer(minLength: 0)
                    Button("Save", action: saveThreshold)
                        .disabled(proposedThreshold == nil)
                }
                Text(proposedThreshold == nil ? "Enter a threshold from 0.1 to 100%." : "Your chosen daily threshold fills the bar to 100%.")
                    .font(.caption).foregroundStyle(.secondary)
                if let sample = store.history.lastSample {
                    Text("Weekly used: \(sample.usedPercent.formatted())%")
                    Text("Resets \(Date(timeIntervalSince1970: sample.resetsAt).formatted(date: .abbreviated, time: .shortened))")
                    Text("Updated \(sample.date.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.orange)
                }
                Divider()
                ForEach(store.history.days.reversed()) { day in
                    HStack {
                        Text(day.id)
                        Spacer()
                        Text("\(day.usedPercent.formatted(.number.precision(.fractionLength(0...1))))%\(day.isPartial ? "*" : "")")
                            .monospacedDigit()
                    }
                }
                Text("Approximate readings, refreshed every minute while Sidecar is running. A new baseline starts at the first reading after midnight Malaysia time. * Partial day: only increases observed since the baseline are counted. Reset changes start a new baseline; usage across those changes may be missed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(16)
            .frame(width: 300)
        }
        .task {
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await store.refresh() }
        }
    }

    private func usageRow(_ title: String, fraction: Double?, stale: Bool) -> some View {
        let value = fraction ?? 0
        let color: Color = stale || fraction == nil ? .secondary : value >= 1 ? .red : value >= 0.8 ? .orange : .green
        return HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: 45, alignment: .leading)
            GeometryReader { geometry in
                if title == "Weekly" {
                    let segmentWidth = max(0, (geometry.size.width - 18) / 7)
                    HStack(spacing: 3) {
                        ForEach(0..<7) { index in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.12))
                                Capsule().fill(color)
                                    .frame(width: segmentWidth * min(max(value * 7 - Double(index), 0), 1))
                            }
                            .frame(width: segmentWidth)
                        }
                    }
                } else {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 5)
            Text(fraction == nil ? "—" : "\((value * 100).formatted(.number.precision(.fractionLength(0))))%")
                .foregroundStyle(color)
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 32, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
    }

    private func countdownRow(_ title: String, fraction: Double?, stale: Bool, reset: Date?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            usageRow(title, fraction: fraction, stale: stale)
            Text(reset.map { resetCountdown(until: $0, now: now) } ?? "Reset unavailable")
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func nextMidnight(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    private func resetCountdown(until reset: Date, now: Date) -> String {
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0 else { return "Reset pending" }
        let hours = Int(remaining / 3600)
        let days = hours / 24
        let dayText = "\(days) \(days == 1 ? "day" : "days")"
        let hourCount = hours % 24
        let hourText = "\(hourCount) \(hourCount == 1 ? "hour" : "hours")"
        if days > 0 { return "in \(dayText) \(hourText)" }
        if hours > 0 { return "in \(hourText)" }
        return "in less than 1 hour"
    }

    private func saveThreshold() {
        guard let value = proposedThreshold else { return }
        savedThreshold = value
        showsDetails = false
    }
}

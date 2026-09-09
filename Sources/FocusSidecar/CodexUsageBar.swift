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
            let color: Color = stale ? .secondary : fraction >= 1 ? .red : fraction >= 0.8 ? .orange : .green

            Button {
                thresholdDraft = dailyThreshold.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...1)))
                showsDetails.toggle()
            } label: {
                HStack(spacing: 9) {
                    Group {
                        if let icon = Self.codexIcon {
                            Image(nsImage: icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: "terminal").resizable().scaledToFit()
                        }
                    }
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                    GeometryReader { geometry in
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(color)
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                    .frame(height: 5)
                    Text(today == nil ? "—" : "\((fraction * 100).formatted(.number.precision(.fractionLength(0))))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .fixedSize()
                        .frame(minWidth: 32, alignment: .trailing)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Codex daily usage")
            .accessibilityValue(today == nil ? "Unavailable" : "\(Int(fraction * 100)) percent of daily target\(stale ? ", last known reading" : "")")
            .help("100% = \(dailyThreshold.formatted(.number.precision(.fractionLength(0...1))))% of your weekly allowance. Click to set your daily threshold.\(stale ? " Waiting for a fresh reading." : "")")
        }
        .padding(.horizontal, 14)
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Codex daily allowance").font(.headline)
                    Spacer()
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                    .help("Refresh usage")
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
                Text("Approximate readings, refreshed every minute while Sidecar is running. Days start at midnight Malaysia time. * Partial day: only observed usage is counted; gaps across midnight or resets may miss usage.")
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

    private func saveThreshold() {
        guard let value = proposedThreshold else { return }
        savedThreshold = value
        showsDetails = false
    }
}

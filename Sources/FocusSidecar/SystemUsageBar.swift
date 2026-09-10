import Darwin
import Foundation
import SwiftUI

@MainActor
final class SystemUsageStore: ObservableObject {
    @Published var cpu: Double?
    @Published var memory: Double?
    @Published var availableStorage: Int64?
    @Published var totalStorage: Int64?
    @Published var freeStorage: Int64?
    private var previousTicks: [UInt32]?

    func refresh() {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpuInfo = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let ticks = [cpuInfo.cpu_ticks.0, cpuInfo.cpu_ticks.1, cpuInfo.cpu_ticks.2, cpuInfo.cpu_ticks.3]
            if let previousTicks {
                let deltas = zip(ticks, previousTicks).map { Double($0 &- $1) }
                let total = deltas.reduce(0, +)
                cpu = total > 0 ? (total - deltas[Int(CPU_STATE_IDLE)]) / total : 0
            }
            previousTicks = ticks
        } else {
            cpu = nil
            previousTicks = nil
        }

        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        if vmResult == KERN_SUCCESS && pageResult == KERN_SUCCESS {
            // Exclude reclaimable file cache; include compressed memory's physical footprint.
            let appPages = max(0, Double(vm.internal_page_count) - Double(vm.purgeable_count))
            let usedPages = appPages + Double(vm.wire_count) + Double(vm.compressor_page_count)
            memory = min(1, max(0, usedPages * Double(pageSize) / Double(ProcessInfo.processInfo.physicalMemory)))
        } else {
            memory = nil
        }

        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        availableStorage = values?.volumeAvailableCapacityForImportantUsage
        totalStorage = values?.volumeTotalCapacity.map { Int64($0) }
        freeStorage = values?.volumeAvailableCapacity.map { Int64($0) }
    }
}

struct SystemUsageBar: View {
    @StateObject private var store = SystemUsageStore()
    @State private var showsStorage = false

    var body: some View {
        HStack(spacing: 6) {
            metric("CPU", value: percent(store.cpu))
                .help("CPU used across all cores; sampled every 3 seconds.")
            metric("RAM", value: percent(store.memory))
                .help("Approximate physical memory used, including compressed memory and excluding reclaimable file cache.")
            Button { showsStorage.toggle() } label: {
                metric("Storage", value: bytes(store.availableStorage))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help("Available storage. Click to see used, free, and total space.")
            .popover(isPresented: $showsStorage, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Storage").font(.headline)
                    if let total = store.totalStorage, let free = store.freeStorage, total > 0 {
                        let used = max(0, total - free)
                        ProgressView(value: Double(used), total: Double(total))
                        LabeledContent("Used", value: bytes(used))
                        LabeledContent("Free", value: bytes(free))
                        LabeledContent("Total", value: bytes(total))
                        Divider()
                        LabeledContent("Available", value: bytes(store.availableStorage))
                        Text("Available space includes storage macOS can reclaim. Readings are for your home volume.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Storage details are unavailable.").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(16)
                .frame(width: 250)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .task {
            while !Task.isCancelled {
                store.refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal) } ?? "—"
    }

    private func percent(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).foregroundStyle(.primary).monospacedDigit()
                Text(title).font(.system(size: 8, weight: .medium))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

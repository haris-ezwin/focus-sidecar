import SwiftUI

struct TaskEditorContext: Identifiable {
    let id = UUID()
    let task: FocusTask?
}

struct TaskEditorSheet: View {
    @ObservedObject var store: TaskStore
    let task: FocusTask?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var startTime: String
    @State private var endTime: String
    @State private var isSaving = false
    @State private var error: String?

    init(store: TaskStore, task: FocusTask?) {
        self.store = store
        self.task = task
        _title = State(initialValue: task?.title ?? "")
        _hasDueDate = State(initialValue: task == nil || task?.dueDate != nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        _dueDate = State(initialValue: task?.dueDate.flatMap { formatter.date(from: $0) } ?? Date())
        _startTime = State(initialValue: task?.startTime ?? "")
        _endTime = State(initialValue: task?.endTime ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(task == nil ? "New task" : "Edit task").font(.headline)
            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)
            Toggle("Due date", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("Date", selection: $dueDate, displayedComponents: .date)
            }
            HStack {
                TextField("Start (HH:mm)", text: $startTime)
                TextField("End (HH:mm)", text: $endTime)
            }
            .textFieldStyle(.roundedBorder)
            Text("Times are optional. Use 24-hour time, for example 17:00.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 360)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        do {
            let start = try normalizedTime(startTime)
            let end = try normalizedTime(endTime)
            if end != nil && start == nil { throw FocusSidecarError.server("Enter a start time or clear the end time.") }
            isSaving = true
            error = nil
            Task {
                defer { isSaving = false }
                do {
                    try await store.saveTask(existing: task, title: title,
                        dueDate: hasDueDate ? SupabaseService.dateString(for: dueDate, calendar: .current) : nil,
                        startTime: start, endTime: end)
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func normalizedTime(_ value: String) throws -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute),
              parts.count == 2 || (Int(parts[2]).map { (0...59).contains($0) } ?? false) else {
            throw FocusSidecarError.server("Use a valid 24-hour time, such as 17:00.")
        }
        return String(format: "%02d:%02d:%02d", hour, minute, parts.count == 3 ? Int(parts[2])! : 0)
    }
}

struct ExistingTaskSheet: View {
    @ObservedObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [FocusTask] = []
    @State private var search = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?

    private var filteredTasks: [FocusTask] {
        tasks.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add existing task").font(.headline)
            Text("Choose an unfinished task to move its due date to today.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search tasks", text: $search).textFieldStyle(.roundedBorder)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTasks.isEmpty {
                Text(search.isEmpty ? "No other unfinished tasks." : "No matching tasks.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredTasks) { task in
                            Button {
                                isSaving = true
                                error = nil
                                Task {
                                    defer { isSaving = false }
                                    do { try await store.addToToday(task); dismiss() }
                                    catch { self.error = error.localizedDescription }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(task.title).foregroundStyle(.primary)
                                        Text(task.dueDate ?? "No due date")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle").foregroundStyle(.green)
                                }
                                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Retry loading") { Task { await load() } }
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 380, height: 420)
        .disabled(isSaving).interactiveDismissDisabled(isSaving)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { tasks = try await store.availableTasks() }
        catch { self.error = error.localizedDescription }
    }
}

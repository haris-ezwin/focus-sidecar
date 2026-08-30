import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [FocusTask] = []
    @Published private(set) var events: [CountdownEvent] = []
    @Published private(set) var signedInEmail: String?
    @Published private(set) var isLoading = false
    @Published private(set) var updatingTaskIDs: Set<UUID> = []
    @Published private(set) var deletingTaskIDs: Set<UUID> = []
    @Published var errorMessage: String?
    @Published var eventErrorMessage: String?

    private let service: SupabaseService
    private var eventDatabase: CountdownEventDatabase?
    private var refreshTask: Task<Void, Never>?

    init(service: SupabaseService) {
        self.service = service
        do {
            let database = try CountdownEventDatabase()
            eventDatabase = database
            events = try database.fetchEvents()
        } catch {
            eventErrorMessage = error.localizedDescription
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var isAuthenticated: Bool { signedInEmail != nil }
    var remainingCount: Int { tasks.filter { !$0.isDone }.count }

    func restoreAndLoad() async {
        do {
            signedInEmail = try await service.restoreSession()
            if isAuthenticated {
                await refresh()
                startAutoRefresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signIn(email: String, password: String) async {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your email and password."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            signedInEmail = try await service.signIn(email: email, password: password)
            await refresh()
            startAutoRefresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        do {
            try await service.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
        signedInEmail = nil
        tasks = []
        refreshTask?.cancel()
    }

    func refresh() async {
        guard isAuthenticated else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let date = Date()
            let fetchedTasks = try await service.tasks(for: date).filter { !$0.isDone }
            tasks = applyStoredOrder(to: fetchedTasks, for: date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveTask(_ draggedTaskID: UUID, over destinationTaskID: UUID) {
        guard draggedTaskID != destinationTaskID,
              let sourceIndex = tasks.firstIndex(where: { $0.id == draggedTaskID }),
              let destinationIndex = tasks.firstIndex(where: { $0.id == destinationTaskID }) else {
            return
        }

        tasks.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
        )
        saveTaskOrder(for: Date())
    }

    func toggle(_ task: FocusTask) async {
        guard !updatingTaskIDs.contains(task.id), !deletingTaskIDs.contains(task.id) else { return }
        updatingTaskIDs.insert(task.id)
        errorMessage = nil
        defer { updatingTaskIDs.remove(task.id) }

        let completed = !task.isDone
        replaceTask(task, status: completed ? "Done" : "Todo")

        do {
            try await service.setCompleted(completed, taskID: task.id)
            if completed {
                try? await Task.sleep(for: .milliseconds(420))
                tasks.removeAll { $0.id == task.id }
                saveTaskOrder(for: Date())
            }
        } catch {
            replaceTask(task, status: task.status)
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ task: FocusTask) async {
        guard !deletingTaskIDs.contains(task.id), !updatingTaskIDs.contains(task.id) else { return }
        deletingTaskIDs.insert(task.id)
        errorMessage = nil
        defer { deletingTaskIDs.remove(task.id) }

        do {
            try await service.deleteTask(taskID: task.id)
            tasks.removeAll { $0.id == task.id }
            saveTaskOrder(for: Date())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveEvent(existing: CountdownEvent?, name: String, eventAt: Date) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Enter an event name." }
        guard trimmedName.count <= 120 else { return "Keep the event name under 120 characters." }
        guard eventAt >= Date().addingTimeInterval(-60) else {
            return "Choose a future date and time."
        }
        guard let eventDatabase else {
            return eventErrorMessage ?? "The local events database is unavailable."
        }

        do {
            if let existing {
                let updated = CountdownEvent(id: existing.id, name: trimmedName, eventAt: eventAt)
                try eventDatabase.update(updated)
                if let index = events.firstIndex(where: { $0.id == existing.id }) {
                    events[index] = updated
                }
            } else {
                events.append(try eventDatabase.insert(name: trimmedName, eventAt: eventAt))
            }
            events.sort { $0.eventAt < $1.eventAt }
            eventErrorMessage = nil
            return nil
        } catch {
            eventErrorMessage = error.localizedDescription
            return error.localizedDescription
        }
    }

    func deleteEvent(_ event: CountdownEvent) {
        guard let eventDatabase else {
            eventErrorMessage = "The local events database is unavailable."
            return
        }

        do {
            try eventDatabase.delete(id: event.id)
            events.removeAll { $0.id == event.id }
            eventErrorMessage = nil
        } catch {
            eventErrorMessage = error.localizedDescription
        }
    }

    private func replaceTask(_ task: FocusTask, status: String) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = FocusTask(
            id: task.id,
            title: task.title,
            priority: task.priority,
            status: status,
            dueDate: task.dueDate,
            startTime: task.startTime,
            endTime: task.endTime
        )
    }

    private func applyStoredOrder(to fetchedTasks: [FocusTask], for date: Date) -> [FocusTask] {
        let storedIDs = UserDefaults.standard.stringArray(forKey: taskOrderKey(for: date)) ?? []
        guard !storedIDs.isEmpty else { return fetchedTasks }

        let storedPositions = Dictionary(
            uniqueKeysWithValues: storedIDs.enumerated().map { ($0.element, $0.offset) }
        )
        let serverPositions = Dictionary(
            uniqueKeysWithValues: fetchedTasks.enumerated().map { ($0.element.id, $0.offset) }
        )

        return fetchedTasks.sorted { lhs, rhs in
            let lhsPosition = storedPositions[lhs.id.uuidString]
            let rhsPosition = storedPositions[rhs.id.uuidString]

            switch (lhsPosition, rhsPosition) {
            case let (.some(lhs), .some(rhs)):
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return (serverPositions[lhs.id] ?? 0) < (serverPositions[rhs.id] ?? 0)
            }
        }
    }

    private func saveTaskOrder(for date: Date) {
        UserDefaults.standard.set(
            tasks.map { $0.id.uuidString },
            forKey: taskOrderKey(for: date)
        )
    }

    private func taskOrderKey(for date: Date) -> String {
        "taskOrder.\(SupabaseService.dateString(for: date, calendar: .current))"
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}

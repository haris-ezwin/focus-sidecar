import AppKit
import SwiftUI

struct TaskPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var follower: WindowFollower
    @ObservedObject var timerStore: FocusTimerStore
    @State private var eventEditor: EventEditorContext?
    @State private var eventToDelete: CountdownEvent?
    @State private var dividerDragStartHeight: CGFloat?
    @State private var liveEventsListHeight: CGFloat?
    @State private var isDividerHovered = false
    @State private var revealedTaskID: UUID?
    @AppStorage("countdown.eventsListHeight") private var preferredEventsListHeight = 188.0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 0) {
                GeometryReader { geometry in
                    VStack(spacing: 10) {
                        eventsSection(maxListHeight: maxEventsListHeight(in: geometry.size.height))

                        draggableDivider(maxListHeight: maxEventsListHeight(in: geometry.size.height))

                        Group {
                            if store.isAuthenticated {
                                tasksView
                            } else {
                                SignInView(store: store, follower: follower)
                            }
                        }
                    }
                    .padding(14)
                }
                .coordinateSpace(name: "focusPanelContent")

                FocusTimerPanel(store: timerStore)
            }
        }
        .frame(minWidth: 284, minHeight: 620)
        .preferredColorScheme(.dark)
        .sheet(item: $eventEditor) { context in
            EventEditorSheet(event: context.event) { name, date in
                store.saveEvent(existing: context.event, name: name, eventAt: date)
            }
        }
        .alert(
            "Delete event?",
            isPresented: Binding(
                get: { eventToDelete != nil },
                set: { if !$0 { eventToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { eventToDelete = nil }
            Button("Delete", role: .destructive) {
                guard let event = eventToDelete else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    store.deleteEvent(event)
                }
                eventToDelete = nil
            }
        } message: {
            Text("This removes \(eventToDelete?.name ?? "this event") from this Mac.")
        }
    }

    private var tasksView: some View {
        VStack(spacing: 10) {
            header

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.tasks.isEmpty && !store.isLoading {
                Spacer()
                VStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(.green)
                    Text("Nothing due today")
                        .font(.subheadline.weight(.medium))
                    Text("Your day is clear.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.tasks) { task in
                            SwipeableTaskRow(
                                task: task,
                                isUpdating: store.updatingTaskIDs.contains(task.id),
                                isDeleting: store.deletingTaskIDs.contains(task.id),
                                revealedTaskID: $revealedTaskID,
                                onToggle: { Task { await store.toggle(task) } },
                                onDelete: {
                                    Task {
                                        await store.delete(task)
                                        revealedTaskID = nil
                                    }
                                }
                            )
                        }
                    }
                    .animation(.snappy(duration: 0.34), value: store.tasks)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func eventsSection(maxListHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Events looking forward to")
                    .font(.caption.weight(.semibold))

                Spacer()

                Button {
                    eventEditor = EventEditorContext(event: nil)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .help("Add event")
            }

            if let error = store.eventErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
            }

            if store.events.isEmpty {
                Button {
                    eventEditor = EventEditorContext(event: nil)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "calendar.badge.plus")
                        Text("Add an event to start a countdown")
                        Spacer()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 9)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.events) { event in
                            CountdownEventCard(
                                event: event,
                                onEdit: { eventEditor = EventEditorContext(event: event) },
                                onDelete: { eventToDelete = event }
                            )
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: store.events)
                }
                .frame(height: effectiveEventsListHeight(maxListHeight: maxListHeight))
                .scrollIndicators(.never)
            }
        }
    }

    private var eventsContentHeight: CGFloat {
        let rowHeights = CGFloat(store.events.count) * 58
        let gaps = CGFloat(max(store.events.count - 1, 0)) * 7
        return rowHeights + gaps
    }

    private func maxEventsListHeight(in panelHeight: CGFloat) -> CGFloat {
        max(58, panelHeight - 260)
    }

    private func effectiveEventsListHeight(maxListHeight: CGFloat) -> CGFloat {
        let upperBound = min(eventsContentHeight, maxListHeight)
        let requestedHeight = liveEventsListHeight ?? CGFloat(preferredEventsListHeight)
        return min(max(requestedHeight, 58), max(upperBound, 58))
    }

    private func draggableDivider(maxListHeight: CGFloat) -> some View {
        ZStack {
            Divider()

            Capsule()
                .fill(isDividerHovered || dividerDragStartHeight != nil ? Color.green : Color.secondary)
                .frame(width: 34, height: 4)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { isDividerHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("focusPanelContent"))
                .onChanged { value in
                    guard !store.events.isEmpty else { return }
                    let startHeight: CGFloat
                    if let dividerDragStartHeight {
                        startHeight = dividerDragStartHeight
                    } else {
                        startHeight = effectiveEventsListHeight(maxListHeight: maxListHeight)
                        dividerDragStartHeight = startHeight
                    }

                    let minimumHeight: CGFloat = 58
                    let maximumHeight = max(min(eventsContentHeight, maxListHeight), minimumHeight)
                    let proposedHeight = startHeight + value.translation.height
                    liveEventsListHeight = min(max(proposedHeight, minimumHeight), maximumHeight)
                }
                .onEnded { _ in
                    if let liveEventsListHeight {
                        preferredEventsListHeight = Double(liveEventsListHeight)
                    }
                    liveEventsListHeight = nil
                    dividerDragStartHeight = nil
                }
        )
        .help("Drag to show more or fewer events")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("TODAY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.headline)
                Text("\(store.remainingCount) remaining")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                follower.togglePinned()
            } label: {
                Image(systemName: follower.isPinned ? "pin.fill" : "pin.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(follower.isPinned ? .green : .secondary)
            .help(follower.isPinned ? "Unpin and move freely" : "Pin beside the active window")

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(store.isLoading ? .degrees(45) : .zero)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")

            Menu {
                Text(store.signedInEmail ?? "")
                Divider()
                windowFollowingSettings
                Divider()
                Button("Sign out") { Task { await store.signOut() } }
                Button("Quit Focus Sidecar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var windowFollowingSettings: some View {
        Menu("Settings", systemImage: "gearshape") {
            if follower.hasAccessibilityPermission {
                Label("Window following enabled", systemImage: "checkmark.circle.fill")
                    .disabled(true)
            } else {
                Button("Enable window following…", systemImage: "macwindow.on.rectangle") {
                    follower.requestPermissionIfNeeded()
                }
            }

            Button {
                follower.refreshAccessibilityPermission()
            } label: {
                Label("Check permission again", systemImage: "arrow.clockwise")
            }
        }
    }
}

private extension FocusTimerMode {
    var color: Color {
        switch self {
        case .work: .blue
        case .rest: .orange
        }
    }
}

private struct FocusTimerPanel: View {
    @ObservedObject var store: FocusTimerStore

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            timerCard(for: .work, totalSeconds: store.totalWorkSeconds)
            timerCard(for: .rest, totalSeconds: store.totalRestSeconds)

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onReceive(ticker) { _ in store.tick() }
    }

    private func timerCard(for mode: FocusTimerMode, totalSeconds: Int) -> some View {
        let isActive = store.activeMode == mode

        return VStack(spacing: 0) {
            HStack {
                Text("Total \(mode.title.lowercased()) today")
                Spacer()
                Text(totalLabel(totalSeconds))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isActive ? mode.color : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 24)

            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)

            Button {
                store.toggle(mode)
            } label: {
                HStack(spacing: 10) {
                    Text(mode.title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))

                    Spacer()

                    if isActive {
                        Text(timerLabel(store.sessionSeconds))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }

                    Image(systemName: isActive && store.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(isActive ? mode.color : Color.secondary)
                        .frame(width: 26)
                }
                .foregroundStyle(isActive ? mode.color : Color.primary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.plain)
            .help(controlHelp(for: mode, isActive: isActive))
        }
        .background(
            isActive ? mode.color.opacity(0.075) : Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive ? mode.color.opacity(0.9) : Color.white.opacity(0.11), lineWidth: 1)
        }
    }

    private func timerLabel(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let seconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func totalLabel(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%dh %02d mins %d sec", hours, minutes, remainingSeconds)
    }

    private func controlHelp(for mode: FocusTimerMode, isActive: Bool) -> String {
        guard isActive else { return "Start \(mode.title.lowercased()) timer" }
        return store.isRunning ? "Pause \(mode.title.lowercased()) timer" : "Resume \(mode.title.lowercased()) timer"
    }
}

private struct EventEditorContext: Identifiable {
    let id = UUID()
    let event: CountdownEvent?
}

private struct CountdownEventCard: View {
    let event: CountdownEvent
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                Text(event.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Menu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(event.countdownLabel)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(event.daysUntil < 0 ? Color.secondary : Color.green)
                Text(event.dateTimeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

private struct EventEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let event: CountdownEvent?
    let onSave: (String, Date) -> String?

    @State private var name: String
    @State private var eventAt: Date
    @State private var validationMessage: String?

    init(event: CountdownEvent?, onSave: @escaping (String, Date) -> String?) {
        self.event = event
        self.onSave = onSave
        _name = State(initialValue: event?.name ?? "")
        _eventAt = State(initialValue: event?.eventAt ?? Date().addingTimeInterval(86_400))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(event == nil ? "Add event" : "Edit event")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Event name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }

            DatePicker(
                "Date and time",
                selection: $eventAt,
                in: earliestDate...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
        }
        .padding(20)
        .frame(width: 320)
        .preferredColorScheme(.dark)
    }

    private var earliestDate: Date {
        min(Date().addingTimeInterval(-60), event?.eventAt ?? .distantFuture)
    }

    private func save() {
        validationMessage = onSave(name, eventAt)
        if validationMessage == nil {
            dismiss()
        }
    }
}

private struct SwipeableTaskRow: View {
    let task: FocusTask
    let isUpdating: Bool
    let isDeleting: Bool
    @Binding var revealedTaskID: UUID?
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var dragStartOffset: CGFloat?
    @State private var liveOffset: CGFloat?
    @State private var isHorizontalDrag: Bool?

    private let revealWidth: CGFloat = 58
    private let actionWidth: CGFloat = 50

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onDelete) {
                Group {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
                .background(
                    Color.red,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .opacity(revealProgress)
            .allowsHitTesting(revealProgress > 0.95 && !isDeleting)
            .accessibilityLabel("Delete task")
            .help("Delete task")
            .zIndex(1)

            TaskRow(
                task: task,
                isUpdating: isUpdating || isDeleting,
                onToggle: onToggle
            )
            .offset(x: displayedOffset)
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture)
            .animation(.snappy(duration: 0.22), value: revealedTaskID)
            .help("Drag left for task options")
            .zIndex(0)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .move(edge: .trailing))
        ))
    }

    private var settledOffset: CGFloat {
        revealedTaskID == task.id ? -revealWidth : 0
    }

    private var displayedOffset: CGFloat {
        liveOffset ?? settledOffset
    }

    private var revealProgress: Double {
        min(max(Double(-displayedOffset / revealWidth), 0), 1)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if isHorizontalDrag == nil {
                    isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                }
                guard isHorizontalDrag == true, !isDeleting else { return }

                let startOffset: CGFloat
                if let dragStartOffset {
                    startOffset = dragStartOffset
                } else {
                    startOffset = settledOffset
                    dragStartOffset = startOffset
                }

                liveOffset = min(max(startOffset + value.translation.width, -revealWidth), 0)
            }
            .onEnded { _ in
                defer {
                    liveOffset = nil
                    dragStartOffset = nil
                    isHorizontalDrag = nil
                }
                guard isHorizontalDrag == true, !isDeleting else { return }

                let shouldReveal = (liveOffset ?? settledOffset) < -(revealWidth / 2)
                withAnimation(.snappy(duration: 0.22)) {
                    revealedTaskID = shouldReveal ? task.id : nil
                }
            }
    }
}

private struct TaskRow: View {
    let task: FocusTask
    let isUpdating: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: task.isDone)
                    .frame(width: 16, height: 16)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(task.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .help(task.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .strikethrough(task.isDone)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if let time = task.timeLabel {
                        Text(time)
                    }
                    if let priority = task.priority {
                        Label(priority, systemImage: "circle.fill")
                            .labelStyle(PriorityLabelStyle(priority: priority))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity.combined(with: .scale(scale: 0.94))
        ))
    }
}

private struct PriorityLabelStyle: LabelStyle {
    let priority: String

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(color)
            configuration.title
        }
    }

    private var color: Color {
        switch priority {
        case "High": .red
        case "Medium": .orange
        default: .blue
        }
    }
}

private struct SignInView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var follower: WindowFollower
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Button {
                    follower.togglePinned()
                } label: {
                    Image(systemName: follower.isPinned ? "pin.fill" : "pin.slash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(follower.isPinned ? .green : .secondary)
                .help(follower.isPinned ? "Unpin and move freely" : "Pin beside the active window")

                Menu {
                    Menu("Settings", systemImage: "gearshape") {
                        if follower.hasAccessibilityPermission {
                            Label("Window following enabled", systemImage: "checkmark.circle.fill")
                                .disabled(true)
                        } else {
                            Button("Enable window following…", systemImage: "macwindow.on.rectangle") {
                                follower.requestPermissionIfNeeded()
                            }
                        }

                        Button("Check permission again", systemImage: "arrow.clockwise") {
                            follower.refreshAccessibilityPermission()
                        }
                    }
                    Divider()
                    Button("Quit Focus Sidecar") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Today’s tasks")
                    .font(.headline)
                Text("Sign in with your LMS account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit { signIn() }

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Button(action: signIn) {
                HStack {
                    if store.isLoading { ProgressView().controlSize(.small) }
                    Text("Sign in")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(store.isLoading)

            Text("Your password is never stored. The session is kept in Keychain.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func signIn() {
        Task { await store.signIn(email: email, password: password) }
    }
}

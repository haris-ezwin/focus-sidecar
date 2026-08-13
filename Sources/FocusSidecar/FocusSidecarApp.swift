import AppKit
import SwiftUI

@MainActor
final class FocusSidecarApp: NSObject, NSApplicationDelegate {
    private static let bundleIdentifier = "com.ezwin.focus-sidecar"
    private static let showPanelNotification = Notification.Name("com.ezwin.focus-sidecar.show-panel")

    private var panel: CompanionPanel?
    private var follower: WindowFollower?
    private var store: TaskStore?
    private var timerStore: FocusTimerStore?
    private var menuBarTimerController: MenuBarTimerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceIfNeeded() {
            return
        }

        NSApp.setActivationPolicy(.regular)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showPanelFromExternalLaunch),
            name: Self.showPanelNotification,
            object: nil
        )

        let configuration: SupabaseConfiguration
        do {
            configuration = try SupabaseConfiguration.load()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Focus Sidecar is not configured"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let service = SupabaseService(configuration: configuration)
        let store = TaskStore(service: service)
        let timerStore = FocusTimerStore()
        let follower = WindowFollower()
        let contentView = TaskPanelView(store: store, follower: follower, timerStore: timerStore)

        let panel = CompanionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 284, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.managed]
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = false
        panel.standardWindowButton(.zoomButton)?.isHidden = false
        panel.contentViewController = NSHostingController(rootView: contentView)
        panel.setContentSize(NSSize(width: 284, height: 620))
        panel.contentMinSize = NSSize(width: 284, height: 620)
        panel.contentMaxSize = NSSize(width: 420, height: 820)
        let restoredFrame = panel.setFrameUsingName("FocusSidecarWindowFrame")
        _ = panel.setFrameAutosaveName("FocusSidecarWindowFrame")

        follower.attach(panel: panel, useDefaultPlacement: !restoredFrame)
        follower.start()
        panel.orderFrontRegardless()

        self.panel = panel
        self.follower = follower
        self.store = store
        self.timerStore = timerStore
        self.menuBarTimerController = MenuBarTimerController(store: timerStore) { [weak follower] in
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            follower?.showPanel()
        }

        Task { await store.restoreAndLoad() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        follower?.showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        timerStore?.stopForTermination()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func showPanelFromExternalLaunch() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        follower?.showPanel()
    }

    private func activateExistingInstanceIfNeeded() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingInstances = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }

        guard let existing = existingInstances.first else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            Self.showPanelNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }
}

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@main
@MainActor
enum FocusSidecarMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = FocusSidecarApp()
        application.delegate = delegate
        application.run()
    }
}

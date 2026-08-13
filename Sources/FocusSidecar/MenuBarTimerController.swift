import AppKit
import Combine

@MainActor
final class MenuBarTimerController {
    private let store: FocusTimerStore
    private let onOpenApp: () -> Void
    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?

    init(store: FocusTimerStore, onOpenApp: @escaping () -> Void) {
        self.store = store
        self.onOpenApp = onOpenApp

        cancellable = Publishers.CombineLatest3(
            store.$activeMode,
            store.$isRunning,
            store.$sessionSeconds
        )
        .sink { [weak self] mode, isRunning, seconds in
            self?.render(mode: mode, isRunning: isRunning, seconds: seconds)
        }
    }

    private func render(mode: FocusTimerMode?, isRunning: Bool, seconds: Int) {
        guard isRunning, let mode else {
            removeStatusItem()
            return
        }

        let item = statusItem ?? makeStatusItem()
        guard let button = item.button else { return }

        button.image = NSImage(
            systemSymbolName: mode == .work ? "laptopcomputer" : "cup.and.saucer.fill",
            accessibilityDescription: "\(mode.title) timer"
        )
        button.image?.isTemplate = true
        button.title = elapsedTimeLabel(seconds)
        button.toolTip = "\(mode.title) timer — click to open Focus Sidecar"
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(openApp)
        }
        statusItem = item
        return item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func elapsedTimeLabel(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    @objc private func openApp() {
        onOpenApp()
    }
}

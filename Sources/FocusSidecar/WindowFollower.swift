import AppKit
import ApplicationServices
import Foundation

@MainActor
final class WindowFollower: ObservableObject {
    @Published private(set) var hasAccessibilityPermission = AXIsProcessTrusted()
    @Published private(set) var isPinned: Bool

    private weak var panel: NSPanel?
    private var timer: Timer?
    private var lastExternalPID: pid_t?
    private var pinnedOffset: CGPoint?
    private static let pinPreferenceKey = "focus-sidecar.is-pinned"
    private static let pinOffsetXKey = "focus-sidecar.pin-offset-x"
    private static let pinOffsetYKey = "focus-sidecar.pin-offset-y"

    init() {
        if let storedValue = UserDefaults.standard.object(forKey: Self.pinPreferenceKey) as? Bool {
            isPinned = storedValue
        } else {
            isPinned = true
        }
        if let x = UserDefaults.standard.object(forKey: Self.pinOffsetXKey) as? Double,
           let y = UserDefaults.standard.object(forKey: Self.pinOffsetYKey) as? Double {
            pinnedOffset = CGPoint(x: x, y: y)
        }
    }

    func attach(panel: NSPanel, useDefaultPlacement: Bool) {
        self.panel = panel
        applyDesktopBehavior()
        if useDefaultPlacement {
            placeAtScreenEdge()
        }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        requestPermissionIfNeeded()
        updatePosition()
    }

    func requestPermissionIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func togglePinned() {
        isPinned.toggle()
        UserDefaults.standard.set(isPinned, forKey: Self.pinPreferenceKey)
        applyDesktopBehavior()
        if isPinned {
            capturePinOffset()
        }
    }

    func showPanel() {
        guard let panel else { return }
        let panelArea = panel.frame.width * panel.frame.height
        let largestVisibleArea = NSScreen.screens
            .map { screen -> CGFloat in
                let intersection = screen.visibleFrame.intersection(panel.frame)
                guard !intersection.isNull else { return 0 }
                return intersection.width * intersection.height
            }
            .max() ?? 0

        if panelArea == 0 || largestVisibleArea < panelArea * 0.4 {
            placeAtScreenEdge()
        }
        panel.orderFrontRegardless()
    }

    private func updatePosition() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibilityPermission {
            hasAccessibilityPermission = trusted
        }
        guard trusted, isPinned, let panel else { return }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            lastExternalPID = frontmost.processIdentifier
        }
        guard let pid = lastExternalPID, let frame = focusedWindowFrame(for: pid) else { return }

        if pinnedOffset == nil {
            savePinOffset(panelFrame: panel.frame, targetFrame: frame)
            return
        }
        guard let pinnedOffset else { return }
        let panelSize = panel.frame.size
        let destination = CGPoint(
            x: frame.minX + pinnedOffset.x,
            y: frame.maxY + pinnedOffset.y - panelSize.height
        )
        if hypot(panel.frame.origin.x - destination.x, panel.frame.origin.y - destination.y) > 1 {
            panel.setFrameOrigin(destination)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func applyDesktopBehavior() {
        guard let panel else { return }
        if isPinned {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            panel.collectionBehavior = [.managed]
        }
    }

    private func capturePinOffset() {
        guard let panel, AXIsProcessTrusted() else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            lastExternalPID = frontmost.processIdentifier
        }
        guard let pid = lastExternalPID,
              let targetFrame = focusedWindowFrame(for: pid) else { return }
        savePinOffset(panelFrame: panel.frame, targetFrame: targetFrame)
    }

    private func savePinOffset(panelFrame: CGRect, targetFrame: CGRect) {
        let offset = CGPoint(
            x: panelFrame.minX - targetFrame.minX,
            y: panelFrame.maxY - targetFrame.maxY
        )
        pinnedOffset = offset
        UserDefaults.standard.set(Double(offset.x), forKey: Self.pinOffsetXKey)
        UserDefaults.standard.set(Double(offset.y), forKey: Self.pinOffsetYKey)
    }

    private func focusedWindowFrame(for pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else { return nil }
        let windowElement = unsafeDowncast(window, to: AXUIElement.self)

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let positionAX = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeValue, to: AXValue.self)

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }

        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: position.x,
            y: primaryTop - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func placeAtScreenEdge() {
        guard let panel, let visible = NSScreen.main?.visibleFrame else { return }
        let width = max(panel.frame.width, 268)
        let height = max(panel.frame.height, 332)
        panel.setFrameOrigin(CGPoint(
            x: visible.maxX - width - 14,
            y: visible.maxY - height - 14
        ))
    }
}

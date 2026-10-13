import AppKit
import SwiftUI

/// A Control Center–style drop-down: an arrowless, rounded, translucent panel
/// pinned just under its status item. It closes when it loses focus (a click
/// elsewhere) or on Escape, and keeps its top edge fixed as content resizes.
@MainActor
final class MenuBarPanel: NSObject, NSWindowDelegate {
    private let panel: KeyablePanel
    private let hosting: NSHostingController<AnyView>
    private weak var anchor: NSStatusBarButton?
    private var resizeObserver: NSObjectProtocol?
    private var lastAutoClose = Date.distantPast
    var onClose: (() -> Void)?

    static let cornerRadius: CGFloat = 14
    static let gap: CGFloat = 4

    init<Content: View>(content: Content) {
        hosting = NSHostingController(rootView: AnyView(content))
        hosting.sizingOptions = [.preferredContentSize]
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: true)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background

        // SwiftUI content can grow or shrink (rules added, notices shown); keep
        // the panel's top edge pinned under the menu bar when it does.
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        hosting.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: hosting.view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToContent() }
        }
    }

    var isShown: Bool { panel.isVisible }

    func show(below button: NSStatusBarButton) {
        anchor = button
        fitToContent()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        anchor?.highlight(false)
        onClose?()
    }

    func toggle(below button: NSStatusBarButton) {
        if isShown { close(); return }
        // Clicking the status item first steals focus (closing us), then sends
        // its action; don't reopen in that case.
        guard Date().timeIntervalSince(lastAutoClose) > 0.3 else { return }
        show(below: button)
    }

    private func fitToContent() {
        let size = hosting.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        if panel.frame.size != size { panel.setContentSize(size) }
        reposition()
    }

    private func reposition() {
        guard let button = anchor, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = panel.frame.size
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = buttonFrame.minY - Self.gap - size.height
        let frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click in another app, the menu bar, or the desktop dismisses it, like a menu.
        guard panel.isVisible else { return }
        lastAutoClose = Date()
        close()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Borderless panels can't become key by default; text fields need key status.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

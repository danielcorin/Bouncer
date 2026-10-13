import AppKit
import BouncerCore
import Combine
import SwiftUI

/// The menu bar item. Its icon reflects the blocking phase, and it briefly flashes
/// the blocked domain whenever Bouncer turns a lookup away.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: BlockingStore
    private let service: BouncerService
    private let configuration: AppConfigurationModel
    private var cancellables: Set<AnyCancellable> = []
    private var flashTask: Task<Void, Never>?
    private var flashing = false

    init(store: BlockingStore, service: BouncerService, configuration: AppConfigurationModel, openSettings: @escaping () -> Void) {
        self.store = store
        self.service = service
        self.configuration = configuration
        super.init()

        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: MenuView(store: store, service: service, configuration: configuration) { [weak self] in
            self?.popover.performClose(nil)
            openSettings()
        } quit: {
            NSApp.terminate(nil)
        })
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.toolTip = "Bouncer — Option-click to toggle blocking"
        }

        store.$phase.combineLatest(store.$isEnabled, store.$dnsVerified)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)
        store.blocks
            .receive(on: RunLoop.main)
            .sink { [weak self] entry in
                guard let self, self.configuration.configuration.flashIndicator else { return }
                self.flash(text: entry.domain, symbol: "hand.raised.fill", color: .systemRed)
            }
            .store(in: &cancellables)
        refreshIcon()
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            Task {
                let state = try? await service.blockingToggle(.init())
                announce(state?.enabled == true ? "Blocking on" : "Blocking off", failed: state == nil)
            }
            return
        }
        popover.isShown ? popover.performClose(sender) : showPopover()
    }

    func showPopover() {
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Short confirmation after a hotkey or option-click toggle.
    func announce(_ text: String, failed: Bool = false) {
        let symbol = failed ? "exclamationmark.shield.fill" : (store.isEnabled ? "shield.fill" : "shield")
        flash(text: text, symbol: symbol, color: failed ? .systemOrange : nil, duration: 1.4)
    }

    private func flash(text: String, symbol: String, color: NSColor?, duration: TimeInterval = 2.5) {
        guard let button = item.button else { return }
        flashing = true
        button.image = Self.image(symbol, color: color)
        let shown = text.count > 32 ? "…" + text.suffix(31) : text
        button.attributedTitle = NSAttributedString(string: " " + shown, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: color ?? NSColor.labelColor,
        ])
        Self.pulse(button)
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.flashing = false
            self.refreshIcon()
        }
    }

    private func refreshIcon() {
        guard !flashing, let button = item.button else { return }
        let symbol: String
        switch store.phase {
        case .on where store.dnsVerified == false: symbol = "exclamationmark.shield.fill"
        case .on: symbol = "shield.fill"
        case .starting, .stopping: symbol = "shield.lefthalf.filled"
        case .failed: symbol = "exclamationmark.shield"
        case .off: symbol = "shield"
        }
        button.image = Self.image(symbol, color: nil)
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.appearsDisabled = store.phase == .off
        button.setAccessibilityLabel("Bouncer, blocking \(store.phase.rawValue)")
    }

    private static func image(_ symbol: String, color: NSColor?) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Bouncer")
        guard let color else { image?.isTemplate = true; return image }
        let configured = image?.withSymbolConfiguration(.init(paletteColors: [color]))
        configured?.isTemplate = false
        return configured
    }

    private static func pulse(_ view: NSView) {
        view.wantsLayer = true
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 0.35, 1, 0.35, 1]
        animation.duration = 0.6
        view.layer?.add(animation, forKey: "bouncer.pulse")
    }
}

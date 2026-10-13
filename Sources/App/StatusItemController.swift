import AppKit
import BouncerCore
import Combine
import SwiftUI

/// The menu bar item. Its icon reflects the blocking phase, and it briefly flashes
/// the blocked domain whenever Bouncer turns a lookup away.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: MenuBarPanel!
    private let store: BlockingStore
    private let service: BouncerService
    private let configuration: AppConfigurationModel
    private var cancellables: Set<AnyCancellable> = []
    private var flashTask: Task<Void, Never>?
    private var flashing = false

    init(store: BlockingStore, service: BouncerService, configuration: AppConfigurationModel,
         openSettings: @escaping () -> Void, openAbout: @escaping () -> Void) {
        self.store = store
        self.service = service
        self.configuration = configuration
        super.init()

        panel = MenuBarPanel(content: MenuView(store: store, service: service, configuration: configuration,
            openSettings: { [weak self] in
                self?.panel.close()
                openSettings()
            },
            openAbout: { [weak self] in
                self?.panel.close()
                openAbout()
            },
            quit: { NSApp.terminate(nil) }))

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
                do { _ = try await service.blockingToggle(.init()) }
                catch { announceFailure() }
            }
            return
        }
        panel.toggle(below: sender)
    }

    func showPopover() {
        guard let button = item.button, !panel.isShown else { return }
        panel.show(below: button)
    }

    /// Brief warning when a hotkey or option-click toggle fails. Successful
    /// toggles show nothing extra; the icon simply changes.
    func announceFailure() {
        flash(text: "Couldn't toggle", symbol: "exclamationmark.shield.fill", color: .systemOrange, duration: 1.4)
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

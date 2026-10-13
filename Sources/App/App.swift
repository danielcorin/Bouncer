import AppKit
import AutomationRuntime
import BouncerCore
import Combine

/// Process-level facts and window actions for `BouncerService`.
@MainActor
final class AppKitShell: AppShell {
    var onShow: (() -> Void)?
    let appName = "Bouncer"
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown" }
    var isFrontmost: Bool { NSApp.isActive }

    func show() throws -> String {
        onShow?()
        return "Bouncer's menu is open."
    }

    func quit() throws -> String {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.terminate(nil)
        }
        return "Bouncer is quitting; blocks are being removed."
    }
}

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    let configurationModel = AppConfigurationModel()
    let store: BlockingStore
    let service: BouncerService
    private let shell = AppKitShell()
    private let hotkeys = HotkeyManager()
    private let configuration = ConfigurationOperationService()
    private var server: AutomationSocketServer?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []

    private lazy var host = AutomationHost(
        version: shell.version,
        operations: GeneratedCatalog.operations.map(\.id),
        normalize: { MacAutomationErrors.normalize($0) }
    ) { [weak self] request in
        guard let self else { throw AutomationFailure("unavailable", "The app is shutting down.") }
        if let value = try await self.configuration.dispatchConfiguration(request) { return value }
        return try await self.service.dispatchApplication(request)
    }

    private init() {
        let initial = configurationModel.configuration
        store = BlockingStore(backend: TunnelFilterBackend(), options: initial.filterOptions)
        service = BouncerService(store: store, shell: shell, configuration: initial)
    }

    func start() {
        configurationModel.start()
        let statusItem = StatusItemController(store: store, service: service, configuration: configurationModel) { [weak self] in
            self?.showSettings()
        }
        self.statusItem = statusItem
        shell.onShow = { [weak statusItem] in statusItem?.showPopover() }

        hotkeys.onPress = { [weak self] in self?.toggleFromHotkey() }
        configurationModel.$configuration
            .removeDuplicates()
            .sink { [weak self] configuration in
                guard let self else { return }
                self.hotkeys.register(HotkeyChord(configuration.hotkey))
                Task { await self.service.applyConfiguration(configuration) }
            }
            .store(in: &cancellables)

        let server = AutomationSocketServer(path: BouncerAutomationPaths.socket.path) { await AppRuntime.shared.host.handle($0) }
        do {
            try BouncerAutomationPaths.transfers.cleanExpired()
            try server.start()
            self.server = server
        } catch {
            NSLog("Automation startup failed: \(error.localizedDescription)")
        }

        let enableOnLaunch = configurationModel.configuration.enableOnLaunch
        Task {
            await service.start()
            if enableOnLaunch { _ = try? await service.blockingOn(.init()) }
        }
    }

    func stop() {
        hotkeys.register(nil)
        service.shutdown()
        server?.stop()
        server = nil
    }

    private func toggleFromHotkey() {
        Task {
            do {
                let state = try await service.blockingToggle(.init())
                statusItem?.announce(state.enabled ? "Blocking on" : "Blocking off")
            } catch {
                statusItem?.announce("Couldn't toggle", failed: true)
            }
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: store, service: service, configuration: configurationModel)
        }
        settingsWindow?.present()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.mainMenu = Self.makeMainMenu()
            AppRuntime.shared.start()
        }
    }

    /// Never shown (no menu bar of our own as an accessory app), but it supplies
    /// key equivalents while the popover or Settings is focused: ⌘Q, ⌘,, ⌘W, and
    /// the Edit shortcuts that text fields rely on.
    @MainActor private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "Bouncer")
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Bouncer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for submenu in [app, edit, window] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }

    @objc func showSettings(_ sender: Any?) {
        MainActor.assumeIsolated { AppRuntime.shared.showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Blocks never outlive the app: stop the tunnel now. If this process dies
        // without getting here, the tunnel stops itself when heartbeats cease.
        MainActor.assumeIsolated { AppRuntime.shared.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
enum BouncerMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

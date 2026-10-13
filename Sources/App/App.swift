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
        store = BlockingStore(backend: HelperFilterBackend(), options: initial.filterOptions)
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

        if configurationModel.configuration.enableOnLaunch {
            Task { _ = try? await service.blockingOn(.init()) }
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
        MainActor.assumeIsolated { AppRuntime.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Blocks never outlive the app: tell the helper to restore DNS now. If this
        // process dies without getting here, the helper does it on disconnect.
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

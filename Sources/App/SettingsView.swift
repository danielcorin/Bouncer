import AppKit
import BouncerCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(store: BlockingStore, service: BouncerService, configuration: AppConfigurationModel, openAbout: @escaping () -> Void) {
        window = NSWindow(contentViewController: NSHostingController(rootView:
            SettingsView(store: store, service: service, configuration: configuration, openAbout: openAbout)))
        window.title = "Bouncer Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var store: BlockingStore
    let service: BouncerService
    @ObservedObject var configuration: AppConfigurationModel
    let openAbout: () -> Void

    @State private var upstream = ""
    @State private var testDomain = ""
    @State private var testResult: String?
    @State private var tunnelMessage: String?
    @State private var cliMessage: String?
    @State private var confirmUninstall = false

    private var config: AppConfiguration { configuration.configuration }

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Toggle blocking") {
                    HotkeyRecorder(chord: HotkeyChord(config.hotkey)) { chord in
                        configuration.set(.hotkey, value: chord?.description ?? "")
                    }
                }
            }

            Section("Behavior") {
                Toggle("Turn blocking on when Bouncer launches", isOn: binding(.enableOnLaunch, \.enableOnLaunch))
                Toggle("Flash the menu bar when a site is blocked", isOn: binding(.flashIndicator, \.flashIndicator))
                Toggle(isOn: binding(.blockBypassCanaries, \.blockBypassCanaries)) {
                    Text("Prevent DNS bypass while blocking")
                    Text("Signals Firefox's DNS-over-HTTPS to use system DNS so blocks apply to it too.")
                }
                LabeledContent("Upstream DNS") {
                    TextField("Automatic (network DHCP)", text: $upstream)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { configuration.set(.upstreamDNS, value: upstream) }
                }
            }

            Section("Test a domain") {
                HStack {
                    TextField("news.ycombinator.com", text: $testDomain)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(runTest)
                    Button("Test", action: runTest).disabled(testDomain.isEmpty)
                }
                if let testResult {
                    Text(testResult).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("DNS tunnel") {
                LabeledContent("Status", value: tunnelStatus)
                HStack {
                    Button(store.tunnel.installed ? "Reinstall Configuration" : "Install Configuration") {
                        perform { _ = try await service.tunnelInstall(.init()) }
                    }
                    Button("Remove Configuration…") { confirmUninstall = true }
                        .disabled(!store.tunnel.installed)
                }
                Text("Bouncer blocks by running a VPN-style tunnel that only handles DNS. It appears as “Bouncer” in System Settings › VPN and runs only while blocking is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tunnelMessage {
                    Text(tunnelMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section("Command line") {
                HStack {
                    Button("Install Command Line Tool", action: installCLI)
                    Spacer()
                    Text("bouncer on · off · toggle · rules add").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let cliMessage {
                    Text(cliMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Settings file") {
                    Button(configuration.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                        NSWorkspace.shared.activateFileViewerSelecting([configuration.fileURL.deletingLastPathComponent()])
                    }
                    .buttonStyle(.link)
                }
            }

            Section("About") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bouncer").font(.headline)
                        Text("\(AboutInfo.version) · \(AboutInfo.copyright)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("About Bouncer…", action: openAbout)
                }
            }

            if let error = configuration.configurationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            upstream = config.upstreamDNS.joined(separator: ", ")
            store.refreshTunnel()
        }
        .confirmationDialog("Remove Bouncer's DNS tunnel configuration?", isPresented: $confirmUninstall) {
            Button("Remove", role: .destructive) {
                perform { _ = try await service.tunnelRemove(.init(force: true)) }
            }
        } message: {
            Text("Blocking turns off. macOS will ask you to allow the tunnel again next time you enable it.")
        }
    }

    private var tunnelStatus: String {
        guard store.tunnel.installed else { return "Not installed — installs the first time you turn blocking on" }
        return store.tunnelConnected ? "Installed, running" : "Installed, stopped"
    }

    private func binding(_ key: AppConfigurationKey, _ path: KeyPath<AppConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { config[keyPath: path] }, set: { configuration.set(key, $0) })
    }

    private func runTest() {
        let domain = testDomain
        Task {
            do {
                let result = try await service.ruleTest(.init(domain: domain))
                switch result.decision {
                case .blocked: testResult = "Blocked by \(result.rule?.pattern ?? "a rule")."
                case .allowed: testResult = "Allowed by the allow rule \(result.rule?.pattern ?? "")."
                case .unmatched: testResult = "No rule matches \(result.domain); it resolves normally."
                }
            } catch {
                testResult = MacAutomationErrors.normalize(error).message
            }
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
                tunnelMessage = nil
            } catch {
                tunnelMessage = MacAutomationErrors.normalize(error).message
            }
        }
    }

    private func installCLI() {
        do {
            cliMessage = "Installed \(try CLIInstaller.install().path). Make sure ~/.local/bin is on your PATH."
        } catch {
            cliMessage = error.localizedDescription
        }
    }
}

/// Click, then press the new shortcut. Escape cancels; Delete clears.
struct HotkeyRecorder: View {
    let chord: HotkeyChord?
    let onChange: (HotkeyChord?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Type shortcut…" : (chord?.displayString ?? "None")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 110)
            if chord != nil && !recording {
                Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Disable the shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 && flags.isEmpty { stop(); return nil } // Escape
            if event.keyCode == 51 && flags.isEmpty { onChange(nil); stop(); return nil } // Delete
            var modifiers = Set<HotkeyChord.Modifier>()
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.command) { modifiers.insert(.command) }
            if let chord = HotkeyChord(keyCode: UInt32(event.keyCode), modifiers: modifiers) {
                onChange(chord)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

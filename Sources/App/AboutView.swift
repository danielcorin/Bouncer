import AppKit
import BouncerCore
import SwiftUI

@MainActor
final class AboutWindowController {
    private let window: NSWindow

    init(configuration: AppConfigurationModel, openSettings: @escaping () -> Void) {
        window = NSWindow(contentViewController: NSHostingController(rootView:
            AboutView(configuration: configuration, openSettings: openSettings)))
        window.title = "About Bouncer"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}

struct AboutInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    static var noticesURL: URL? {
        Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
    }
}

struct AboutView: View {
    @ObservedObject var configuration: AppConfigurationModel
    let openSettings: () -> Void

    private var hotkey: String { HotkeyChord(configuration.configuration.hotkey)?.displayString ?? "none" }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Bouncer")
                    .font(.title.bold())
                Text(AboutInfo.version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Turns away the sites you don't want to visit — in every browser and app.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                fact("shield.lefthalf.filled", "How it works",
                     "While blocking is on, a DNS-only tunnel answers lookups for blocked domains with “not found” and passes everything else through. It works with iCloud Private Relay, and quitting Bouncer always removes every block.")
                fact("text.magnifyingglass", "Rules",
                     "reddit.com blocks a site and its subdomains, *.example.com only subdomains, and /regex/ any matching domain. Allow rules always win.")
                fact("keyboard", "Shortcuts",
                     "\(hotkey) toggles blocking anywhere · Option-click the menu bar icon to toggle · ⌘Q quits.")
                fact("terminal", "Command line",
                     "bouncer on · off · toggle · rules add · test · activity")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Settings…", action: openSettings)
                if let notices = AboutInfo.noticesURL {
                    Button("Third-Party Notices") { NSWorkspace.shared.open(notices) }
                }
            }
            .controlSize(.small)

            Text(AboutInfo.copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func fact(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

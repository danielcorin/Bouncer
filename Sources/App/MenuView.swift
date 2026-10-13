import BouncerCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var store: BlockingStore
    let service: BouncerService
    @ObservedObject var configuration: AppConfigurationModel
    let openSettings: () -> Void
    let openAbout: () -> Void
    let quit: () -> Void

    @State private var draft = ""
    @State private var draftAction: FilterRule.Action = .block
    @State private var error: String?
    @State private var editing: UUID?
    @State private var editText = ""
    @State private var hovered: UUID?
    @State private var info: String?
    @State private var restartingBrowser = false
    /// Read on each render so it follows changes to the default browser.
    private var defaultBrowser: BrowserInfo? { WorkspaceBrowserController().defaultBrowser() }

    private var busy: Bool { store.phase == .starting || store.phase == .stopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, notice == nil ? 12 : 10)
            if let notice {
                noticeView(notice)
                    .padding(.bottom, 12)
            }
            Divider()
            addRow
                .padding(.vertical, 12)
            rulesList
            if !store.activity.isEmpty {
                Divider().padding(.top, 10)
                activityList
                    .padding(.top, 10)
            }
            Divider().padding(.top, 10)
            footer
                .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: 340)
        .tint(.bouncer)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: headerSymbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(headerColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bouncer").font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Toggle("Blocking", isOn: Binding(get: { store.isEnabled }, set: { setEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(busy)
                .help("Toggle blocking (\(hotkeyDisplay ?? "no shortcut"))")
        }
    }

    private var headerSymbol: String {
        switch store.phase {
        case .on where store.dnsVerified == false: "exclamationmark.shield.fill"
        case .on: "shield.fill"
        case .starting, .stopping: "shield.lefthalf.filled"
        case .failed: "exclamationmark.shield"
        case .off: "shield"
        }
    }

    private var headerColor: Color {
        switch store.phase {
        case .on where store.dnsVerified == false: .orange
        case .on: .bouncer
        case .failed: .red
        default: .secondary
        }
    }

    private var summary: String {
        let state = switch store.phase {
        case .on where store.dnsVerified == false: "Bypassed"
        case .on: "Blocking"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .failed: "Not blocking"
        case .off: "Off"
        }
        let blockCount = store.rules.filter { $0.enabled && $0.action == .block }.count
        var parts = [state, blockCount == 0 ? "no rules" : "\(blockCount) rule\(blockCount == 1 ? "" : "s")"]
        if let hotkeyDisplay { parts.append(hotkeyDisplay) }
        return parts.joined(separator: " · ")
    }

    private var hotkeyDisplay: String? { HotkeyChord(configuration.configuration.hotkey)?.displayString }

    // MARK: - Notices

    private struct Notice {
        var text: String
        var isError: Bool
    }

    private var notice: Notice? {
        if let error { return Notice(text: error, isError: true) }
        if let info { return Notice(text: info, isError: false) }
        guard let message = store.message else { return nil }
        return Notice(text: message, isError: store.phase == .failed)
    }

    private func noticeView(_ notice: Notice) -> some View {
        let warning = notice.isError || store.dnsVerified == false
        let color: Color = notice.isError ? .red : warning ? .orange : .secondary
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(color)
            Text(notice.text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Adding

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("Add a domain or /regex/", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addRule)
                Picker("", selection: $draftAction) {
                    Text("Block").tag(FilterRule.Action.block)
                    Text("Allow").tag(FilterRule.Action.allow)
                }
                .labelsHidden()
                .fixedSize()
                Button(action: addRule) { Image(systemName: "plus") }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add rule (Return)")
            }
            Text("Includes subdomains · /pattern/ for regex · allow beats block")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Rules

    @ViewBuilder private var rulesList: some View {
        if store.rules.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "hand.raised")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No rules yet")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Try reddit.com or /tiktok|instagram/")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(store.rules) { rule in row(rule) }
                }
            }
            .frame(maxHeight: min(CGFloat(store.rules.count) * 27, 243))
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func row(_ rule: FilterRule) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { enabled in
                run { _ = try await service.ruleUpdate(.init(enabled: enabled, id: rule.id.uuidString)) }
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help(rule.enabled ? "Disable rule" : "Enable rule")
            if editing == rule.id {
                TextField("Pattern", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { commitEdit(rule) }
                    .onExitCommand { editing = nil }
            } else {
                Text(rule.kind == .regex ? "/\(rule.pattern)/" : rule.pattern)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(rule.enabled ? .primary : .tertiary)
                    .strikethrough(!rule.enabled, color: .secondary.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture(count: 2) { beginEdit(rule) }
                    .help("Double-click to edit")
            }
            Spacer(minLength: 4)
            if rule.action == .allow {
                Text("allow")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.green.opacity(0.13), in: Capsule())
                    .help("Allow rules override block rules")
            }
            Button {
                run { _ = try await service.ruleRemove(.init(id: rule.id.uuidString)) }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovered == rule.id ? 1 : 0)
            .help("Remove rule")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(hovered == rule.id ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = rule.id } else if hovered == rule.id { hovered = nil }
        }
        .contextMenu {
            Button("Edit Pattern") { beginEdit(rule) }
            Button(rule.action == .block ? "Make Allow Rule" : "Make Block Rule") {
                run { _ = try await service.ruleUpdate(.init(action: rule.action == .block ? "allow" : "block", id: rule.id.uuidString)) }
            }
            Button(rule.kind == .domain ? "Treat as Regex" : "Treat as Domain") {
                run { _ = try await service.ruleUpdate(.init(id: rule.id.uuidString, kind: rule.kind == .domain ? "regex" : "domain")) }
            }
            Button("Copy Pattern") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rule.pattern, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive) {
                run { _ = try await service.ruleRemove(.init(id: rule.id.uuidString)) }
            }
        }
    }

    // MARK: - Activity

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Recently blocked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.blockedCount) since launch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            TimelineView(.periodic(from: .now, by: 5)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.activity.prefix(4)) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: "hand.raised.fill")
                                .font(.caption2)
                                .foregroundStyle(.red.opacity(0.85))
                            Text(entry.domain)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if entry.count > 1 {
                                Text("×\(entry.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            Text(CompactRelativeTime.string(since: entry.lastSeen, now: context.date))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .help("Blocked by \(entry.rulePattern)")
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 2) {
            Button(action: openSettings) { Label("Settings…", systemImage: "gearshape") }
                .buttonStyle(FooterButtonStyle())
            Button(action: openAbout) { Image(systemName: "info.circle") }
                .buttonStyle(FooterButtonStyle())
                .help("About Bouncer")
            if let browser = defaultBrowser {
                Button(action: restartBrowser) {
                    HStack(spacing: 5) {
                        if restartingBrowser {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Restart \(browser.name)").lineLimit(1)
                    }
                }
                .buttonStyle(FooterButtonStyle())
                .disabled(restartingBrowser)
                .help("Quit and reopen \(browser.name) so it drops connections to sites you just blocked\(browser.restoresTabs == true ? "; its windows and tabs reopen" : "")")
            }
            Spacer(minLength: 4)
            Button(action: quit) {
                HStack(spacing: 4) {
                    Text("Quit")
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(FooterButtonStyle())
            .help("Quitting removes all blocks")
        }
        .font(.callout)
    }

    // MARK: - Actions

    private func setEnabled(_ enabled: Bool) {
        run {
            if enabled { _ = try await service.blockingOn(.init()) } else { _ = try await service.blockingOff(.init()) }
        }
    }

    private func restartBrowser() {
        restartingBrowser = true
        run {
            defer { restartingBrowser = false }
            let result = try await service.browserRestart(.init(force: true))
            if !result.restarted {
                info = result.message
                try? await Task.sleep(for: .seconds(4))
                if info == result.message { info = nil }
            }
        }
    }

    private func addRule() {
        let pattern = draft
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        run {
            _ = try await service.ruleAdd(.init(action: draftAction.rawValue, pattern: pattern))
            draft = ""
        }
    }

    private func beginEdit(_ rule: FilterRule) {
        editText = rule.kind == .regex ? "/\(rule.pattern)/" : rule.pattern
        editing = rule.id
    }

    private func commitEdit(_ rule: FilterRule) {
        let text = editText
        run {
            _ = try await service.ruleUpdate(.init(id: rule.id.uuidString, pattern: text))
            editing = nil
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await work()
                error = nil
            } catch {
                self.error = MacAutomationErrors.normalize(error).message
            }
        }
    }
}

/// Quiet, menu-like footer buttons that highlight on hover.
private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(isPressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverHighlight<Label: View>: View {
        let isPressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var hovering = false

        var body: some View {
            label()
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(.secondary)
                .background(Color.primary.opacity(isPressed ? 0.12 : hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

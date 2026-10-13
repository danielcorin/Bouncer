import BouncerCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var store: BlockingStore
    let service: BouncerService
    @ObservedObject var configuration: AppConfigurationModel
    let openSettings: () -> Void
    let quit: () -> Void

    @State private var draft = ""
    @State private var draftAction: FilterRule.Action = .block
    @State private var error: String?
    @State private var editing: UUID?
    @State private var editText = ""

    private var busy: Bool { store.phase == .starting || store.phase == .stopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let message = store.message ?? error {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(store.phase == .failed || error != nil ? .red : store.dnsVerified == false ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Divider()
            addRow
            rulesList
            if !store.activity.isEmpty {
                Divider()
                activityList
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: store.phase == .on ? "shield.fill" : store.phase == .failed ? "exclamationmark.shield" : "shield")
                .font(.title2)
                .foregroundStyle(store.phase == .on ? Color.accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bouncer").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
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
        var parts = [state, "\(blockCount) block rule\(blockCount == 1 ? "" : "s")"]
        if let hotkeyDisplay { parts.append(hotkeyDisplay) }
        return parts.joined(separator: " · ")
    }

    private var hotkeyDisplay: String? { HotkeyChord(configuration.configuration.hotkey)?.displayString }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("reddit.com, *.example.com, or /regex/", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(addRule)
                Picker("", selection: $draftAction) {
                    Text("Block").tag(FilterRule.Action.block)
                    Text("Allow").tag(FilterRule.Action.allow)
                }
                .labelsHidden()
                .fixedSize()
                Button(action: addRule) { Image(systemName: "plus") }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add rule")
            }
            Text("Domains include subdomains. Wrap a pattern in slashes for a case-insensitive regex. Allow rules win.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var rulesList: some View {
        if store.rules.isEmpty {
            Text("No rules yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.rules) { rule in row(rule) }
                }
            }
            .frame(maxHeight: min(CGFloat(store.rules.count) * 28 + 4, 240))
        }
    }

    private func row(_ rule: FilterRule) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { enabled in
                run { _ = try await service.ruleUpdate(.init(enabled: enabled, id: rule.id.uuidString)) }
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture(count: 2) { beginEdit(rule) }
            }
            Spacer(minLength: 4)
            badge(rule.action == .allow ? "allow" : "block", color: rule.action == .allow ? .green : .red)
            Button {
                run { _ = try await service.ruleRemove(.init(id: rule.id.uuidString)) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove rule")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
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

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recently blocked").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.blockedCount) since launch").font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(store.activity.prefix(5)) { entry in
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(.red)
                    Text(entry.domain).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    if entry.count > 1 { Text("×\(entry.count)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text(entry.lastSeen, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Settings…", action: openSettings)
            Spacer()
            Button("Quit Bouncer  ⌘Q", action: quit)
                .help("Quitting removes all blocks")
        }
        .controlSize(.small)
    }

    // MARK: - Actions

    private func setEnabled(_ enabled: Bool) {
        run {
            if enabled { _ = try await service.blockingOn(.init()) } else { _ = try await service.blockingOff(.init()) }
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

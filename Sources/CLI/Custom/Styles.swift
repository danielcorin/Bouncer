import AutomationCLI
import BouncerCore

/// Human-readable output; `--json` always prints the full typed envelope.
enum BouncerCLIStyles {
    static func install(in environment: CLIEnvironment) {
        environment.render(APIOperations.Status.self) { status in
            "\(status.appName) \(status.version) (pid \(status.processIdentifier))\n" + blocking(status.blocking)
        }
        for operation in [APIOperations.BlockingOn.self, APIOperations.BlockingOff.self, APIOperations.BlockingToggle.self,
                          APIOperations.HelperInstall.self, APIOperations.HelperUninstall.self] as [any BlockingStateOperation.Type] {
            operation.register(in: environment)
        }
        environment.render(APIOperations.RuleList.self) { list in
            list.rules.isEmpty ? "No rules. Add one with: bouncer rules add reddit.com" : list.rules.map(rule).joined(separator: "\n")
        }
        environment.render(APIOperations.RuleAdd.self) { "Added " + rule($0) }
        environment.render(APIOperations.RuleUpdate.self) { "Updated " + rule($0) }
        environment.render(APIOperations.RuleRemove.self) { "Removed " + rule($0) }
        environment.render(APIOperations.RuleTest.self) { test in
            switch test.decision {
            case .blocked: "\(test.domain): blocked by \(test.rule.map(rule) ?? "a rule")"
            case .allowed: "\(test.domain): allowed by \(test.rule.map(rule) ?? "a rule")"
            case .unmatched: "\(test.domain): no rule matches"
            }
        }
        environment.render(APIOperations.ActivityList.self) { activity in
            let lines = activity.events.map { event in
                "\(event.at)  \(event.domain)\(event.count > 1 ? " ×\(event.count)" : "")  (\(event.rulePattern))"
            }
            return (lines.isEmpty ? ["Nothing blocked yet."] : lines).joined(separator: "\n") + "\n\(activity.blockedCount) blocked since launch"
        }
    }

    static func blocking(_ state: APIData.BlockingState) -> String {
        var lines = ["Blocking: \(state.phase.rawValue)\(state.enabled && state.phase != .on ? " (requested on)" : "")",
                     "Rules: \(state.ruleCount) · blocked lookups since launch: \(state.blockedCount)",
                     "Hotkey: \(HotkeyChord(state.hotkey)?.displayString ?? "none")",
                     "Helper: \(state.helper.installed ? (state.helper.upToDate ? "installed" : "installed, update pending") : "not installed")\(state.helper.connected ? ", connected" : "")"]
        if let message = state.message { lines.append(message) }
        return lines.joined(separator: "\n")
    }

    static func rule(_ rule: APIData.Rule) -> String {
        let pattern = rule.kind == .regex ? "/\(rule.pattern)/" : rule.pattern
        return "\(rule.id.prefix(8))  \(rule.action.rawValue)  \(pattern)\(rule.enabled ? "" : "  (disabled)")"
    }
}

/// Every lifecycle command returns `BlockingState`; register one renderer for all.
protocol BlockingStateOperation: AutomationOperation where Output == APIData.BlockingState {}
extension BlockingStateOperation {
    static func register(in environment: CLIEnvironment) {
        environment.render(Self.self) { BouncerCLIStyles.blocking($0) }
    }
}
extension APIOperations.BlockingOn: BlockingStateOperation {}
extension APIOperations.BlockingOff: BlockingStateOperation {}
extension APIOperations.BlockingToggle: BlockingStateOperation {}
extension APIOperations.HelperInstall: BlockingStateOperation {}
extension APIOperations.HelperUninstall: BlockingStateOperation {}

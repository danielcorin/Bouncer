import Foundation
import AutomationRuntime
import BouncerCore

/// Add a typed scenario here with each new operation. The coverage gate fails
/// for missing IDs; every assertion runs through direct Swift and the CLI.
/// Steps run in order against a fresh fixture whose tunnel is in-memory.
@MainActor
func appScenarios(application: any ApplicationOperations, configuration: ConfigurationOperationService, transfers: TransferStore) throws -> ScenarioSuite {
    let steps: [ScenarioStep] = [
        .init(APIOperations.Status.self, input: { .init() }) { value in
            try require(value["appName"] == .string("Bouncer fixture"), "Application identity")
            try require(value["blocking"]["enabled"] == .bool(false) && value["blocking"]["phase"] == .string("off"), "Blocking starts off")
            try require(value["blocking"]["hotkey"] == .string("ctrl+option+cmd+b"), "Default hotkey")
        },
        .init(APIOperations.Show.self, error: "capability_unavailable", input: { .init() }) { _ in },
        .init(APIOperations.Quit.self, error: "capability_unavailable", input: { .init() }) { _ in },

        // Configuration
        .init(APIOperations.ConfigList.self, input: { .init(all: true) }) { value in
            try require(value["entries"].elements.count == 6, "All configuration keys")
        },
        .init(APIOperations.ConfigSet.self, input: { .init(key: "flash-indicator", value: "false") }) { value in
            try require(value["value"] == .bool(false), "Set preference")
        },
        .init(APIOperations.ConfigGet.self, input: { .init(key: "flash-indicator") }) { value in
            try require(value["value"] == .bool(false) && value["source"] == .string("user"), "Read saved preference")
        },
        .init(APIOperations.ConfigSet.self, input: { .init(key: "hotkey", value: "Cmd+Shift+F12") }) { value in
            try require(value["value"] == .string("shift+cmd+f12"), "Hotkeys are stored canonically")
        },
        .init(APIOperations.ConfigSet.self, error: "invalid_input", input: { .init(key: "hotkey", value: "shift+b") }) { _ in },
        .init(APIOperations.ConfigSet.self, error: "invalid_input", input: { .init(key: "upstream-dns", value: "1.1.1.1, dns.google") }) { _ in },
        .init(APIOperations.ConfigValidate.self, input: { .init(content: "upstream-dns = \"9.9.9.9,2620:fe::fe\"") }) { value in
            try require(value["valid"] == .bool(true), "Validate TOML")
        },
        .init(APIOperations.ConfigValidate.self, error: "invalid_input", input: { .init(content: "flash-indicator = 7") }) { _ in },
        .init(APIOperations.ConfigReload.self, input: { .init() }) { value in
            try require(value["valid"] == .bool(true), "Reload valid settings")
        },
        .init(APIOperations.ConfigUnset.self, input: { .init(key: "flash-indicator") }) { value in
            try require(value["value"] == .bool(true), "Restore preference default")
        },
        .init(APIOperations.ConfigUnset.self, input: { .init(key: "hotkey") }) { value in
            try require(value["value"] == .string("ctrl+option+cmd+b"), "Restore hotkey default")
        },
        .init(APIOperations.ConfigGet.self, input: { .init(key: "restart-browser") }) { value in
            try require(value["value"] == .string("ask") && value["source"] == .string("defaults"), "Restart prompt is the default")
        },
        .init(APIOperations.ConfigSet.self, input: { .init(key: "restart-browser", value: "Always") }) { value in
            try require(value["value"] == .string("always"), "Restart mode is stored lowercase")
        },
        .init(APIOperations.ConfigSet.self, error: "invalid_input", input: { .init(key: "restart-browser", value: "sometimes") }) { _ in },
        .init(APIOperations.ConfigUnset.self, input: { .init(key: "restart-browser") }) { value in
            try require(value["value"] == .string("ask"), "Restore restart default")
        },

        // Rules
        .init(APIOperations.RuleList.self, input: { .init() }) { value in
            try require(value["rules"].elements.isEmpty, "No rules initially")
        },
        .init(APIOperations.RuleAdd.self, input: { .init(pattern: "https://Example.COM/some/page") }) { value in
            try require(value["pattern"] == .string("example.com") && value["kind"] == .string("domain") && value["action"] == .string("block"),
                        "URLs reduce to a lowercase domain block rule")
        },
        .init(APIOperations.RuleAdd.self, input: { .init(pattern: "/^news\\.ycombinator\\.com$/") }) { value in
            try require(value["pattern"] == .string("^news\\.ycombinator\\.com$") && value["kind"] == .string("regex"), "Slashed input becomes a regex")
        },
        .init(APIOperations.RuleAdd.self, input: { .init(action: "allow", pattern: "ok.example.com") }) { value in
            try require(value["action"] == .string("allow") && value["enabled"] == .bool(true), "Allow rule")
        },
        .init(APIOperations.RuleAdd.self, error: "invalid_input", input: { .init(pattern: "bad..domain") }) { _ in },
        .init(APIOperations.RuleAdd.self, error: "invalid_input", input: { .init(kind: "regex", pattern: "([") }) { _ in },
        .init(APIOperations.RuleAdd.self, error: "invalid_input", input: { .init(action: "deny", pattern: "x.com") }) { _ in },
        .init(APIOperations.RuleTest.self, input: { .init(domain: "WWW.example.com.") }) { value in
            try require(value["domain"] == .string("www.example.com") && value["decision"] == .string("blocked")
                        && value["rule"]["pattern"] == .string("example.com"), "Subdomains of a domain rule are blocked")
        },
        .init(APIOperations.RuleTest.self, input: { .init(domain: "ok.example.com") }) { value in
            try require(value["decision"] == .string("allowed"), "Allow rules override block rules")
        },
        .init(APIOperations.RuleTest.self, input: { .init(domain: "notexample.com") }) { value in
            try require(value["decision"] == .string("unmatched") && value["rule"] == .null, "Domain rules match on label boundaries")
        },
        .init(APIOperations.RuleUpdate.self, input: { .init(enabled: false, id: "ok.example.com") }) { value in
            try require(value["enabled"] == .bool(false) && value["pattern"] == .string("ok.example.com"), "Disable a rule by pattern")
        },
        .init(APIOperations.RuleTest.self, input: { .init(domain: "ok.example.com") }) { value in
            try require(value["decision"] == .string("blocked"), "Disabled allow rules no longer apply")
        },
        .init(APIOperations.RuleUpdate.self, error: "not_found", input: { .init(enabled: true, id: "nothing.invalid") }) { _ in },

        // Blocking lifecycle (the fixture's in-memory tunnel installs on first use)
        .init(APIOperations.BlockingOn.self, input: { .init() }) { value in
            try require(value["enabled"] == .bool(true) && value["phase"] == .string("on"), "Blocking turns on")
            try require(value["tunnel"]["installed"] == .bool(true) && value["tunnel"]["connected"] == .bool(true), "Tunnel installed on demand")
            try require(value["ruleCount"] == .integer(3), "Rule count")
        },
        .init(APIOperations.ActivityList.self, input: { .init(limit: 10) }) { value in
            let domains = value["events"].elements.compactMap { $0["domain"].string }
            try require(Set(domains) == ["example.com", "www.example.com", "ok.example.com", "news.ycombinator.com"], "Only blocked lookups are recorded")
            try require(value["blockedCount"] == .integer(4), "Blocked lookup count")
            try require(value["events"].elements.first?["domain"] == .string("news.ycombinator.com"), "Most recent first")
        },
        .init(APIOperations.ActivityList.self, error: "invalid_input", input: { .init(limit: 0) }) { _ in },
        // The activation probes above: three example.com lookups (one attempt) and news.ycombinator.com (regex → ycombinator.com).
        .init(APIOperations.StatsShow.self, input: { .init(days: 1) }) { value in
            let today = value["days"].elements.first
            try require(value["days"].elements.count == 1 && today?["date"] == .string(DenialStatsStore.dayKey(for: Date())), "Today only")
            let sites = today?["sites"].elements ?? []
            try require(sites.compactMap { $0["site"].string } == ["example.com", "ycombinator.com"], "Sites ranked, named by rule or main domain")
            try require(sites.first?["attempts"] == .integer(1) && sites.first?["lookups"] == .integer(3), "A burst of lookups is one attempt")
            try require(value["todayAttempts"] == .integer(2) && value["totalAttempts"] == .integer(2), "Totals")
        },
        .init(APIOperations.StatsShow.self, input: { .init(days: 7) }) { value in
            try require(value["days"].elements.count == 7, "Empty days are included")
            try require(value["days"].elements.first?["date"] == .string(DenialStatsStore.dayKey(for: Date())), "Newest first")
        },
        .init(APIOperations.StatsShow.self, error: "invalid_input", input: { .init(date: "13/10/2026") }) { _ in },
        .init(APIOperations.StatsShow.self, error: "invalid_input", input: { .init(days: 0) }) { _ in },
        .init(APIOperations.BlockingToggle.self, input: { .init() }) { value in
            try require(value["enabled"] == .bool(false) && value["phase"] == .string("off"), "Toggle turns blocking off")
        },
        .init(APIOperations.BlockingToggle.self, input: { .init() }) { value in
            try require(value["enabled"] == .bool(true) && value["phase"] == .string("on"), "Toggle turns blocking back on")
        },
        .init(APIOperations.BlockingOff.self, input: { .init() }) { value in
            try require(value["enabled"] == .bool(false) && value["phase"] == .string("off"), "Blocking turns off")
        },
        .init(APIOperations.BlockingOff.self, input: { .init() }) { value in
            try require(value["tunnel"]["connected"] == .bool(false), "The tunnel stops with blocking")
        },
        .init(APIOperations.TunnelInstall.self, input: { .init() }) { value in
            try require(value["tunnel"]["installed"] == .bool(true) && value["enabled"] == .bool(false), "Reinstalling leaves blocking off")
        },
        .init(APIOperations.TunnelRemove.self, error: "force_required", input: { .init(force: false) }) { _ in },
        .init(APIOperations.TunnelRemove.self, input: { .init(force: true) }) { value in
            try require(value["tunnel"]["installed"] == .bool(false) && value["enabled"] == .bool(false), "Tunnel configuration removed")
        },
        .init(APIOperations.BrowserRestart.self, error: "force_required", input: { .init(force: false) }) { _ in },
        .init(APIOperations.BrowserRestart.self, input: { .init(force: true) }) { value in
            try require(value["restarted"] == .bool(true) && value["browser"] == .string("Fixture Browser"), "Default browser restarted")
            try require(value["restoresTabs"] == .bool(true), "Chromium browsers come back with their tabs")
        },
        .init(APIOperations.RuleRemove.self, input: { .init(id: "example.com") }) { value in
            try require(value["pattern"] == .string("example.com"), "Removed rule is returned")
        },
        .init(APIOperations.RuleRemove.self, error: "not_found", input: { .init(id: "example.com") }) { _ in },
        .init(APIOperations.RuleList.self, input: { .init() }) { value in
            try require(value["rules"].elements.compactMap { $0["pattern"].string } == ["^news\\.ycombinator\\.com$", "ok.example.com"], "Remaining rules keep their order")
        },
        .init(APIOperations.StatsClear.self, error: "force_required", input: { .init(force: false) }) { _ in },
        .init(APIOperations.StatsClear.self, input: { .init(force: true) }) { value in
            try require(value["totalAttempts"] == .integer(0) && value["days"].elements.first?["sites"].elements.isEmpty == true, "Stats cleared")
        },
    ]
    return try ScenarioSuite(steps: steps, application: application, configuration: configuration, transfers: transfers,
                             normalize: { MacAutomationErrors.normalize($0) })
}

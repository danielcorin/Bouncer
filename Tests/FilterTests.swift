import XCTest
@testable import BouncerCore

final class RuleMatcherTests: XCTestCase {
    private func rule(_ pattern: String, _ kind: FilterRule.Kind = .domain, _ action: FilterRule.Action = .block, enabled: Bool = true) -> FilterRule {
        FilterRule(pattern: pattern, kind: kind, action: action, enabled: enabled)
    }

    func testDomainRulesMatchTheNameAndSubdomainsOnLabelBoundaries() {
        let matcher = RuleMatcher(rules: [rule("reddit.com")])
        XCTAssertTrue(matcher.evaluate("reddit.com").isBlocked)
        XCTAssertTrue(matcher.evaluate("old.reddit.com").isBlocked)
        XCTAssertTrue(matcher.evaluate("A.B.REDDIT.COM.").isBlocked)
        XCTAssertFalse(matcher.evaluate("notreddit.com").isBlocked)
        XCTAssertFalse(matcher.evaluate("reddit.com.evil.net").isBlocked)
    }

    func testWildcardDomainsMatchSubdomainsOnly() {
        let matcher = RuleMatcher(rules: [rule("*.example.com")])
        XCTAssertFalse(matcher.evaluate("example.com").isBlocked)
        XCTAssertTrue(matcher.evaluate("www.example.com").isBlocked)
    }

    func testRegexRulesAreCaseInsensitiveAndUnanchored() {
        let matcher = RuleMatcher(rules: [rule("news|tiktok", .regex), rule("^x\\.com$", .regex)])
        XCTAssertTrue(matcher.evaluate("hackerNEWS.ycombinator.com").isBlocked)
        XCTAssertTrue(matcher.evaluate("www.tiktok.com").isBlocked)
        XCTAssertTrue(matcher.evaluate("x.com").isBlocked)
        XCTAssertFalse(matcher.evaluate("api.x.com").isBlocked)
        XCTAssertFalse(matcher.evaluate("apple.com").isBlocked)
    }

    func testAllowRulesWinRegardlessOfOrder() {
        let allow = rule("music.youtube.com", .domain, .allow)
        let matcher = RuleMatcher(rules: [rule(".*", .regex), allow])
        XCTAssertEqual(matcher.evaluate("music.youtube.com"), .allowed(allow))
        XCTAssertTrue(matcher.evaluate("youtube.com").isBlocked)
    }

    func testDisabledAndInvalidRulesAreIgnored() {
        let matcher = RuleMatcher(rules: [rule("a.com", enabled: false), rule("([", .regex)])
        XCTAssertEqual(matcher.evaluate("a.com"), .unmatched)
        XCTAssertTrue(matcher.isEmpty)
    }

    func testPatternParsing() throws {
        XCTAssertEqual(try FilterPattern.parse(" https://WWW.Reddit.com:443/r/x?y ", kind: nil).pattern, "www.reddit.com")
        XCTAssertEqual(try FilterPattern.parse("reddit.com/r/swift", kind: nil).pattern, "reddit.com")
        XCTAssertEqual(try FilterPattern.parse("*.Example.com.", kind: nil).pattern, "*.example.com")
        XCTAssertEqual(try FilterPattern.parse("/^a+$/", kind: nil).kind, .regex)
        XCTAssertEqual(try FilterPattern.parse("/^a+$/", kind: nil).pattern, "^a+$")
        XCTAssertEqual(try FilterPattern.parse("^a+$", kind: .regex).pattern, "^a+$")
        XCTAssertThrowsError(try FilterPattern.parse("", kind: nil))
        XCTAssertThrowsError(try FilterPattern.parse("-bad.com", kind: nil))
        XCTAssertThrowsError(try FilterPattern.parse("a b.com", kind: nil))
        XCTAssertThrowsError(try FilterPattern.parse("//", kind: nil))
        XCTAssertThrowsError(try FilterPattern.parse("/(/", kind: nil))
        XCTAssertThrowsError(try FilterPattern.kind("glob"))
        XCTAssertNil(try FilterPattern.kind("auto"))
        XCTAssertEqual(try FilterPattern.action("ALLOW"), .allow)
    }
}

final class DNSFilterEngineTests: XCTestCase {
    private func query(_ name: String, type: UInt16 = 1) -> [UInt8] {
        var packet: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { packet += [UInt8(label.utf8.count)] + Array(label.utf8) }
        return packet + [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
    }

    func testBlocksMatchesAndRecordsTheRule() throws {
        let rule = FilterRule(pattern: "tiktok", kind: .regex)
        let engine = DNSFilterEngine(matcher: RuleMatcher(rules: [rule]), blockCanaries: true)
        guard case .respond(let response, let blocked) = engine.process(query("www.TikTok.com")) else { return XCTFail("Expected a local answer") }
        XCTAssertEqual(DNSPacket.responseCode(response), 3)
        XCTAssertEqual(blocked?.domain, "www.tiktok.com")
        XCTAssertEqual(blocked?.ruleID, rule.id)
    }

    func testForwardsEverythingElseAndAnswersSelfTestsAndCanaries() throws {
        let engine = DNSFilterEngine(matcher: .empty, blockCanaries: true)
        guard case .forward(let question) = engine.process(query("apple.com")) else { return XCTFail("Expected forwarding") }
        XCTAssertEqual(question?.name, "apple.com")
        guard case .respond(let selfTest, nil) = engine.process(query("abc123." + TunnelConstants.selfTestSuffix)) else { return XCTFail("Self-test") }
        XCTAssertEqual(Array(selfTest.suffix(4)), TunnelConstants.selfTestAddress)
        guard case .respond(let canary, nil) = engine.process(query("use-application-dns.net")) else { return XCTFail("Canary") }
        XCTAssertEqual(DNSPacket.responseCode(canary), 3)
        let permissive = DNSFilterEngine(matcher: .empty, blockCanaries: false)
        guard case .forward = permissive.process(query("use-application-dns.net")) else { return XCTFail("Canary blocking is optional") }
        guard case .forward(nil) = engine.process([1, 2, 3]) else { return XCTFail("Malformed packets are forwarded untouched") }
    }

    func testUDPDatagramRoundTrip() throws {
        let original = UDPDatagram(source: [198, 18, 0, 2], destination: TunnelConstants.dnsServerBytes, sourcePort: 50_000, destinationPort: 53, payload: query("a.com"))
        // Build the client's packet by replying from the opposite side, then parse it.
        let mirrored = UDPDatagram(source: original.destination, destination: original.source, sourcePort: 53, destinationPort: 50_000, payload: [])
        let packet = mirrored.reply(payload: original.payload)
        let parsed = try XCTUnwrap(UDPDatagram(ipv4: packet))
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(UDPDatagram.checksum(Array(packet[0..<20])), 0, "Valid IPv4 header checksum")
        let reply = parsed.reply(payload: [9, 9])
        XCTAssertEqual(Array(reply[12..<16]), TunnelConstants.dnsServerBytes, "Reply comes from the tunnel resolver")
        XCTAssertEqual(Array(reply[20..<24]), [0, 53, 0xC3, 0x50], "Ports swapped")
        var fragment = packet
        fragment[6] = 0x20 // more fragments
        XCTAssertNil(UDPDatagram(ipv4: fragment))
    }
}

final class DNSPacketTests: XCTestCase {
    /// dig-style query for www.Example.com A with RD set and an EDNS OPT record.
    private let query: [UInt8] = [
        0xAB, 0xCD, 0x01, 0x20, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        3, 0x77, 0x77, 0x77, 7, 0x45, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 3, 0x63, 0x6F, 0x6D, 0,
        0x00, 0x01, 0x00, 0x01,
        0x00, 0x00, 0x29, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    func testParsesTheFirstQuestion() throws {
        let question = try XCTUnwrap(DNSPacket.parseQuestion(query))
        XCTAssertEqual(question.id, 0xABCD)
        XCTAssertEqual(question.name, "www.example.com")
        XCTAssertEqual(question.type, 1)
        XCTAssertEqual(question.questionEnd, 33)
    }

    func testRejectsResponsesAndMalformedPackets() {
        var response = query
        response[2] |= 0x80
        XCTAssertNil(DNSPacket.parseQuestion(response))
        XCTAssertNil(DNSPacket.parseQuestion(Array(query.prefix(20))))
        var compressed = query
        compressed[12] = 0xC0
        XCTAssertNil(DNSPacket.parseQuestion(compressed))
    }

    func testBlockedResponseIsAnUncacheableNXDOMAIN() throws {
        let question = try XCTUnwrap(DNSPacket.parseQuestion(query))
        let response = DNSPacket.blockedResponse(to: query, question: question)
        XCTAssertEqual(Array(response[0..<2]), [0xAB, 0xCD], "ID echoed")
        XCTAssertEqual(response[2] & 0x80, 0x80, "QR set")
        XCTAssertEqual(response[2] & 0x01, 0x01, "RD echoed")
        XCTAssertEqual(DNSPacket.responseCode(response), 3, "NXDOMAIN")
        XCTAssertEqual(Array(response[4..<12]), [0, 1, 0, 0, 0, 1, 0, 0], "1 question, 1 authority, no OPT")
        XCTAssertEqual(Array(response[12..<33]), Array(query[12..<33]), "Question copied")
        let soa = Array(response[33...])
        XCTAssertEqual(Array(soa[0..<6]), [0xC0, 0x0C, 0x00, 0x06, 0x00, 0x01])
        XCTAssertEqual(Array(soa[6..<10]), [0, 0, 0, 0], "Zero TTL")
        XCTAssertEqual(soa.count, 10 + 2 + 22)
        XCTAssertEqual(Array(soa.suffix(4)), [0, 0, 0, 0], "Zero negative-cache minimum")
    }

    func testSelfTestAnswerIsAnUncacheableARecord() throws {
        let question = try XCTUnwrap(DNSPacket.parseQuestion(query))
        let response = DNSPacket.addressResponse(to: query, question: question, ipv4: [127, 0, 0, 53])
        XCTAssertEqual(DNSPacket.responseCode(response), 0)
        XCTAssertEqual(Array(response[6..<8]), [0, 1], "One answer")
        XCTAssertEqual(Array(response.suffix(16)), [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 0, 0, 4, 127, 0, 0, 53])
        var aaaa = query
        aaaa[30] = 28
        let nodata = DNSPacket.addressResponse(to: aaaa, question: try XCTUnwrap(DNSPacket.parseQuestion(aaaa)), ipv4: [127, 0, 0, 53])
        XCTAssertEqual(Array(nodata[6..<8]), [0, 0], "AAAA gets NODATA")
    }

    func testFailureResponseIsServfail() throws {
        let question = try XCTUnwrap(DNSPacket.parseQuestion(query))
        let response = DNSPacket.failureResponse(to: query, question: question)
        XCTAssertEqual(DNSPacket.responseCode(response), 2)
        XCTAssertEqual(response.count, 33)
    }
}

final class HotkeyChordTests: XCTestCase {
    func testParsesAndCanonicalizes() throws {
        let chord = try XCTUnwrap(HotkeyChord("Cmd + Opt + Control + B"))
        XCTAssertEqual(chord.description, "ctrl+option+cmd+b")
        XCTAssertEqual(chord.displayString, "⌃⌥⌘B")
        XCTAssertEqual(chord.keyCode, 11)
        XCTAssertEqual(HotkeyChord("shift+cmd+f12")?.displayString, "⇧⌘F12")
        XCTAssertEqual(HotkeyChord(chord.description), chord)
    }

    func testRequiresANonShiftModifierAndAKnownKey() {
        XCTAssertNil(HotkeyChord("b"))
        XCTAssertNil(HotkeyChord("shift+b"))
        XCTAssertNil(HotkeyChord("cmd+hyper"))
        XCTAssertNil(HotkeyChord("super+b"))
        XCTAssertNil(HotkeyChord(keyCode: 999, modifiers: [.command]))
    }

    func testConfigurationStoresCanonicalHotkeysAndUpstreams() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppConfigurationStore(fileURL: root.appendingPathComponent("config.toml"))
        XCTAssertEqual(try store.set(.hotkey, value: "opt+cmd+k").hotkey, "option+cmd+k")
        XCTAssertEqual(try store.set(.hotkey, value: "").hotkey, "")
        XCTAssertThrowsError(try store.set(.hotkey, value: "k"))
        XCTAssertEqual(try store.set(.upstreamDNS, value: "9.9.9.9, 2620:fe::fe").upstreamDNS, ["9.9.9.9", "2620:fe::fe"])
        XCTAssertThrowsError(try store.set(.upstreamDNS, value: "dns.quad9.net"))
        XCTAssertEqual(try store.load().filterOptions, FilterOptions(blockBypassCanaries: true, upstreamServers: ["9.9.9.9", "2620:fe::fe"]))
    }

    func testTunnelProtocolRoundTrips() throws {
        let rule = FilterRule(pattern: "a.com", kind: .domain)
        let configuration = TunnelConfiguration(rules: [rule], options: .init(blockBypassCanaries: false, upstreamServers: ["1.1.1.1"]), upstream: ["192.168.1.1"])
        let request = try TunnelCoding.decode(TunnelRequest.self, from: TunnelCoding.encode(TunnelRequest(configuration: configuration, eventsAfter: 4)))
        XCTAssertEqual(request.configuration, configuration)
        XCTAssertEqual(request.eventsAfter, 4)
        let lookup = BlockedLookup(domain: "a.com", ruleID: rule.id, rulePattern: "a.com", date: Date(timeIntervalSince1970: 1_700_000_000))
        let reply = try TunnelCoding.decode(TunnelReply.self, from: TunnelCoding.encode(TunnelReply(events: [.init(sequence: 5, lookup: lookup)], lastSequence: 5, stats: .init())))
        XCTAssertEqual(reply.events.first?.lookup, lookup)
    }

}

@MainActor
final class BlockingStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(_ backend: InMemoryFilterBackend) -> BlockingStore {
        BlockingStore(rulesURL: root.appendingPathComponent("rules.json"), backend: backend)
    }

    func testRulesPersistAndReachTheActiveFilter() async throws {
        let backend = InMemoryFilterBackend()
        let store = makeStore(backend)
        _ = try await store.addRule(pattern: "a.com", kind: nil, action: nil)
        try await store.setEnabled(true)
        XCTAssertEqual(backend.activeRules?.map(\.pattern), ["a.com"])
        let regex = try await store.addRule(pattern: "/^b/", kind: nil, action: nil)
        XCTAssertEqual(backend.activeRules?.map(\.pattern), ["a.com", "^b"], "Edits apply live while blocking")
        let duplicate = try await store.addRule(pattern: "/^b/", kind: nil, action: nil)
        XCTAssertEqual(duplicate.id, regex.id, "Adding the same rule twice is idempotent")
        XCTAssertEqual(makeStore(InMemoryFilterBackend()).rules.map(\.pattern), ["a.com", "^b"], "Rules reload from disk")
    }

    func testCanceledHelperInstallLeavesBlockingOff() async throws {
        let backend = InMemoryFilterBackend()
        backend.installFailure = FilterBackendError("canceled", "The administrator prompt was canceled.")
        let store = makeStore(backend)
        do {
            try await store.setEnabled(true)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual((error as? FilterBackendError)?.code, "canceled")
        }
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.message, "The administrator prompt was canceled.")
        XCTAssertFalse(backend.isActive)
    }

    func testExternalDisconnectTurnsBlockingOffInsteadOfFighting() async throws {
        let backend = InMemoryFilterBackend()
        let store = makeStore(backend)
        try await store.setEnabled(true)
        backend.simulateDisconnect()
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(store.phase, .failed)
        XCTAssertEqual(store.message, "The DNS tunnel was disconnected.")
        try await store.setEnabled(true)
        XCTAssertEqual(store.phase, .on, "Turning blocking back on recovers")
    }

    func testDetectsWhenSystemLookupsBypassTheFilter() async throws {
        let backend = InMemoryFilterBackend()
        backend.systemResolutionReachesFilter = false
        let store = makeStore(backend)
        store.verificationDelays = [.milliseconds(10), .milliseconds(10)]
        try await store.setEnabled(true)
        for _ in 0..<40 where store.dnsVerified == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.dnsVerified, false)
        XCTAssertEqual(store.message, BlockingStore.bypassWarning)
        try await store.setEnabled(false)
        XCTAssertNil(store.dnsVerified)
        XCTAssertNil(store.message, "Turning off clears the warning")

        backend.systemResolutionReachesFilter = true
        try await store.setEnabled(true)
        for _ in 0..<40 where store.dnsVerified == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.dnsVerified, true)
        XCTAssertNil(store.message)
    }

    func testDisconnectWhileOffDoesNothing() async throws {
        let backend = InMemoryFilterBackend()
        let store = makeStore(backend)
        try await store.setEnabled(true)
        try await store.setEnabled(false)
        backend.simulateDisconnect()
        XCTAssertEqual(store.phase, .off)
    }

    func testShutdownAlwaysTearsDown() async throws {
        let backend = InMemoryFilterBackend()
        let store = makeStore(backend)
        try await store.setEnabled(true)
        store.shutdown()
        XCTAssertEqual(backend.exitTeardowns, 1)
        XCTAssertFalse(backend.isActive)
        XCTAssertEqual(store.phase, .off)
    }

    func testRapidTogglesSettleInOrder() async throws {
        let backend = InMemoryFilterBackend()
        let store = makeStore(backend)
        // Issue the requests in a known order (as hotkey presses arrive on the main
        // actor) without waiting for each to finish; they must apply in that order.
        let requests = [true, false, true].map { enabled in
            Task { @MainActor in try await store.setEnabled(enabled) }
        }
        for request in requests { try await request.value }
        XCTAssertTrue(store.isEnabled)
        XCTAssertEqual(store.phase, .on)
        XCTAssertTrue(backend.isActive)
        XCTAssertEqual(backend.installCount, 1)
    }

    func testActivityCoalescesByDomainAndPublishesForTheIndicator() async throws {
        let backend = InMemoryFilterBackend()
        let store = makeStore(backend)
        _ = try await store.addRule(pattern: "a.com", kind: nil, action: nil)
        try await store.setEnabled(true)
        var flashed: [String] = []
        let subscription = store.blocks.sink { flashed.append($0.domain) }
        backend.simulateLookup("a.com")
        backend.simulateLookup("b.a.com")
        backend.simulateLookup("a.com")
        backend.simulateLookup("unrelated.org")
        subscription.cancel()
        XCTAssertEqual(flashed, ["a.com", "b.a.com", "a.com"])
        XCTAssertEqual(store.activity.map(\.domain), ["a.com", "b.a.com"])
        XCTAssertEqual(store.activity.first?.count, 2)
        XCTAssertEqual(store.blockedCount, 3)
    }

    func testServiceAppliesConfigurationToTheActiveFilter() async throws {
        let backend = InMemoryFilterBackend()
        let store = makeStore(backend)
        try await store.setEnabled(true)
        let service = BouncerService(store: store, shell: TestShell())
        await service.applyConfiguration(AppConfiguration(blockBypassCanaries: false, upstreamDNS: ["9.9.9.9"]))
        XCTAssertEqual(backend.activeOptions, FilterOptions(blockBypassCanaries: false, upstreamServers: ["9.9.9.9"]))
        let state = try await service.status(.init()).blocking
        XCTAssertEqual(state.phase, .on)
        XCTAssertEqual(state.hotkey, "ctrl+option+cmd+b")
    }
}

@MainActor
private final class TestShell: AppShell {
    let appName = "Test"
    let version = "0"
    let isFrontmost = false
    func show() throws -> String { "shown" }
    func quit() throws -> String { "quit" }
}

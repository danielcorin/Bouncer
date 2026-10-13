import AppKit
import BouncerCore
import Charts
import SwiftUI

@MainActor
final class StatsWindowController {
    private let window: NSWindow

    init(store: BlockingStore, service: BouncerService) {
        window = NSWindow(contentViewController: NSHostingController(rootView: StatsView(stats: store.stats, service: service)))
        window.title = "Bouncer Stats"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }
}

extension Color {
    /// The chart fill: the brand teal stepped to pass the dataviz palette checks
    /// (lightness band, chroma floor, 3:1 contrast) on each surface.
    static let bouncerChart = Color(nsColor: NSColor(name: "BouncerChart") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1F / 255, green: 0xA3 / 255, blue: 0x96 / 255, alpha: 1)  // #1FA396
            : NSColor(srgbRed: 0x00 / 255, green: 0x8F / 255, blue: 0x88 / 255, alpha: 1)  // #008F88
    })
}

struct StatsView: View {
    @ObservedObject var stats: DenialStatsStore
    let service: BouncerService

    @State private var selectedKey = DenialStatsStore.dayKey(for: Date())
    @State private var hoveredKey: String?
    @State private var confirmClear = false

    private static let chartDays = 14
    private var todayKey: String { DenialStatsStore.dayKey(for: Date()) }
    private var recent: [DayDenials] { stats.recentDays(Self.chartDays, endingOn: Date()) }
    private var selected: DayDenials { stats.day(selectedKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            tiles
            chartSection
            Divider()
            daySection
            footer
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .tint(.bouncer)
        .confirmationDialog("Delete all Bouncer stats?", isPresented: $confirmClear) {
            Button("Delete Stats", role: .destructive) {
                Task { _ = try? await service.statsClear(.init(force: true)) }
            }
        } message: {
            Text("This removes every recorded day. Your rules aren't affected.")
        }
    }

    // MARK: - Totals

    private var tiles: some View {
        HStack(spacing: 12) {
            tile("Today", stats.day(todayKey).attempts)
            tile("Last 7 days", stats.recentDays(7, endingOn: Date()).reduce(0) { $0 + $1.attempts })
            tile("All time", stats.totalAttempts)
        }
    }

    private func tile(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(value == 1 ? "denial" : "denials").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Denials per day, last \(Self.chartDays) days")
                .font(.headline)
            // One category per day keeps every label exactly under its bar.
            Chart(recent) { day in
                BarMark(x: .value("Day", day.date), y: .value("Denials", day.attempts), width: .ratio(0.72))
                    .cornerRadius(3)
                    .foregroundStyle(Color.bouncerChart.opacity(day.date == selectedKey ? 1 : 0.55))
                if day.date == hoveredKey {
                    RuleMark(x: .value("Day", day.date))
                        .foregroundStyle(Color.secondary.opacity(0.2))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            tooltip(day)
                        }
                }
            }
            .chartXAxis {
                // Label every other day, ending on today.
                AxisMarks(values: recent.reversed().enumerated().filter { $0.offset % 2 == 0 }.map(\.element.date)) { value in
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            Text(dayDate(key), format: .dateTime.month(.abbreviated).day())
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                    AxisValueLabel().foregroundStyle(Color.secondary)
                }
            }
            .chartYScale(domain: 0...max(recent.map(\.attempts).max() ?? 0, 4))
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): hoveredKey = key(at: point, proxy: proxy, geometry: geometry)
                            case .ended: hoveredKey = nil
                            }
                        }
                        .onTapGesture { point in
                            if let key = key(at: point, proxy: proxy, geometry: geometry) { selectedKey = key }
                        }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Denials per day for the last \(Self.chartDays) days")
        }
    }

    private func tooltip(_ day: DayDenials) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dayDate(day.date), format: .dateTime.weekday(.abbreviated).month().day())
                .font(.caption.weight(.semibold))
            Text("\(day.attempts) \(day.attempts == 1 ? "denial" : "denials")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let top = day.ranked.first {
                Text("Most: \(top.site)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private func key(at point: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = point.x - geometry[plot].origin.x
        guard let key: String = proxy.value(atX: x) else { return nil }
        return recent.contains { $0.date == key } ? key : nil
    }

    private func dayDate(_ key: String) -> Date {
        // Noon avoids daylight-saving edges when Charts bins by day.
        (DenialStatsStore.date(forKey: key) ?? Date()).addingTimeInterval(12 * 3600)
    }

    // MARK: - Selected day

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Previous day")
                Text(dayTitle)
                    .font(.headline)
                    .frame(minWidth: 150)
                Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(selectedKey >= todayKey)
                    .help("Next day")
                Spacer()
                Text("\(selected.attempts) \(selected.attempts == 1 ? "denial" : "denials")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if selected.sites.isEmpty {
                Text(selectedKey == todayKey ? "Nothing denied yet today." : "Nothing denied on this day.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                let ranked = selected.ranked
                let top = max(ranked.first?.attempts ?? 1, 1)
                VStack(spacing: 7) {
                    ForEach(ranked.prefix(12)) { site in
                        siteRow(site, fraction: Double(site.attempts) / Double(top))
                    }
                    if ranked.count > 12 {
                        Text("and \(ranked.count - 12) more").font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func siteRow(_ site: SiteDenials, fraction: Double) -> some View {
        HStack(spacing: 10) {
            Text(site.site)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 190, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.bouncerChart)
                    .frame(width: max(4, geometry.size.width * fraction), height: 10)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)
            Text("\(site.attempts)")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .help("\(site.attempts) denied attempts (\(site.lookups) blocked lookups), last at \(site.lastDenied.formatted(date: .omitted, time: .shortened))")
    }

    private var dayTitle: String {
        if selectedKey == todayKey { return "Today" }
        guard let date = DenialStatsStore.date(forKey: selectedKey) else { return selectedKey }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    private func shiftDay(_ offset: Int) {
        guard let date = DenialStatsStore.date(forKey: selectedKey),
              let next = Calendar.current.date(byAdding: .day, value: offset, to: date) else { return }
        let key = DenialStatsStore.dayKey(for: next)
        if key <= todayKey { selectedKey = key }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("A denial is one attempt to reach a blocked site; lookups for the same site within \(Int(DenialStatsStore.attemptWindow)) seconds count once. Background lookups, like prefetching, count too.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Clear Stats…") { confirmClear = true }
                .controlSize(.small)
                .disabled(stats.days.isEmpty)
        }
    }
}

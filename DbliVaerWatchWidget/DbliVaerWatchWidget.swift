import SwiftUI
import WidgetKit
import AppIntents

struct WatchWeatherEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetWeatherSnapshot?

    var relevance: TimelineEntryRelevance? {
        guard let snapshot,
              let first = WeatherGlance.nextEvents(
                Planner.statuses(for: snapshot.place, forecast: snapshot.forecast, now: date),
                now: date
              ).first else { return nil }
        let interval = first.eventAt.timeIntervalSince(date)
        guard interval > 0 && interval <= 3 * 3_600 else { return nil }
        return TimelineEntryRelevance(score: 80, duration: max(900, interval))
    }
}

struct WatchWeatherProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchWeatherEntry {
        WatchWeatherEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchWeatherEntry) -> Void) {
        completion(WatchWeatherEntry(date: Date(), snapshot: SharedWidgetData.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWeatherEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedWidgetData.load()
        guard snapshot != nil else {
            let empty = WatchWeatherEntry(date: now, snapshot: nil)
            completion(Timeline(entries: [empty], policy: .after(now.addingTimeInterval(30 * 60))))
            return
        }
        let entries = stride(from: 0, through: 120, by: 15).compactMap { minutes in
            Calendar.current.date(byAdding: .minute, value: minutes, to: now)
        }.map { WatchWeatherEntry(date: $0, snapshot: snapshot) }
        let nextEvent = entries.compactMap { entry -> Date? in
            guard let snapshot = entry.snapshot else { return nil }
            return WeatherGlance.nextEvents(
                Planner.statuses(for: snapshot.place, forecast: snapshot.forecast, now: entry.date),
                now: entry.date
            ).first?.eventAt
        }.min()
        let refreshAt = min(now.addingTimeInterval(30 * 60), nextEvent ?? now.addingTimeInterval(30 * 60))
        completion(Timeline(entries: entries, policy: .after(refreshAt)))
    }
}

private extension View {
    @ViewBuilder
    func widgetContainerBackground(tint: Color) -> some View {
        if #available(watchOS 10.0, *) {
            self.containerBackground(for: .widget) {
                LinearGradient(colors: [tint.opacity(0.30), .black.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        } else {
            self
        }
    }
}

struct WatchWeatherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchWeatherEntry
    private func localized(_ text: String) -> String { entry.snapshot?.localized(text) ?? text }

    private var current: ForecastHour? { entry.snapshot?.forecast.first }
    private var status: WeatherStatus? {
        guard let snapshot = entry.snapshot else { return nil }
        let upcoming = WeatherGlance.nextEvents(
            Planner.statuses(for: snapshot.place, forecast: snapshot.forecast, now: entry.date),
            now: entry.date
        )
        guard !upcoming.isEmpty else { return nil }
        // The small complications always retain the nearest event. Only the
        // rectangular widget rotates, using the existing 15-minute timeline.
        guard family == .accessoryRectangular else { return upcoming.first }
        let slot = Int(entry.date.timeIntervalSince1970 / (15 * 60))
        return upcoming[((slot % upcoming.count) + upcoming.count) % upcoming.count]
    }
    private var icon: String {
        if let status { return status.type.systemImage }
        guard let current else { return "iphone.and.arrow.forward" }
        return CurrentWeatherCondition.resolve(current).systemImage
    }
    private var tint: Color {
        if let status { return status.type.color }
        guard let current else { return .cyan }
        return CurrentWeatherCondition.resolve(current).color
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label(inlineText, systemImage: icon)
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Circle()
                        .trim(from: 0, to: status.map(progress(for:)) ?? 0.2)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2)
                    VStack(spacing: 1) {
                        Text(status.map { WeatherGlance.compactEventLabel(for: $0, languageStyle: entry.snapshot?.languageStyle ?? .bokmal) } ?? temperature)
                            .font(.caption2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(status.map { compactEventTime($0.eventAt) } ?? "")
                            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                }
                .widgetAccentable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(circularAccessibilityLabel)
            case .accessoryCorner:
                Image(systemName: icon)
                    .font(.title3)
                    .widgetAccentable()
                    .widgetLabel { Text(localized(status?.text ?? temperature)) }
            default:
                rectangularView
            }
        }
        .widgetContainerBackground(tint: tint)
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(tint).widgetAccentable()
                Text(entry.snapshot?.place.displayName ?? AppCopy.name(languageStyle: entry.snapshot?.languageStyle ?? .bokmal))
                    .font(.caption.bold()).lineLimit(1).widgetAccentable()
                Spacer(minLength: 0)
                Text(temperature).font(.caption.bold())
            }
            if entry.snapshot != nil {
                Text("Neste 12 timer")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(localized(status?.text ?? "Ingen aktuelle varsler"))
                    .font(.caption)
                    .lineLimit(2)
            } else {
                Text("Åpne appen på iPhone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localized(status?.text ?? temperature))
    }

    private var temperature: String {
        guard let current else { return "--°" }
        return "\(current.temp.formatted(.number.precision(.fractionLength(0))))°"
    }

    private var circularAccessibilityLabel: String {
        guard let status else { return temperature }
        return "\(localized(WeatherGlance.compactEventLabel(for: status, languageStyle: entry.snapshot?.languageStyle ?? .bokmal))), \(compactEventTime(status.eventAt))"
    }

    private func compactEventTime(_ date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(entry.date) / 60))
        if minutes < 60 { return "\(max(1, minutes))m" }
        return "\(minutes / 60)t"
    }

    private func progress(for status: WeatherStatus) -> CGFloat {
        // The ring is a countdown: full at the start of the 12-hour window,
        // shrinking continuously as the event approaches.
        let remaining = max(0, status.eventAt.timeIntervalSince(entry.date))
        return min(1, max(0, CGFloat(remaining / (12 * 3_600))))
    }

    private var inlineText: String {
        if let status {
            let label = localized(WeatherGlance.compactEventLabel(for: status, languageStyle: entry.snapshot?.languageStyle ?? .bokmal))
            return "\(label) \(compactEventTime(status.eventAt))"
        }
        guard let place = entry.snapshot?.place else {
            return AppCopy.name(languageStyle: entry.snapshot?.languageStyle ?? .bokmal)
        }
        return "\(temperature) \(place.nameWithPreposition)"
    }
}

struct DbliVaerWatchWidget: Widget {
    let kind = "DbliVaerWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWeatherProvider()) { entry in
            WatchWeatherWidgetView(entry: entry)
        }
        .configurationDisplayName("D bli Vær!")
        .description("Været og neste relevante varsel.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryCorner, .accessoryRectangular])
    }
}

@available(watchOSApplicationExtension 26.0, *)
struct OpenWatchWeatherIntent: AppIntent {
    static let title: LocalizedStringResource = "Oppdater D bli Vær!"
    static let description = IntentDescription("Åpner Watch-appen og henter siste vær.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(watchOSApplicationExtension 26.0, *)
struct RefreshWeatherControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "DbliVaerRefreshControl") {
            ControlWidgetButton(action: OpenWatchWeatherIntent()) {
                Label("Oppdater vær", systemImage: "arrow.clockwise")
            }
        }
        .displayName("Oppdater vær")
        .description("Åpne D bli Vær! og hent siste prognose.")
    }
}

@main
struct DbliVaerWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        DbliVaerWatchWidget()
        if #available(watchOSApplicationExtension 26.0, *) {
            RefreshWeatherControl()
        }
    }
}

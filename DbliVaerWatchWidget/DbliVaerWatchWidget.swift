import SwiftUI
import WidgetKit
import AppIntents

struct WatchWeatherEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetWeatherSnapshot?

    var relevance: TimelineEntryRelevance? {
        guard let snapshot,
              let first = Planner.statuses(for: snapshot.place, forecast: snapshot.forecast, now: date).first else { return nil }
        let interval = first.eventAt.timeIntervalSince(date)
        guard first.isNow || (interval > 0 && interval <= 3 * 3_600) else { return nil }
        return TimelineEntryRelevance(score: first.isNow ? 100 : 80, duration: max(900, interval))
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
        let entries = stride(from: 0, through: 120, by: 15).compactMap { minutes in
            Calendar.current.date(byAdding: .minute, value: minutes, to: now)
        }.map { WatchWeatherEntry(date: $0, snapshot: SharedWidgetData.load()) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct WatchWeatherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchWeatherEntry

    private var current: ForecastHour? { entry.snapshot?.forecast.first }
    private var status: WeatherStatus? {
        guard let snapshot = entry.snapshot else { return nil }
        let statuses = WeatherGlance.upcoming(
            Planner.statuses(for: snapshot.place, forecast: snapshot.forecast, now: entry.date),
            now: entry.date
        )
        guard !statuses.isEmpty else { return nil }
        // The small complications always retain the nearest event. Only the
        // rectangular widget rotates, using the existing 15-minute timeline.
        guard family == .accessoryRectangular else { return statuses.first }
        let slot = Int(entry.date.timeIntervalSince1970 / (15 * 60))
        return statuses[((slot % statuses.count) + statuses.count) % statuses.count]
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
                    VStack(spacing: 1) {
                        Image(systemName: icon).font(.headline)
                        Text(status.map { $0.isNow ? "Nå" : shortClockLabel($0.eventAt) } ?? temperature)
                            .font(.caption2.bold().monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .widgetAccentable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status?.text ?? temperature)
            case .accessoryCorner:
                Image(systemName: icon)
                    .font(.title3)
                    .widgetAccentable()
                    .widgetLabel { Text(status?.text ?? temperature) }
            default:
                rectangularView
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [tint.opacity(0.30), .black.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).foregroundStyle(tint).widgetAccentable()
                Text(entry.snapshot?.place.displayName ?? AppCopy.name)
                    .font(.caption.bold()).lineLimit(1).widgetAccentable()
                Spacer(minLength: 0)
                Text(temperature).font(.caption.bold())
            }
            if entry.snapshot != nil {
                Text("Neste 12 timer")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(status?.text ?? "Ingen aktuelle varsler")
                    .font(.caption)
                    .lineLimit(2)
            } else {
                Text("Åpne appen på iPhone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var temperature: String {
        guard let current else { return "--°" }
        return "\(current.temp.formatted(.number.precision(.fractionLength(0))))°"
    }

    private var inlineText: String {
        if let status { return status.text }
        guard let place = entry.snapshot?.place else { return AppCopy.name }
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

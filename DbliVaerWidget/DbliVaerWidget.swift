import SwiftUI
import WidgetKit
import ActivityKit

struct WeatherWidgetEntry: TimelineEntry {
    let date: Date
    let placeName: String
    let statuses: [WeatherStatus]
    let updatedAt: Date?
    var languageStyle: AlertLanguageStyle = .bokmal
    var sharedPlaces: [WidgetPlaceSummary] = []
}

struct WeatherWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeatherWidgetEntry {
        let now = Date()
        return WeatherWidgetEntry(
            date: now,
            placeName: "i Oslo",
            statuses: [
                WeatherStatus(ruleID: UUID(), type: .sol, text: "Sol i 6 timer nå.", eventAt: now, isNow: true),
                WeatherStatus(ruleID: UUID(), type: .regn, text: "Regn om 3 timers tid.", eventAt: now, isNow: false),
            ],
            updatedAt: now
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WeatherWidgetEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeatherWidgetEntry>) -> Void) {
        let now = Date()
        let dates = stride(from: 0, through: 120, by: 30).compactMap {
            Calendar.current.date(byAdding: .minute, value: $0, to: now)
        }
        let entries = dates.map(entry(at:))
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    private func entry(at date: Date) -> WeatherWidgetEntry {
        guard let snapshot = SharedWidgetData.load() else {
            return WeatherWidgetEntry(date: date, placeName: "", statuses: [], updatedAt: nil)
        }
        return WeatherWidgetEntry(
            date: date,
            placeName: snapshot.place.nameWithPreposition,
            statuses: Planner.statuses(for: snapshot.place, forecast: snapshot.forecast, now: date),
            updatedAt: snapshot.updatedAt,
            sharedPlaces: SharedWidgetData.loadSharedPlaces(),
            languageStyle: snapshot.languageStyle ?? .bokmal
        )
    }
}

struct WeatherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WeatherWidgetEntry

    var body: some View {
        Group {
            if family == .systemSmall {
                carReadySmallView
            } else {
                detailedView
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.97, blue: 1.0),
                    Color(red: 0.88, green: 0.94, blue: 0.99),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var heading: some View {
        HStack(spacing: 5) {
            Image(systemName: "cloud.sun.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(AlertType.regn.color, AlertType.sol.color)
                .widgetAccentable()
            Text(AppCopy.heading(placeName: entry.placeName))
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.60)
                .allowsTightening(true)
            Spacer(minLength: 0)
        }
    }

    private var carReadySmallView: some View {
        VStack(alignment: .leading, spacing: 7) {
            heading

            if entry.sharedPlaces.count > 1 {
                Text("Også: " + entry.sharedPlaces.dropFirst().map(\.label).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Flere valgte steder: " + entry.sharedPlaces.dropFirst().map(\.label).joined(separator: ", "))
            }
            if let first = entry.statuses.first {
                Spacer(minLength: 1)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: first.type.systemImage)
                        .font(.system(size: 28, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(first.type.color)
                        .widgetAccentable()
                        .frame(width: 32)
                    Text(WeatherLanguage.text(first.text, style: entry.languageStyle))
                        .font(.headline)
                        .fontWeight(first.isNow ? .bold : .semibold)
                        .lineLimit(3)
                        .minimumScaleFactor(0.78)
                }
                Spacer(minLength: 1)
                if let next = entry.statuses.dropFirst().first {
                    HStack(spacing: 5) {
                        Image(systemName: next.type.systemImage)
                            .foregroundStyle(next.type.color)
                            .widgetAccentable()
                        Text("Neste: \(WeatherLanguage.text(next.text, style: entry.languageStyle))")
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            } else {
                Spacer()
                Image(systemName: entry.updatedAt == nil ? "iphone.and.arrow.forward" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(entry.updatedAt == nil ? Color.orange : Color.green)
                    .widgetAccentable()
                Text(entry.updatedAt == nil ? "Åpne appen for å hente vær." : "Ingen aktuelle varsler.")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
            }
        }
    }

    private var detailedView: some View {
        VStack(alignment: .leading, spacing: 7) {
            heading

            if entry.statuses.isEmpty {
                Spacer()
                Text(entry.updatedAt == nil ? "Åpne appen for å hente vær." : "Ingen aktuelle varsler.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.statuses.prefix(4)) { status in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: status.type.systemImage)
                            .foregroundStyle(status.type.color)
                            .frame(width: 16)
                        Text(WeatherLanguage.text(status.text, style: entry.languageStyle))
                            .font(.caption)
                            .fontWeight(status.isNow ? .semibold : .regular)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct DbliVaerWidget: Widget {
    let kind = "DbliVaerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeatherWidgetProvider()) { entry in
            WeatherWidgetView(entry: entry)
        }
        .configurationDisplayName("D bli Vær!")
        .description("Aktuelle værvarsler for valgt sted på iPhone og i CarPlay.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .containerBackgroundRemovable(true)
    }
}

struct WeatherLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WeatherActivityAttributes.self) { context in
            WeatherLiveActivityView(context: context)
                .activityBackgroundTint(Color(red: 0.07, green: 0.12, blue: 0.20))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: symbol(for: context.attributes.alertType))
                        .font(.title2)
                        .foregroundStyle(color(for: context.attributes.alertType))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.eventAt, style: .timer)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppCopy.weatherHeadline(
                            weatherName: context.attributes.weatherName,
                            placeName: context.attributes.placeName
                        ))
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: symbol(for: context.attributes.alertType))
                    .foregroundStyle(color(for: context.attributes.alertType))
            } compactTrailing: {
                Text(context.state.eventAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: symbol(for: context.attributes.alertType))
                    .foregroundStyle(color(for: context.attributes.alertType))
            }
            .keylineTint(color(for: context.attributes.alertType))
        }
    }

    private func symbol(for rawType: String) -> String {
        AlertType(rawValue: rawType)?.systemImage ?? "cloud.rain.fill"
    }

    private func color(for rawType: String) -> Color {
        AlertType(rawValue: rawType)?.color ?? .blue
    }
}

private struct WeatherLiveActivityView: View {
    let context: ActivityViewContext<WeatherActivityAttributes>

    private var type: AlertType { AlertType(rawValue: context.attributes.alertType) ?? .regn }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: type.systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(type.color)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppCopy.weatherHeadline(
                    weatherName: context.attributes.weatherName,
                    placeName: context.attributes.placeName
                ))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 4) {
                    Text(context.state.possible ? "Mulig om" : "Om")
                    Text(context.state.eventAt, style: .timer)
                        .monospacedDigit()
                }
                .font(.title3.weight(.semibold))
                Text(context.state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }
}

@main
struct DbliVaerWidgetBundle: WidgetBundle {
    var body: some Widget {
        DbliVaerWidget()
        WeatherLiveActivity()
    }
}

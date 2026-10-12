import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var store: WatchWeatherStore

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = store.snapshot, let current = snapshot.forecast.first {
                    List {
                        Section {
                            HStack(spacing: 6) {
                                Text(snapshot.place.displayName)
                                    .font(.headline)
                                    .foregroundStyle(.cyan)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                                HStack(spacing: 4) {
                                    Text(compactTemperatureText(current.temp))
                                        .font(.system(.title3, design: .rounded).weight(.medium))
                                    Image(systemName: currentCondition(current).systemImage)
                                        .font(.title3)
                                        .foregroundStyle(currentCondition(current).color)
                                        .accessibilityLabel(currentCondition(current).label)
                                }
                                .fixedSize()
                            }
                            .padding(.vertical, 3)
                            TimelineView(.periodic(from: .now, by: 15 * 60)) { timeline in
                                if let freshness = WeatherGlance.freshness(
                                    updatedAt: snapshot.updatedAt,
                                    now: timeline.date,
                                    languageStyle: snapshot.languageStyle ?? .bokmal
                                ) {
                                    Label(
                                        snapshot.localized(freshness.label),
                                        systemImage: freshness.isStale ? "exclamationmark.triangle.fill" : "clock"
                                    )
                                    .font(.caption2.weight(freshness.isStale ? .semibold : .regular))
                                    .foregroundStyle(freshness.isStale ? Color.orange : Color.secondary)
                                    .lineLimit(1)
                                }
                            }
                        }

                        Section("Neste 12 timer") {
                            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                                let statuses = WeatherGlance.upcoming(
                                    Planner.statuses(for: snapshot.place, forecast: snapshot.forecast, now: timeline.date),
                                    now: timeline.date
                                )
                                if statuses.isEmpty {
                                    Text("Ingen aktuelle hendelser").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 8) {
                                        ForEach(statuses) { status in
                                            VStack(spacing: 3) {
                                                Image(systemName: status.type.systemImage)
                                                    .font(.title3)
                                                    .foregroundStyle(status.type.color)
                                                Text(snapshot.localized(WeatherGlance.eventName(
                                                    for: status,
                                                    languageStyle: snapshot.languageStyle ?? .bokmal
                                                )))
                                                    .font(.caption2.weight(.semibold))
                                                    .lineLimit(1)
                                                Text(status.isNow ? (snapshot.languageStyle == .english ? "Now" : "Nå") : shortClockLabel(status.eventAt))
                                                    .font(.caption2.monospacedDigit())
                                            }
                                            .frame(maxWidth: .infinity)
                                            .accessibilityElement(children: .ignore)
                                            .accessibilityLabel(eventAccessibilityLabel(status, snapshot: snapshot))
                                        }
                                    }
                                }
                            }
                        }

                        Section("Nå") {
                            watchMetric(WeatherGlance.metricLabel(for: .precipitation, languageStyle: snapshot.languageStyle ?? .bokmal), value: "\(current.precipitationRiskRate.formatted(.number.precision(.fractionLength(0...1)))) mm", icon: "drop.fill", color: .blue)
                            watchMetric(
                                WeatherGlance.metricLabel(for: .windGusts, languageStyle: snapshot.languageStyle ?? .bokmal),
                                value: current.compactWindAndGust,
                                icon: "wind",
                                color: .teal
                            )
                            watchMetric(WeatherGlance.metricLabel(for: .dewPoint, languageStyle: snapshot.languageStyle ?? .bokmal), value: "\(current.dew.formatted(.number.precision(.fractionLength(0...1))))°", icon: "humidity.fill", color: .mint)
                        }

                        if let message = store.message {
                            Text(message).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                } else {
                    if #available(watchOS 10.0, *) {
                        ContentUnavailableView(
                            "Venter på iPhone",
                            systemImage: "iphone.and.arrow.forward",
                            description: Text("Åpne D bli Vær! på iPhone første gang.")
                        )
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "iphone.and.arrow.forward")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Venter på iPhone")
                                .font(.headline)
                            Text("Åpne D bli Vær! på iPhone første gang.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(AppCopy.name(languageStyle: store.snapshot?.languageStyle ?? .bokmal))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await store.refresh() } } label: {
                        if store.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(store.isRefreshing || store.snapshot == nil)
                }
            }
        }
    }

    private func watchMetric(_ name: String, value: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func currentCondition(_ hour: ForecastHour) -> CurrentWeatherCondition {
        CurrentWeatherCondition.resolve(hour)
    }

    private func eventAccessibilityLabel(_ status: WeatherStatus, snapshot: WidgetWeatherSnapshot) -> String {
        let languageStyle = snapshot.languageStyle ?? .bokmal
        let name = snapshot.localized(WeatherGlance.eventName(for: status, languageStyle: languageStyle))
        let time = status.isNow
            ? (languageStyle == .english ? "Now" : "Nå")
            : shortClockLabel(status.eventAt)
        return "\(name), \(time)"
    }
}

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
                                    Text("\(current.temp.formatted(.number.precision(.fractionLength(0))))°")
                                        .font(.system(.title3, design: .rounded).weight(.medium))
                                    Image(systemName: currentCondition(current).systemImage)
                                        .font(.title3)
                                        .foregroundStyle(currentCondition(current).color)
                                        .accessibilityLabel(currentCondition(current).label)
                                }
                                .fixedSize()
                            }
                            .padding(.vertical, 3)
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
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                                        ForEach(statuses) { status in
                                            VStack(spacing: 4) {
                                                Image(systemName: status.type.systemImage)
                                                    .font(.title3)
                                                    .foregroundStyle(status.type.color)
                                                Text(status.isNow ? "Nå" : shortClockLabel(status.eventAt))
                                                    .font(.caption2.monospacedDigit())
                                            }
                                            .frame(maxWidth: .infinity)
                                            .accessibilityElement(children: .ignore)
                                            .accessibilityLabel(snapshot.localized(status.text))
                                        }
                                    }
                                }
                            }
                        }

                        Section("Nå") {
                            watchMetric("Nedbør", value: "\(current.precipitationRiskRate.formatted(.number.precision(.fractionLength(0...1)))) mm", icon: "drop.fill", color: .blue)
                            watchMetric(
                                "Vindkast",
                                value: current.compactWindAndGust,
                                icon: "wind",
                                color: .teal
                            )
                            watchMetric("Duggpunkt", value: "\(current.dew.formatted(.number.precision(.fractionLength(0...1))))°", icon: "humidity.fill", color: .mint)
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
}

import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var store: WatchWeatherStore

    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = store.snapshot, let current = snapshot.forecast.first {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(AppCopy.name)
                                    .font(.headline)
                                Text(snapshot.place.nameWithPreposition)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.cyan)
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(current.temp.formatted(.number.precision(.fractionLength(0))))°")
                                        .font(.system(size: 38, weight: .medium, design: .rounded))
                                    Spacer()
                                    Image(systemName: currentWeatherSymbol(current))
                                        .font(.title)
                                        .foregroundStyle(currentWeatherColor(current))
                                }
                            }
                            .padding(.vertical, 3)
                        }

                        let statuses = Planner.statuses(for: snapshot.place, forecast: snapshot.forecast)
                        Section("Aktuelt") {
                            if statuses.isEmpty {
                                Label("Ingen aktuelle varsler", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(statuses.prefix(5)) { status in
                                    Label {
                                        Text(status.text).font(.footnote)
                                    } icon: {
                                        Image(systemName: status.type.systemImage)
                                            .foregroundStyle(status.type.color)
                                    }
                                }
                            }
                        }

                        Section("Nå") {
                            watchMetric("Nedbør", value: "\(current.precipitationRiskRate.formatted(.number.precision(.fractionLength(0...1)))) mm", icon: "drop.fill", color: .blue)
                            watchMetric("Vindkast", value: "\(current.effectiveWind.formatted(.number.precision(.fractionLength(0...1)))) m/s", icon: "wind", color: .teal)
                            watchMetric("Duggpunkt", value: "\(current.dew.formatted(.number.precision(.fractionLength(0...1))))°", icon: "humidity.fill", color: .mint)
                        }

                        if let message = store.message {
                            Text(message).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Venter på iPhone",
                        systemImage: "iphone.and.arrow.forward",
                        description: Text("Åpne D bli Vær! på iPhone første gang.")
                    )
                }
            }
            .navigationTitle(AppCopy.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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

    private func currentWeatherSymbol(_ hour: ForecastHour) -> String {
        if hour.temp <= 1, hour.precipitationRiskRate >= 0.1 { return "cloud.snow.fill" }
        if hour.precipitationRiskRate >= 0.1 { return "cloud.rain.fill" }
        if hour.cloud <= 25 { return "sun.max.fill" }
        return "cloud.fill"
    }

    private func currentWeatherColor(_ hour: ForecastHour) -> Color {
        if hour.temp <= 1, hour.precipitationRiskRate >= 0.1 { return AlertType.sno.color }
        if hour.precipitationRiskRate >= 0.1 { return AlertType.regn.color }
        if hour.cloud <= 25 { return AlertType.sol.color }
        return .gray
    }
}

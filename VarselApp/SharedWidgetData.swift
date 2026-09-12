import Foundation

/// A glance shows the nearest event per weather type, not one tile per rule.
enum WeatherGlance {
    static func upcoming(_ statuses: [WeatherStatus], now: Date) -> [WeatherStatus] {
        let end = now.addingTimeInterval(12 * 3_600)
        let ordered = statuses.filter {
            $0.isNow || ($0.eventAt > now && $0.eventAt <= end)
        }.sorted {
            if $0.isNow != $1.isNow { return $0.isNow }
            if $0.eventAt != $1.eventAt { return $0.eventAt < $1.eventAt }
            return $0.ruleID.uuidString < $1.ruleID.uuidString
        }
        var seen = Set<AlertType>()
        return ordered.filter { seen.insert($0.type).inserted }
    }
}

struct WidgetWeatherSnapshot: Codable {
    let place: Place
    let forecast: [ForecastHour]
    let updatedAt: Date
}

/// Versioned payload semantics for iPhone → Watch application context.
/// A nil snapshot explicitly clears weather that would otherwise linger.
struct WatchWeatherTransfer: Codable {
    let snapshot: WidgetWeatherSnapshot?
    let sentAt: Date
}

enum SharedWidgetData {
    static let appGroup = "group.no.mathias.dblivaer"
    private static let snapshotKey = "widget.weather.snapshot"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func save(place: Place, forecast: [ForecastHour], updatedAt: Date = Date()) {
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: updatedAt)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    static func load() -> WidgetWeatherSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetWeatherSnapshot.self, from: data)
    }

    static func clear() {
        defaults.removeObject(forKey: snapshotKey)
    }
}

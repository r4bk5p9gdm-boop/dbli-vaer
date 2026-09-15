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
    var languageStyle: AlertLanguageStyle? = nil
    var textSeparator: WeatherTextSeparator? = .current

    func localized(_ text: String) -> String {
        WeatherLanguage.text(text, style: languageStyle ?? .bokmal, separator: textSeparator ?? .space)
    }

    /// A phone transfer (including clearing the place) invalidates an in-flight
    /// Watch request even when it happens to refer to the same coordinates.
    func refreshed(with hours: [ForecastHour], at date: Date, requestRevision: UUID, currentRevision: UUID) -> WidgetWeatherSnapshot? {
        guard requestRevision == currentRevision, !hours.isEmpty else { return nil }
        return WidgetWeatherSnapshot(
            place: place,
            forecast: hours.map { $0.locallyAdjusted(by: place.localTemperatureOffset) },
            updatedAt: date,
            languageStyle: languageStyle,
            textSeparator: textSeparator
        )
    }
}

struct WidgetPlaceSummary: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let preposition: PlacePreposition?

    var label: String {
        let place = Place(name: name, lat: 0, lon: 0, preposition: preposition)
        return place.nameWithPreposition
    }
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
    private static let placesKey = "widget.weather.places"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func save(place: Place, forecast: [ForecastHour], updatedAt: Date = Date(), languageStyle: AlertLanguageStyle? = nil, textSeparator: WeatherTextSeparator? = .current) {
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: updatedAt, languageStyle: languageStyle, textSeparator: textSeparator)
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
        defaults.removeObject(forKey: placesKey)
    }

    static func saveSharedPlaces(_ places: [Place]) {
        let summaries = places.prefix(3).map { WidgetPlaceSummary(id: $0.id, name: $0.displayName, preposition: $0.preposition) }
        if let data = try? JSONEncoder().encode(summaries) { defaults.set(data, forKey: placesKey) }
    }

    static func loadSharedPlaces() -> [WidgetPlaceSummary] {
        guard let data = defaults.data(forKey: placesKey) else { return [] }
        return (try? JSONDecoder().decode([WidgetPlaceSummary].self, from: data)) ?? []
    }
}

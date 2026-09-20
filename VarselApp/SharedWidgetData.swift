import Foundation

/// A glance shows the nearest event per weather type, not one tile per rule.
enum WeatherGlance {
    private static let nowStatusRetention: TimeInterval = 90 * 60
    private static let nowStatusLookahead: TimeInterval = 15 * 60

    static func upcoming(_ statuses: [WeatherStatus], now: Date) -> [WeatherStatus] {
        let end = now.addingTimeInterval(12 * 3_600)
        let ordered = statuses.filter {
            if $0.isNow {
                // A stale Watch/widget snapshot can outlive the event that
                // made it a "now" status. Keep the Now-glance bounded to the
                // same 90-minute semantics as Yr's short-range nowcast.
                return $0.eventAt >= now.addingTimeInterval(-nowStatusRetention)
                    && $0.eventAt <= now.addingTimeInterval(nowStatusLookahead)
            }
            return $0.eventAt > now && $0.eventAt <= end
        }.sorted {
            if $0.isNow != $1.isNow { return $0.isNow }
            if $0.eventAt != $1.eventAt { return $0.eventAt < $1.eventAt }
            let firstSeverity = glanceSeverity($0.type)
            let secondSeverity = glanceSeverity($1.type)
            if firstSeverity != secondSeverity { return firstSeverity > secondSeverity }
            return $0.ruleID.uuidString < $1.ruleID.uuidString
        }
        var seen = Set<AlertType>()
        return ordered.filter { seen.insert($0.type).inserted }
    }

    /// Forward-looking events used by Watch complications and widgets.
    /// The phone's glance may include a current NÅ-status, but a widget slot
    /// should always reserve its space for the next event.
    static func nextEvents(_ statuses: [WeatherStatus], now: Date) -> [WeatherStatus] {
        upcoming(statuses, now: now).filter { !$0.isNow }
    }

    static func compactEventLabel(for status: WeatherStatus, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        switch status.type {
        case .regn: return languageStyle == .english ? "Rain!" : "Regn!"
        case .sno: return languageStyle == .english ? "Snow!" : "Snø!"
        case .vind: return languageStyle == .english ? "Wind!" : "Vind!"
        case .dugg: return languageStyle == .inntrondersk ? "Dogg!" : languageStyle == .english ? "Dew!" : "Dugg!"
        case .sol: return languageStyle == .english ? "Sun!" : "Sol!"
        case .frost: return "Frost!"
        case .temperatur:
            let isHigh = status.text.localizedCaseInsensitiveContains("over")
            let marker = isHigh ? ">" : "<"
            let number = status.text
                .split(whereSeparator: { $0 == " " || $0 == "°" })
                .first(where: { Double(String($0).replacingOccurrences(of: ",", with: ".")) != nil })
                .map(String.init) ?? ""
            return number.isEmpty ? "Temp!" : "\(marker)\(number)°"
        }
    }

    private static func glanceSeverity(_ type: AlertType) -> Int {
        switch type {
        case .frost, .sno: return 3
        case .vind: return 2
        default: return 1
        }
    }
}

struct WidgetWeatherSnapshot: Codable {
    let place: Place
    let forecast: [ForecastHour]
    let updatedAt: Date
    var languageStyle: AlertLanguageStyle? = nil
    var textSeparator: WeatherTextSeparator? = .current

    private enum CodingKeys: String, CodingKey {
        case place, forecast, updatedAt, languageStyle, textSeparator
    }

    init(
        place: Place,
        forecast: [ForecastHour],
        updatedAt: Date,
        languageStyle: AlertLanguageStyle? = nil,
        textSeparator: WeatherTextSeparator? = .current
    ) {
        self.place = place
        self.forecast = forecast
        self.updatedAt = updatedAt
        self.languageStyle = languageStyle
        self.textSeparator = textSeparator
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        place = try values.decode(Place.self, forKey: .place)
        forecast = try values.decode([ForecastHour].self, forKey: .forecast)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)

        // A newer phone may write a language that an older Watch build does
        // not know. Keep the weather snapshot usable instead of discarding
        // the place and temperature together with the unknown preference.
        if let raw = try? values.decode(String.self, forKey: .languageStyle) {
            languageStyle = AlertLanguageStyle.persisted(raw) ?? .bokmal
        } else {
            languageStyle = nil
        }
        if let raw = try? values.decode(String.self, forKey: .textSeparator) {
            textSeparator = WeatherTextSeparator(rawValue: raw)
        } else {
            textSeparator = nil
        }
    }

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

enum WatchTransferPolicy {
    static func accepts(_ incoming: Date, after last: Date) -> Bool { incoming > last }
}

enum SharedWidgetData {
    static let appGroup = "group.no.mathias.dblivaer"
    private static let snapshotKey = "widget.weather.snapshot"
    private static let placesKey = "widget.weather.places"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static func shouldWrite(existing: Data?, new: Data) -> Bool {
        existing != new
    }

    @discardableResult
    static func save(place: Place, forecast: [ForecastHour], updatedAt: Date = Date(), languageStyle: AlertLanguageStyle? = nil, textSeparator: WeatherTextSeparator? = .current) -> Bool {
        // Never replace a usable widget snapshot with an empty refresh result.
        guard !forecast.isEmpty else { return false }
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: updatedAt, languageStyle: languageStyle, textSeparator: textSeparator)
        if let data = try? JSONEncoder().encode(snapshot) {
            guard shouldWrite(existing: defaults.data(forKey: snapshotKey), new: data) else { return false }
            defaults.set(data, forKey: snapshotKey)
            return true
        }
        return false
    }

    static func load() -> WidgetWeatherSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetWeatherSnapshot.self, from: data)
    }

    static func clear() {
        defaults.removeObject(forKey: snapshotKey)
        defaults.removeObject(forKey: placesKey)
    }

    @discardableResult
    static func saveSharedPlaces(_ places: [Place]) -> Bool {
        let summaries = places.reduce(into: [WidgetPlaceSummary]()) { result, place in
            guard result.isEmpty else { return }
            result.append(WidgetPlaceSummary(id: place.id, name: place.displayName, preposition: place.preposition))
        }
        if let data = try? JSONEncoder().encode(summaries), shouldWrite(existing: defaults.data(forKey: placesKey), new: data) {
            defaults.set(data, forKey: placesKey)
            return true
        }
        return false
    }

    static func loadSharedPlaces() -> [WidgetPlaceSummary] {
        guard let data = defaults.data(forKey: placesKey) else { return [] }
        return (try? JSONDecoder().decode([WidgetPlaceSummary].self, from: data)) ?? []
    }
}

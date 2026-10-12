import Foundation
import OSLog

/// A glance shows the nearest event per weather type, not one tile per rule.
enum WeatherGlance {
    private static let nowStatusRetention: TimeInterval = 90 * 60
    private static let nowStatusLookahead: TimeInterval = 15 * 60
    static let staleAfter: TimeInterval = 2 * 3_600

    enum Metric: CaseIterable {
        case precipitation
        case windGusts
        case dewPoint
    }

    enum WidgetEmptyState {
        case openPhone
        case noUpcomingAlerts
        case noCurrentAlerts
    }

    static func widgetEmptyStateText(
        _ state: WidgetEmptyState,
        languageStyle: AlertLanguageStyle
    ) -> String {
        let english: String
        let bokmal: String
        switch state {
        case .openPhone:
            english = "Open the app on your iPhone to get weather."
            bokmal = "Åpne appen på iPhone for å hente vær."
        case .noUpcomingAlerts:
            english = "No upcoming alerts."
            bokmal = "Ingen kommende varsler."
        case .noCurrentAlerts:
            english = "No current alerts."
            bokmal = "Ingen aktuelle varsler."
        }
        return languageStyle == .english ? english : WeatherLanguage.text(bokmal, style: languageStyle)
    }

    static func compactRelativeTime(
        to eventAt: Date,
        from now: Date,
        languageStyle: AlertLanguageStyle,
        compact: Bool
    ) -> String {
        let minutes = max(0, Int(eventAt.timeIntervalSince(now) / 60))
        let prefix = languageStyle == .english ? "in" : "om"
        if minutes < 60 {
            let amount = max(1, minutes)
            let unit = compact ? "m" : " min"
            return "\(prefix) \(amount)\(unit)"
        }
        let hours = minutes / 60
        let unit = languageStyle == .english ? "h" : (compact ? "t" : " t")
        return "\(prefix) \(hours)\(unit)"
    }

    static func metricLabel(for metric: Metric, languageStyle: AlertLanguageStyle) -> String {
        switch (metric, languageStyle == .english) {
        case (.precipitation, true): return "Precipitation"
        case (.windGusts, true): return "Wind gusts"
        case (.dewPoint, true): return "Dew point"
        case (.precipitation, false): return "Nedbør"
        case (.windGusts, false): return "Vindkast"
        case (.dewPoint, false): return "Duggpunkt"
        }
    }

    struct Freshness: Equatable {
        let label: String
        let isStale: Bool
    }

    static func freshness(
        updatedAt: Date?,
        now: Date,
        languageStyle: AlertLanguageStyle = .bokmal
    ) -> Freshness? {
        guard let updatedAt else { return nil }
        let age = max(0, now.timeIntervalSince(updatedAt))
        let isStale = age > staleAfter
        if isStale {
            let hours = max(2, Int((age / 3_600).rounded(.up)))
            let label = languageStyle == .english
                ? "May be outdated · last updated \(hours)h ago"
                : "Kan være utdatert · sist oppdatert for \(hours) t siden"
            return Freshness(label: label, isStale: true)
        }

        let localeIdentifier = languageStyle == .english ? "en_GB" : "nb_NO"
        let time = updatedAt.formatted(
            .dateTime.hour().minute().locale(Locale(identifier: localeIdentifier))
        )
        let label = languageStyle == .english ? "Updated \(time)" : "Oppdatert \(time)"
        return Freshness(label: label, isStale: false)
    }

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

    /// Keep glance-sized surfaces focused on the two nearest future events.
    static func widgetEvents(_ statuses: [WeatherStatus], now: Date) -> [WeatherStatus] {
        Array(nextEvents(statuses, now: now).prefix(2))
    }

    static func eventName(for status: WeatherStatus, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        switch status.type {
        case .regn: return languageStyle == .english ? "Rain" : "Regn"
        case .sno: return languageStyle == .english ? "Snow" : "Snø"
        case .vind: return languageStyle == .english ? "Wind" : "Vind"
        case .dugg:
            if languageStyle == .english { return "Dew" }
            return languageStyle == .inntrondersk ? "Dogg" : "Dugg"
        case .sol: return languageStyle == .english ? "Sun" : "Sol"
        case .frost: return "Frost"
        case .temperatur:
            return compactEventLabel(for: status, languageStyle: languageStyle).replacingOccurrences(of: "!", with: "")
        }
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

enum WatchWeatherCopy {
    enum Section {
        case next12Hours
        case currentConditions
    }

    enum EmptyState {
        case noEvents
        case waitingTitle
        case waitingDescription
    }

    static func refreshFailure(languageStyle: AlertLanguageStyle) -> String {
        languageStyle == .english
            ? "Could not update. Showing the last fetched weather."
            : "Kunne ikke oppdatere. Viser sist hentede vær."
    }

    static func sectionTitle(_ section: Section, languageStyle: AlertLanguageStyle) -> String {
        switch (section, languageStyle) {
        case (.next12Hours, .english): return "Next 12 hours"
        case (.next12Hours, .inntrondersk): return "Neste 12 tima"
        case (.next12Hours, .bokmal): return "Neste 12 timer"
        case (.currentConditions, .english): return "Now"
        case (.currentConditions, .inntrondersk): return "No"
        case (.currentConditions, .bokmal): return "Nå"
        }
    }

    static func emptyState(_ state: EmptyState, languageStyle: AlertLanguageStyle) -> String {
        switch (state, languageStyle) {
        case (.noEvents, .english): return "No current weather events."
        case (.noEvents, .inntrondersk): return "Ingen værhendelsa no."
        case (.noEvents, .bokmal): return "Ingen aktuelle hendelser"
        case (.waitingTitle, .english): return "Waiting for iPhone"
        case (.waitingTitle, .inntrondersk), (.waitingTitle, .bokmal): return "Venter på iPhone"
        case (.waitingDescription, .english): return "Open D bli Vær! on your iPhone to get started."
        case (.waitingDescription, .inntrondersk), (.waitingDescription, .bokmal):
            return "Åpne D bli Vær! på iPhone første gang."
        }
    }
}

struct WidgetWeatherSnapshot: Codable {
    private static let validationReferenceDateKey = CodingUserInfoKey(rawValue: "WidgetWeatherSnapshot.validationReferenceDate")!

    let place: Place
    let forecast: [ForecastHour]
    let updatedAt: Date
    var languageStyle: AlertLanguageStyle? = nil
    var textSeparator: WeatherTextSeparator? = .current

    private enum CodingKeys: String, CodingKey {
        case place, forecast, updatedAt, languageStyle, textSeparator
    }

    static func decoder(referenceDate: Date = Date()) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[validationReferenceDateKey] = referenceDate
        return decoder
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
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        if let referenceDate = decoder.userInfo[Self.validationReferenceDateKey] as? Date,
           updatedAt.timeIntervalSince(referenceDate) > Store.forecastFutureTimestampTolerance {
            throw DecodingError.dataCorruptedError(
                forKey: .updatedAt,
                in: values,
                debugDescription: "Snapshot update time is implausibly far in the future."
            )
        }
        forecast = ForecastHour.sanitizedCacheSequence(
            try values.decode([ForecastHour].self, forKey: .forecast),
            fetchedAt: updatedAt
        )

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
    static func restoredTimestamp(_ persisted: Date?, now: Date = Date()) -> Date {
        guard let persisted,
              persisted.timeIntervalSince1970.isFinite,
              persisted.timeIntervalSince(now) <= Store.forecastFutureTimestampTolerance else {
            return .distantPast
        }
        return persisted
    }

    static func accepts(_ incoming: Date, after last: Date, now: Date = Date()) -> Bool {
        let incomingTime = incoming.timeIntervalSince1970
        guard incomingTime.isFinite,
              incoming.timeIntervalSince(now) <= Store.forecastFutureTimestampTolerance else { return false }
        return incoming > last
    }

    static func acceptsSnapshot(_ incoming: WidgetWeatherSnapshot?, replacing current: WidgetWeatherSnapshot?) -> Bool {
        guard let incoming else { return true }
        guard let current else { return true }
        return incoming.updatedAt >= current.updatedAt
    }
}

enum SharedWidgetData {
    static let appGroup = "group.no.mathias.dblivaer"
    private static let snapshotKey = "widget.weather.snapshot"
    private static let placesKey = "widget.weather.places"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "no.mathias.dblivaer",
        category: "SharedWidgetData"
    )

    static func withAppGroupDefaults<Value>(
        suiteName: String,
        defaultsProvider: (String) -> UserDefaults?,
        onUnavailable: () -> Void,
        operation: (UserDefaults) -> Value
    ) -> Value? {
        guard let defaults = defaultsProvider(suiteName) else {
            onUnavailable()
            return nil
        }
        return operation(defaults)
    }

    private static func withDefaults<Value>(_ operation: (UserDefaults) -> Value) -> Value? {
        withAppGroupDefaults(
            suiteName: appGroup,
            defaultsProvider: { UserDefaults(suiteName: $0) },
            onUnavailable: {
                logger.error("App Group UserDefaults unavailable for \(appGroup, privacy: .public); shared weather data access was skipped.")
            },
            operation: operation
        )
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
            return withDefaults { defaults in
                guard shouldWrite(existing: defaults.data(forKey: snapshotKey), new: data) else { return false }
                defaults.set(data, forKey: snapshotKey)
                return true
            } ?? false
        }
        return false
    }

    static func load() -> WidgetWeatherSnapshot? {
        guard let data = withDefaults({ $0.data(forKey: snapshotKey) }) ?? nil else { return nil }
        return try? WidgetWeatherSnapshot.decoder().decode(WidgetWeatherSnapshot.self, from: data)
    }

    static func clear() {
        _ = withDefaults { defaults in
            defaults.removeObject(forKey: snapshotKey)
            defaults.removeObject(forKey: placesKey)
        }
    }

    @discardableResult
    static func saveSharedPlaces(_ places: [Place]) -> Bool {
        var summaries: [WidgetPlaceSummary] = []
        var seenIDs = Set<UUID>()
        for place in places {
            guard summaries.count < 3 else { break }
            guard seenIDs.insert(place.id).inserted else { continue }
            summaries.append(WidgetPlaceSummary(id: place.id, name: place.displayName, preposition: place.preposition))
        }
        if let data = try? JSONEncoder().encode(summaries) {
            return withDefaults { defaults in
                guard shouldWrite(existing: defaults.data(forKey: placesKey), new: data) else { return false }
                defaults.set(data, forKey: placesKey)
                return true
            } ?? false
        }
        return false
    }

    static func loadSharedPlaces() -> [WidgetPlaceSummary] {
        guard let data = withDefaults({ $0.data(forKey: placesKey) }) ?? nil else { return [] }
        return (try? JSONDecoder().decode([WidgetPlaceSummary].self, from: data)) ?? []
    }
}

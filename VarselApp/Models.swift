import SwiftUI
import CoreLocation

enum PlaceOrderingSettings {
    static let homePlaceIDKey = "varsel.homePlaceID"
    static let sortModeKey = "varsel.placeSortMode"
}

func compactTemperatureText(_ temperature: Double) -> String {
    guard temperature.isFinite else { return "–°" }
    return "\(temperature.formatted(.number.precision(.fractionLength(0))))°"
}

/// Explicit favorites for the sides of the current-location home page.
/// IDs survive renaming and list sorting; deleted places are not substituted.
struct HomeFavorites: Codable, Equatable {
    var left: UUID?
    var right: UUID?

    func resolved(availableIDs: Set<UUID>) -> HomeFavorites {
        // Missing/deleted favorites resolve to nil; swipe pages never invent
        // a replacement or duplicate the current place.
        let validLeft = left.flatMap { availableIDs.contains($0) ? $0 : nil }
        let validRight = right.flatMap { availableIDs.contains($0) && $0 != validLeft ? $0 : nil }
        return HomeFavorites(left: validLeft, right: validRight)
    }
}

enum WatchPlaceSource: String, CaseIterable, Identifiable {
    case position
    case fixed

    var id: String { rawValue }
    var label: String {
        switch self {
        case .position: "Aktuell posisjon"
        case .fixed: "Fast sted"
        }
    }
}

enum WatchPlaceSettings {
    static let sourceKey = "varsel.watchPlaceSource"
    static let fixedPlaceIDKey = "varsel.watchFixedPlaceID"

    /// Resolves the place the Watch should display without allowing a stale
    /// saved UUID to produce an empty or unrelated snapshot.
    static func resolvedPlaceID(
        source: WatchPlaceSource,
        fixedPlaceID: UUID?,
        selectedID: UUID?,
        currentLocationID: UUID?,
        availableIDs: Set<UUID>
    ) -> UUID? {
        switch source {
        case .fixed:
            guard let fixedPlaceID, availableIDs.contains(fixedPlaceID) else { return selectedID.flatMap { availableIDs.contains($0) ? $0 : nil } }
            return fixedPlaceID
        case .position:
            return currentLocationID.flatMap { availableIDs.contains($0) ? $0 : nil }
                ?? selectedID.flatMap { availableIDs.contains($0) ? $0 : nil }
        }
    }
}

/// Pure swipe policy shared by the home view and its regression tests. Vertical
/// scrolling is never interpreted as a place change, and duplicate favorite
/// IDs cannot create a phantom intermediate page.
enum HomeSwipeSelection {
    static func shouldShowHint(placeCount: Int) -> Bool { placeCount > 1 }

    /// Shared home-page order: live position first, then the two starred
    /// places. Missing or repeated IDs are removed without changing order.
    static func orderedHomeIDs(positionID: UUID?, favorite1ID: UUID?, favorite2ID: UUID?) -> [UUID] {
        [positionID, favorite1ID, favorite2ID].compactMap { $0 }.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
    }

    static func orderedIDs(leftID: UUID?, currentID: UUID?, rightID: UUID?) -> [UUID] {
        [leftID, currentID, rightID].compactMap { $0 }.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
    }

    static func nextIndex(
        currentID: UUID,
        placeIDs: [UUID],
        horizontalTranslation: Double,
        verticalTranslation: Double,
        minimumDistance: Double = 70
    ) -> Int? {
        let uniqueIDs = placeIDs.reduce(into: [UUID]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard abs(horizontalTranslation) > abs(verticalTranslation),
              abs(horizontalTranslation) > minimumDistance,
              let currentIndex = uniqueIDs.firstIndex(of: currentID) else { return nil }
        let next = horizontalTranslation < 0 ? currentIndex + 1 : currentIndex - 1
        return uniqueIDs.indices.contains(next) ? next : nil
    }
}

struct SharedPlaceSelection: Codable, Equatable {
    var ids: [UUID] = []
    func resolved(available: [Place]) -> [UUID] {
        let valid = Set(available.map(\.id))
        return ids.filter { valid.contains($0) }.reduce(into: []) { if !$0.contains($1) && $0.count < 3 { $0.append($1) } }
    }
}

enum AppCopy {
    static let name = LanguageCatalog.value("app.name", language: "nb", fallback: "D bli Vær!")

    static func name(languageStyle: AlertLanguageStyle) -> String {
        LanguageCatalog.value("app.name", language: languageStyle.catalogCode, fallback: name)
    }

    static func heading(placeName: String = "") -> String {
        [name, placeName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func heading(placeName: String = "", languageStyle: AlertLanguageStyle) -> String {
        [name(languageStyle: languageStyle), placeName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func weatherHeadline(
        weatherName: String,
        placeName: String = "",
        possibility: String = "bli"
    ) -> String {
        ["D \(possibility) \(weatherName)!", placeName].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

enum AlertLanguageStyle: String, Codable, CaseIterable, Identifiable {
    case bokmal
    case inntrondersk
    case english
    var id: String { rawValue }
    var label: String {
        switch self { case .bokmal: "Bokmål"; case .inntrondersk: "Inntrøndersk"; case .english: "English" }
    }
    var catalogCode: String { self == .bokmal ? "nb" : self == .inntrondersk ? "tr" : "en" }

    static func persisted(_ value: String) -> AlertLanguageStyle? {
        if let exact = AlertLanguageStyle(rawValue: value) { return exact }
        switch value.lowercased() {
        case "bokmål", "bokmaal": return .bokmal
        case "inntrøndersk", "inntrondersk": return .inntrondersk
        case "en", "english", "engelsk": return .english
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let style = Self.persisted(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Ukjent språkvalg: \(value)"))
        }
        self = style
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Only generated weather copy goes through this dictionary. Place names,
/// prepositions and the user's reminder are deliberately kept verbatim.
enum LanguageCatalog {
    private struct Catalog: Decodable { let tekster: [String: [String: String]] }
    static let entries: [String: [String: String]] = {
        // A missing/invalid optional catalog must degrade to built-in copy;
        // it must never prevent Store from loading seed places.
        guard let url = Bundle.main.url(forResource: "Sprak", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [:] }
        return catalog.tekster
    }()

    static func value(_ key: String, language: String, fallback: String, arguments: [String: String] = [:]) -> String {
        let candidate = entries[key]?[language]
        let template = (candidate?.isEmpty == false ? candidate : nil) ?? fallback
        // One pass: user-provided values must never be interpreted as templates.
        guard let regex = try? NSRegularExpression(pattern: "\\{([a-zA-Z_]+)\\}") else { return template }
        var result = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: template),
                  let range = Range(match.range, in: result), let value = arguments[String(template[keyRange])] else { continue }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
}

enum WeatherTextSeparator: String, CaseIterable, Codable, Identifiable {
    case space, comma, bullet, dash
    var id: String { rawValue }
    static let key = "weather.text.separator"
    static var defaults: UserDefaults { UserDefaults(suiteName: "group.no.mathias.dblivaer") ?? .standard }
    static var current: Self { Self(rawValue: defaults.string(forKey: key) ?? "space") ?? .space }
    var label: String {
        switch self { case .space: "Mellomrom"; case .comma: "Komma ,"; case .bullet: "Punkt •"; case .dash: "Tankestrek —" }
    }
    var separator: String {
        switch self { case .space: " "; case .comma: ", "; case .bullet: " • "; case .dash: " — " }
    }
    func format(_ text: String) -> String {
        text.replacingOccurrences(of: " kl. ", with: separator + "kl. ")
    }
}

enum WeatherLanguage {
    private static func sentenceStart(_ value: String) -> String {
        value.prefix(1).uppercased() + value.dropFirst()
    }
    static func text(_ text: String, style: AlertLanguageStyle, separator: WeatherTextSeparator = .current) -> String {
        if style == .english { return englishText(text) }
        guard style == .inntrondersk else { return separator.format(text) }
        var result = text
            .replacingOccurrences(of: "\\b([0-9]+) timer\\b", with: "$1 tima", options: .regularExpression)
            // The second line follows the vocabulary approved in
            // VARSELTEKSTER.md. Keep these replacements before generic
            // substitutions so multiword weather descriptions stay intact.
            .replacingOccurrences(of: "Litt regn", with: "Småregn")
            .replacingOccurrences(of: "Kraftig regn", with: "Striskur")
            .replacingOccurrences(of: "Regnbyger", with: "Regnbyga")
            .replacingOccurrences(of: "Lett snøfall", with: "Litt snø")
            .replacingOccurrences(of: "Snøbyger", with: "Snøbyga")
            .replacingOccurrences(of: "Frisk bris", with: "Fresk bris")
            .replacingOccurrences(of: "Full storm", with: "Uvær")
            // «No e d» describes only something happening right now. Keep
            // future dew forecasts as the plain weather name so a timestamp
            // is not accidentally phrased as a present status.
            .replacingOccurrences(of: "Fare for dugg nå", with: LanguageCatalog.value("now.dew", language: "tr", fallback: "D e Duggfall!"))
            .replacingOccurrences(of: "Duggfall nå", with: LanguageCatalog.value("now.dew", language: "tr", fallback: "D e Duggfall!"))
            .replacingOccurrences(of: "Frost nå", with: LanguageCatalog.value("now.frost", language: "tr", fallback: "D e Frost!"))
            .replacingOccurrences(of: "Sol i [0-9]+ timer nå\\.", with: LanguageCatalog.value("now.sun", language: "tr", fallback: "D e Sol!"), options: .regularExpression)
            .replacingOccurrences(of: "Fare for dugg", with: "Mulig doggfall")
            .replacingOccurrences(of: "Duggfall", with: "Doggfall")
            // Current-condition messages are short, spoken phrases. Keep
            // these replacements before the generic «nå» -> «no» mapping.
            .replacingOccurrences(of: "Litt regn nå", with: LanguageCatalog.value("now.rain_light", language: "tr", fallback: "D e Litt Regn!"))
            .replacingOccurrences(of: "Mulig regn nå", with: LanguageCatalog.value("now.rain_possible", language: "tr", fallback: "D kan bli regn no"))
            .replacingOccurrences(of: "Regn nå", with: LanguageCatalog.value("now.rain", language: "tr", fallback: "D Regne!"))
            .replacingOccurrences(of: "Snø nå", with: LanguageCatalog.value("now.snow", language: "tr", fallback: "Det Snør!"))
            .replacingOccurrences(of: "Vindkast nå", with: LanguageCatalog.value("now.wind", language: "tr", fallback: "D Blæs!"))
            .replacingOccurrences(of: "Vind nå", with: LanguageCatalog.value("now.wind", language: "tr", fallback: "D Blæs!"))
            .replacingOccurrences(of: "Under ([0-9,.-]+)° nå\\.?", with: "D e Under $1°!", options: .regularExpression)
            .replacingOccurrences(of: "!.", with: "!")
            .replacingOccurrences(of: "\\bnå\\b", with: LanguageCatalog.value("time.now", language: "tr", fallback: "no"), options: .regularExpression)
            .replacingOccurrences(of: "opptil", with: "oppte")
            .replacingOccurrences(of: "denne timen", with: LanguageCatalog.value("time.this_hour", language: "tr", fallback: "herre tima"))
            .replacingOccurrences(of: "i overmorgen", with: LanguageCatalog.value("time.day_after_phrase", language: "tr", fallback: "i overmårrå"))
            .replacingOccurrences(of: "I overmorgen", with: sentenceStart(LanguageCatalog.value("time.day_after_phrase", language: "tr", fallback: "i overmårrå")))
            .replacingOccurrences(of: "i morgen", with: LanguageCatalog.value("time.tomorrow_phrase", language: "tr", fallback: "i mårrå"))
            .replacingOccurrences(of: "I morgen", with: sentenceStart(LanguageCatalog.value("time.tomorrow_phrase", language: "tr", fallback: "i mårrå")))
            .replacingOccurrences(of: " til ", with: " " + LanguageCatalog.value("time.until", language: "tr", fallback: "te") + " ")
        let dialectDays = ["manda'n", "tirsda'n", "onsda'n", "torsda'n", "freda'n", "lørda'n", "sønda'n"]
        let keys = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for (index, day) in fullDayNames.enumerated() {
            let dialect = LanguageCatalog.value("weekday." + keys[index], language: "tr", fallback: dialectDays[index])
            result = result.replacingOccurrences(of: "\\b\(day)\\b", with: dialect, options: .regularExpression)
            result = result.replacingOccurrences(of: "\\b\(day.capitalized)\\b", with: dialect.prefix(1).uppercased() + dialect.dropFirst(), options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "(Under [0-9,.-]+)° no", with: "$1 no", options: .regularExpression)
        return separator.format(result)
    }

    private static func englishText(_ text: String) -> String {
        func catalogPhrase(_ key: String, fallback: String) -> String {
            let template = LanguageCatalog.value(key, language: "en", fallback: fallback)
            // The catalog also contains full timestamp templates. This
            // method is used for replacing only the day/night fragment, so
            // discard its timestamp placeholder and trailing preposition.
            return template
                .replacingOccurrences(of: " {klokkeslett}", with: "")
                .replacingOccurrences(of: " at", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        var result = text
            .replacingOccurrences(of: "om et kvarter", with: LanguageCatalog.value("time.quarter", language: "en", fallback: "in fifteen minutes"))
            .replacingOccurrences(of: "om en halvtime", with: LanguageCatalog.value("time.half_hour", language: "en", fallback: "in half an hour"))
            .replacingOccurrences(of: "om tre kvarter", with: LanguageCatalog.value("time.three_quarters", language: "en", fallback: "in forty-five minutes"))
            .replacingOccurrences(of: "om en time", with: LanguageCatalog.value("time.one_hour", language: "en", fallback: "in an hour"))
            .replacingOccurrences(of: "i overmorgen", with: LanguageCatalog.value("time.day_after_phrase", language: "en", fallback: "the day after tomorrow"))
            .replacingOccurrences(of: "i morgen", with: LanguageCatalog.value("time.tomorrow_phrase", language: "en", fallback: "tomorrow"))
            .replacingOccurrences(of: "i dag", with: catalogPhrase("time.today", fallback: "today"))
            .replacingOccurrences(of: "i natt", with: catalogPhrase("time.tonight", fallback: "tonight"))
            .replacingOccurrences(of: "natt til ", with: LanguageCatalog.value("time.night_before", language: "en", fallback: "night before "))
            .replacingOccurrences(of: " kl. ", with: " at ")
            .replacingOccurrences(of: "Sol i ", with: "Sun for ")
            .replacingOccurrences(of: "Fare for dugg", with: LanguageCatalog.value("detail.dew_risk", language: "en", fallback: "Risk of dew"))
            .replacingOccurrences(of: "Duggfall", with: LanguageCatalog.value("weather.dew", language: "en", fallback: "Dew"))
            .replacingOccurrences(of: "Regn", with: LanguageCatalog.value("weather.rain", language: "en", fallback: "Rain"))
            .replacingOccurrences(of: "Snø", with: LanguageCatalog.value("weather.snow", language: "en", fallback: "Snow"))
            .replacingOccurrences(of: "Frost", with: LanguageCatalog.value("weather.frost", language: "en", fallback: "Frost"))
            .replacingOccurrences(of: "Vindkast", with: LanguageCatalog.value("weather.gust", language: "en", fallback: "Wind gusts"))
            .replacingOccurrences(of: "Vind", with: LanguageCatalog.value("weather.wind", language: "en", fallback: "Wind"))
            .replacingOccurrences(of: "Skydekke", with: "Cloud cover")
            .replacingOccurrences(of: "Duggpunkt", with: "Dew point")
            .replacingOccurrences(of: "forskjell fra lufttemperaturen", with: "difference from air temperature")
            .replacingOccurrences(of: "Yr melder", with: "Yr reports")
            .replacingOccurrences(of: "Lokalt anslag", with: "Local estimate")
            .replacingOccurrences(of: "Mulig", with: "Possible")
            .replacingOccurrences(of: "Opptil", with: LanguageCatalog.value("detail.up_to", language: "en", fallback: "up to").capitalized)
            .replacingOccurrences(of: "opptil", with: LanguageCatalog.value("detail.up_to", language: "en", fallback: "up to"))
            .replacingOccurrences(of: "oppte", with: LanguageCatalog.value("detail.up_to", language: "en", fallback: "up to"))
        let weekdays = ["mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag", "søndag"]
        let english = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        for (norwegian, translated) in zip(weekdays, english) {
            result = result.replacingOccurrences(of: norwegian, with: translated)
                .replacingOccurrences(of: norwegian.capitalized, with: translated)
        }
        return result
    }
}

enum WindGustLevel: Int, CaseIterable, Identifiable {
    case looseObjects = 12
    case powerful = 20
    case veryPowerful = 30
    case extreme = 40

    var id: Int { rawValue }
    var threshold: Double { Double(rawValue) }

    var label: String {
        switch self {
        case .looseObjects: "Fest løse gjenstander"
        case .powerful: "Kraftige vindkast"
        case .veryPowerful: "Svært kraftige vindkast"
        case .extreme: "Ekstreme vindkast"
        }
    }

    var notificationWeather: String {
        switch self {
        case .looseObjects: "Vindkast"
        case .powerful: "Kraftige vindkast"
        case .veryPowerful: "Svært kraftige vindkast"
        case .extreme: "Ekstreme vindkast"
        }
    }

    var shortNotificationName: String {
        switch self { case .looseObjects: "vindkast"; case .powerful: "kraftige vindkast"; case .veryPowerful: "svært kraftige vindkast"; case .extreme: "ekstreme vindkast" }
    }

    var guidance: String {
        switch self {
        case .looseObjects: "Fest løse gjenstander."
        case .powerful: "Sikre lette utemøbler og andre løse ting."
        case .veryPowerful: "Vær forberedt på skader og krevende ferdsel."
        case .extreme: "Ekstreme kast kan gi alvorlige skader. Følg farevarslene fra MET."
        }
    }

    static func forThreshold(_ speed: Double) -> WindGustLevel {
        allCases.min(by: { abs($0.threshold - speed) < abs($1.threshold - speed) }) ?? .looseObjects
    }

    static func forSpeed(_ speed: Double) -> WindGustLevel {
        if speed >= extreme.threshold { return .extreme }
        if speed >= veryPowerful.threshold { return .veryPowerful }
        if speed >= powerful.threshold { return .powerful }
        return .looseObjects
    }
}

func windStrengthLabel(for metersPerSecond: Double) -> String {
    // Shared by iPhone, widget and Watch so boundary labels stay identical.
    switch metersPerSecond {
    case ..<0.3: "stille"
    case ..<1.6: "flau vind"
    case ..<3.4: "svak vind"
    case ..<5.5: "lett bris"
    case ..<8.0: "laber bris"
    case ..<10.8: "frisk bris"
    case ..<13.9: "liten kuling"
    case ..<17.2: "stiv kuling"
    case ..<20.8: "sterk kuling"
    case ..<24.5: "liten storm"
    case ..<28.5: "full storm"
    case ..<32.7: "sterk storm"
    default: "orkan"
    }
}

func precipitationHeadlineName(temperature: Double, possible: Bool) -> String {
    let kind = temperature <= 1 ? "Snø" : "Regn"
    return possible ? "Mulig \(kind.lowercased())" : kind
}

enum AlertType: String, Codable, CaseIterable, Identifiable {
    case regn, frost, temperatur, sno, vind, dugg, sol
    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self).lowercased()
        switch value {
        case "regn", "yr": self = .regn
        case "frost": self = .frost
        case "temperatur", "temp": self = .temperatur
        case "sno", "snø", "sludd": self = .sno
        case "vind", "vindkast": self = .vind
        case "dugg", "duggfall": self = .dugg
        case "sol", "skyfritt": self = .sol
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Ukjent varseltype: \(value)"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var label: String {
        switch self {
        case .regn: "Regn"; case .frost: "Frost"; case .temperatur: "Temperatur"; case .sno: "Snø"
        case .vind: "Vindkast"; case .dugg: "Duggpunkt"; case .sol: "Sol"
        }
    }
    var unit: String {
        switch self {
        case .regn: "mm/t"; case .sno: "mm vann/t"; case .frost, .temperatur: "°C"; case .vind: "m/s"
        case .dugg: "°C fra dugg"; case .sol: "% skydekke"
        }
    }
    var defaultThreshold: Double {
        switch self { case .regn: 0.5; case .frost: 0; case .temperatur: 10; case .sno: 0.3; case .vind: 9; case .dugg: 1; case .sol: 20 }
    }
    var range: ClosedRange<Double> {
        switch self { case .regn, .sno: 0.1...5; case .frost: -10...4; case .temperatur: -20...30; case .vind: 4...50; case .dugg: 0...3; case .sol: 0...50 }
    }
    var step: Double {
        switch self { case .regn, .sno: 0.1; case .frost, .temperatur, .dugg: 0.5; case .vind: 1; case .sol: 5 }
    }
    var needsDuration: Bool { self == .sol }
    var systemImage: String {
        switch self {
        case .regn: "cloud.rain.fill"
        case .frost: "thermometer.snowflake"
        case .temperatur: "thermometer"
        case .sno: "cloud.snow.fill"
        case .vind: "wind"
        case .dugg: "drop.fill"
        case .sol: "sun.max.fill"
        }
    }
    var color: Color {
        switch self {
        case .regn: Color(red: 0.18, green: 0.44, blue: 0.93)
        case .frost: Color(red: 0.48, green: 0.78, blue: 0.91)
        case .temperatur: Color(red: 0.30, green: 0.58, blue: 0.78)
        case .sno: Color(red: 0.72, green: 0.78, blue: 0.84)
        case .vind: Color(red: 0.42, green: 0.55, blue: 0.64)
        case .dugg: Color(red: 0.35, green: 0.70, blue: 0.60)
        case .sol: Color(red: 0.95, green: 0.70, blue: 0.24)
        }
    }

    func matches(_ h: ForecastHour, threshold: Double) -> Bool {
        switch self {
        case .regn: h.precipitationRiskRate >= threshold && h.temp > 1
        case .frost: h.temp <= threshold
        case .temperatur: h.temp < threshold
        case .sno: h.precipitationRiskRate >= threshold && h.temp <= 1
        case .vind: h.gust.map { $0.isFinite && $0 >= threshold } ?? false
        case .dugg: h.temp - h.dew <= threshold
        case .sol: h.cloud <= threshold
        }
    }
}

enum CurrentWeatherCondition: Equatable {
    case snow
    case rain
    case fog
    case clear
    case partlyCloudy
    case cloudy

    static func resolve(_ hour: ForecastHour, precipitationIsFalling: Bool? = nil) -> Self {
        let isWet = precipitationIsFalling ?? (hour.precipitationRiskRate >= 0.1)
        if isWet { return hour.temp <= 1 ? .snow : .rain }
        if (hour.fog ?? 0) >= 50 { return .fog }
        if hour.cloud <= 20 { return .clear }
        if hour.cloud <= 65 { return .partlyCloudy }
        return .cloudy
    }

    var label: String {
        switch self {
        case .snow: "Snø"
        case .rain: "Regn"
        case .fog: "Tåke"
        case .clear: "Sol"
        case .partlyCloudy: "Solgløtt"
        case .cloudy: "Skyer"
        }
    }

    var systemImage: String {
        switch self {
        case .snow: AlertType.sno.systemImage
        case .rain: AlertType.regn.systemImage
        case .fog: "cloud.fog.fill"
        case .clear: AlertType.sol.systemImage
        case .partlyCloudy: "cloud.sun.fill"
        case .cloudy: "cloud.fill"
        }
    }

    var color: Color {
        switch self {
        case .snow: AlertType.sno.color
        case .rain: AlertType.regn.color
        case .fog: Color(red: 0.38, green: 0.45, blue: 0.52)
        case .clear: AlertType.sol.color
        // A muted gold tells the user that the sun is actually visible behind
        // the cloud. Fully cloudy keeps the quiet blue-grey treatment.
        case .partlyCloudy: Color(red: 0.79, green: 0.61, blue: 0.22)
        case .cloudy: Color(red: 0.27, green: 0.45, blue: 0.62)
        }
    }
}

struct Rule: Codable, Identifiable, Hashable {
    enum TemperatureDirection: String, Codable, CaseIterable, Identifiable { case below, above; var id: String { rawValue }; var label: String { self == .below ? "Under" : "Over" } }
    var id = UUID()
    var templateTitle: String = ""
    var customName: String = ""
    var memoSuggestion: String = ""
    var type: AlertType
    var threshold: Double
    var temperatureDirection: TemperatureDirection = .below
    var durationHours: Int = 4
    var leadMinutes: Int = 120
    var previousDayNotificationHour: Int? = nil
    var previousDayNotificationMinute: Int = 0
    var notificationWeekday: Int? = nil
    var notificationDayOffset: Int? = nil
    var count: Int = 2
    var intervalMinutes: Int = 30
    var repeatsEnabled: Bool = false
    var quiet: Bool = true
    var quietFrom: Int = 22
    var quietTo: Int = 7
    var days: Set<Int> = Set(0..<7)   // 0 = mandag
    var enabled: Bool = true
    var activeFromHour: Int = 0
    var activeToHour: Int = 0
    var onlyWhenNearby: Bool = false
    var isDisplayOnly: Bool = false

    init(type: AlertType) {
        self.type = type
        self.threshold = type.defaultThreshold
        if type == .sol {
            activeFromHour = 7
            activeToHour = 22
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, templateTitle, customName, memoSuggestion, type, threshold, durationHours, leadMinutes, previousDayNotificationHour, previousDayNotificationMinute, notificationWeekday, notificationDayOffset, count, intervalMinutes
        case repeatsEnabled, quiet, quietFrom, quietTo, days, enabled, activeFromHour, activeToHour, onlyWhenNearby, isDisplayOnly, temperatureDirection
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        templateTitle = try values.decodeIfPresent(String.self, forKey: .templateTitle) ?? ""
        customName = try values.decodeIfPresent(String.self, forKey: .customName) ?? ""
        memoSuggestion = try values.decodeIfPresent(String.self, forKey: .memoSuggestion) ?? ""
        type = try values.decode(AlertType.self, forKey: .type)
        // Preserve the historical wind default for older saved rules.
        threshold = try values.decodeIfPresent(Double.self, forKey: .threshold) ?? (type == .vind ? 10 : type.defaultThreshold)
        temperatureDirection = try values.decodeIfPresent(TemperatureDirection.self, forKey: .temperatureDirection) ?? .below
        durationHours = try values.decodeIfPresent(Int.self, forKey: .durationHours) ?? 4
        leadMinutes = try values.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 120
        previousDayNotificationHour = try values.decodeIfPresent(Int.self, forKey: .previousDayNotificationHour)
        previousDayNotificationMinute = try values.decodeIfPresent(Int.self, forKey: .previousDayNotificationMinute) ?? 0
        notificationWeekday = try values.decodeIfPresent(Int.self, forKey: .notificationWeekday)
        notificationDayOffset = try values.decodeIfPresent(Int.self, forKey: .notificationDayOffset)
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 2
        intervalMinutes = try values.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30
        repeatsEnabled = try values.decodeIfPresent(Bool.self, forKey: .repeatsEnabled) ?? false
        quiet = try values.decodeIfPresent(Bool.self, forKey: .quiet) ?? true
        quietFrom = try values.decodeIfPresent(Int.self, forKey: .quietFrom) ?? 22
        quietTo = try values.decodeIfPresent(Int.self, forKey: .quietTo) ?? 7
        days = try values.decodeIfPresent(Set<Int>.self, forKey: .days) ?? Set(0..<7)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        activeFromHour = try values.decodeIfPresent(Int.self, forKey: .activeFromHour) ?? (type == .sol ? 7 : 0)
        activeToHour = try values.decodeIfPresent(Int.self, forKey: .activeToHour) ?? (type == .sol ? 22 : 0)
        onlyWhenNearby = try values.decodeIfPresent(Bool.self, forKey: .onlyWhenNearby) ?? false
        isDisplayOnly = try values.decodeIfPresent(Bool.self, forKey: .isDisplayOnly) ?? false
    }

    var alertCount: Int { repeatsEnabled ? max(2, count) : 1 }
    static func filtered(_ rules: [Rule], by type: AlertType?) -> [Rule] {
        guard let type else { return rules }
        return rules.filter { $0.type == type }
    }
    var windGustLevel: WindGustLevel { .forThreshold(threshold) }

    var notificationScheduleLabel: String {
        if let hour = previousDayNotificationHour {
            if let weekday = notificationWeekday, dayNames.indices.contains(weekday) {
                return "\(fullDayNames[weekday]) kl. \(hourLabel(hour)).\(String(format: "%02d", previousDayNotificationMinute))"
            }
            if notificationDayOffset == 0 {
                return "kl. \(hourLabel(hour)).\(String(format: "%02d", previousDayNotificationMinute)) samme dag"
            }
            let period = activeFromHour > activeToHour ? "før natta" : "dagen før"
            return "kl. \(hourLabel(hour)).\(String(format: "%02d", previousDayNotificationMinute)) \(period)"
        }
        return "\(minutesLabel(leadMinutes)) før"
    }

    var cleanedCustomName: String? {
        let cleaned = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    var displayName: String {
        let savedTitle = templateTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return savedTitle.isEmpty ? inferredTemplateTitle : savedTitle
    }

    private var inferredTemplateTitle: String {
        let weather: String
        switch type {
        case .regn: weather = "Regn"
        case .frost: weather = "Frost"
        case .temperatur: weather = "Temperatur"
        case .sno: weather = "Snø"
        case .vind: weather = "Vind"
        case .dugg: weather = "Dugg"
        case .sol: weather = "Sol"
        }
        if activeFromHour > activeToHour { return "\(weather) i natt" }
        if previousDayNotificationHour != nil {
            return type == .regn ? "Regn neste dag" : "\(weather) i morgen"
        }
        return "\(weather)varsel"
    }

    func statusText(_ weatherText: String) -> String { weatherText }

    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = (calendar.component(.weekday, from: date) + 5) % 7
        guard days.contains(weekday) else { return false }
        let hour = calendar.component(.hour, from: date)
        if activeFromHour == activeToHour { return true }
        if activeFromHour < activeToHour {
            return hour >= activeFromHour && hour < activeToHour
        }
        return hour >= activeFromHour || hour < activeToHour
    }

    func matches(_ hour: ForecastHour, frostMargin: Double = 0) -> Bool {
        // Frost margin shifts only the decision threshold; raw Yr values stay
        // untouched for display, storage and later calibration.
        let effectiveThreshold = type == .frost ? threshold + max(0, frostMargin) : threshold
        if type == .temperatur { return temperatureDirection == .above ? hour.temp > threshold : hour.temp < threshold }
        return type.matches(hour, threshold: effectiveThreshold)
    }

    var summary: String {
        let t = threshold.formatted(.number.precision(.fractionLength(0...1)))
        let prefix = type == .temperatur ? "\(temperatureDirection.label) " : ""
        return "\(prefix)\(type.label) \(t) \(type.unit)" + (type.needsDuration ? ", \(durationHours) t" : "")
    }

    var activeHoursLabel: String {
        activeFromHour == activeToHour
            ? "hele døgnet"
            : "kl. \(hourLabel(activeFromHour))–\(hourLabel(activeToHour))"
    }
}

struct PrecipitationSample: Codable, Identifiable, Hashable {
    let time: Date
    let rate: Double
    var id: Date { time }
}

struct ForecastHour: Codable, Identifiable, Hashable {
    let time: Date
    var temp: Double, precip: Double, wind: Double, cloud: Double, dew: Double
    var precipMin: Double? = nil
    var precipMax: Double? = nil
    var precipProbability: Double? = nil
    var gust: Double? = nil
    var fog: Double? = nil
    var temperatureLow: Double? = nil
    var temperatureHigh: Double? = nil
    var radarSamples: [PrecipitationSample]? = nil
    var yrTemperature: Double? = nil

    func locallyAdjusted(by offset: Double) -> ForecastHour {
        var copy = self
        let original = yrTemperature ?? temp
        copy.temp = original + offset
        copy.yrTemperature = offset == 0 ? nil : original
        return copy
    }
    var id: Date { time }

    var precipitationRate: Double {
        max(precip, radarSamples?.map(\.rate).max() ?? 0)
    }

    var precipitationRiskRate: Double {
        guard (precipProbability ?? 0) >= 20 else { return precipitationRate }
        return max(precipitationRate, precipMax ?? 0)
    }

    func isPossiblePrecipitation(atOrAbove threshold: Double) -> Bool {
        precipitationRate < threshold && precipitationRiskRate >= threshold
    }

    var effectiveWind: Double { max(wind, gust ?? wind) }
    var compactWindAndGust: String {
        let gustText = gust.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "–"
        return "\(gustText) m/s"
    }

    func precipitationOnset(atOrAbove threshold: Double, after date: Date? = nil) -> Date? {
        radarSamples?.first {
            $0.rate >= threshold && (date == nil || $0.time >= date!)
        }?.time
    }
}

/// Converts liquid-water equivalent from Yr to a rough depth of fresh snow.
/// The temperature-dependent ratio is deliberately capped at 4:1–13:1.
func estimatedFreshSnowMillimeters(waterEquivalent: Double, temperature: Double) -> Double {
    guard waterEquivalent.isFinite, temperature.isFinite else { return 0 }
    let ratio = min(13, max(4.179, 13 * tanh((1 - temperature) / 3)))
    return max(0, waterEquivalent) * ratio
}

enum PlacePreposition: String, Codable, CaseIterable, Identifiable {
    case pa = "på"
    case i = "i"
    case inni
    case oppi
    case borti
    case oppa = "oppå"
    case utpa = "utpå"
    case nerri
    case bortpa = "bortpå"
    case oppmed
    case nedpa = "nedpå"
    case uti
    case innpa = "innpå"
    case frammi
    case nedmed

    var id: String { rawValue }
}

struct Place: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var customName: String? = nil
    var lat: Double
    var lon: Double
    var preposition: PlacePreposition? = nil
    var rules: [Rule] = []
    var notificationsEnabled: Bool? = nil
    var rulesOnlyDisplay: Bool? = nil
    var hiddenAlertTypes: Set<AlertType>? = nil
    var frostMargin: Double? = nil
    var temperatureOffset: Double? = nil
    var displayTemperatureThreshold: Double? = nil
    var displayTemperatureHighThreshold: Double? = nil
    var displayDewThreshold: Double? = nil
    var displaySunThreshold: Double? = nil
    var displaySunThreshold2: Double? = nil
    var displayGustThreshold: Double? = nil
    func displayThreshold(for type: AlertType) -> Double {
        let value: Double?
        switch type {
        case .temperatur: value = displayTemperatureThreshold
        case .dugg: value = displayDewThreshold
        case .sol: value = displaySunThreshold
        case .vind: value = displayGustThreshold
        default: value = nil
        }
        guard let value, value.isFinite else { return type.defaultThreshold }
        return min(type.range.upperBound, max(type.range.lowerBound, value))
    }
    var resolvedDisplayTemperatureThreshold: Double {
        guard let value = displayTemperatureThreshold, value.isFinite else { return AlertType.temperatur.defaultThreshold }
        return min(30, max(-20, value))
    }
    var resolvedDisplayTemperatureHighThreshold: Double {
        guard let value = displayTemperatureHighThreshold, value.isFinite else { return 20 }
        return min(40, max(-10, value))
    }
    var resolvedDisplaySunThreshold2: Double {
        guard let value = displaySunThreshold2, value.isFinite else {
            return min(50, displayThreshold(for: .sol) + 10)
        }
        return min(50, max(0, value))
    }
    var localTemperatureOffset: Double { min(10, max(-10, temperatureOffset ?? 0)) }

    var areNotificationsEnabled: Bool { notificationsEnabled ?? true }
    var showsOnlyRuleAlerts: Bool { rulesOnlyDisplay ?? false }
    var localFrostMargin: Double { max(0, frostMargin ?? 0) }
    /// Number of rules that are currently enabled for this place.
    /// Keeping this calculation in the model prevents list views from
    /// accidentally counting disabled rules after an inline edit.
    var enabledRuleCount: Int { rules.reduce(into: 0) { if $1.enabled { $0 += 1 } } }

    private enum CodingKeys: String, CodingKey {
        case id, name, customName, lat, lon, preposition, rules, notificationsEnabled, rulesOnlyDisplay, hiddenAlertTypes, frostMargin, temperatureOffset, displayTemperatureThreshold, displayTemperatureHighThreshold, displayDewThreshold, displaySunThreshold, displaySunThreshold2, displayGustThreshold
    }

    init(
        id: UUID = UUID(),
        name: String,
        customName: String? = nil,
        lat: Double,
        lon: Double,
        preposition: PlacePreposition? = nil,
        rules: [Rule] = [],
        notificationsEnabled: Bool? = nil,
        rulesOnlyDisplay: Bool? = nil,
        hiddenAlertTypes: Set<AlertType>? = nil,
        frostMargin: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.customName = customName
        self.lat = lat
        self.lon = lon
        self.preposition = preposition
        self.rules = rules
        self.notificationsEnabled = notificationsEnabled
        self.rulesOnlyDisplay = rulesOnlyDisplay
        self.hiddenAlertTypes = hiddenAlertTypes
        self.frostMargin = frostMargin
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(UUID.self, forKey: .id)) ?? UUID()
        // Older or partially written snapshots must not prevent the app from
        // starting. Keep a visible fallback name and neutral coordinates.
        let decodedName = try? values.decode(String.self, forKey: .name)
        name = decodedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? decodedName! : "Ukjent sted"
        customName = try? values.decode(String.self, forKey: .customName)
        lat = (try? values.decode(Double.self, forKey: .lat)).flatMap { $0.isFinite ? $0 : nil } ?? 0
        lon = (try? values.decode(Double.self, forKey: .lon)).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let rawPreposition = try? values.decode(String.self, forKey: .preposition)
        preposition = rawPreposition.flatMap { PlacePreposition(rawValue: $0) }
        rules = (try? values.decode([LossyDecodable<Rule>].self, forKey: .rules))?.compactMap(\.value) ?? []
        notificationsEnabled = try? values.decode(Bool.self, forKey: .notificationsEnabled)
        rulesOnlyDisplay = try? values.decode(Bool.self, forKey: .rulesOnlyDisplay)
        hiddenAlertTypes = (try? values.decode([LossyDecodable<AlertType>].self, forKey: .hiddenAlertTypes))
            .map { Set($0.compactMap(\.value)) }
        frostMargin = try? values.decode(Double.self, forKey: .frostMargin)
        temperatureOffset = try? values.decode(Double.self, forKey: .temperatureOffset)
        displayTemperatureThreshold = try? values.decode(Double.self, forKey: .displayTemperatureThreshold)
        displayTemperatureHighThreshold = try? values.decode(Double.self, forKey: .displayTemperatureHighThreshold)
        displayDewThreshold = try? values.decode(Double.self, forKey: .displayDewThreshold)
        displaySunThreshold = try? values.decode(Double.self, forKey: .displaySunThreshold)
        displaySunThreshold2 = try? values.decode(Double.self, forKey: .displaySunThreshold2)
        displayGustThreshold = try? values.decode(Double.self, forKey: .displayGustThreshold)
    }

    var resolvedPreposition: PlacePreposition {
        if let preposition { return preposition }
        return name.compare("Klinga", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ? .pa : .i
    }

    var nameWithPreposition: String {
        "\(resolvedPreposition.rawValue) \(displayName)"
    }

    var displayName: String {
        let cleaned = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? name : cleaned
    }

    var rulesForDisplay: [Rule] {
        let hidden = hiddenAlertTypes ?? []
        let configured = rules.filter { $0.enabled && !hidden.contains($0.type) }
        guard !showsOnlyRuleAlerts else { return configured }
        let configuredTypes = Set(configured.map(\.type))
        let defaults = AlertType.allCases.filter { !configuredTypes.contains($0) && !hidden.contains($0) }.map { type in
            var rule = Rule(type: type)
            rule.isDisplayOnly = true
            rule.threshold = displayThreshold(for: type)
            return rule
        }
        return configured + defaults
    }

    func isAlertTypeVisible(_ type: AlertType) -> Bool { !(hiddenAlertTypes ?? []).contains(type) }
}

extension Place {
    func distance(to location: CLLocation) -> CLLocationDistance? {
        guard lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        let value = CLLocation(latitude: lat, longitude: lon).distance(from: location)
        return value.isFinite ? value : nil
    }
}

enum PlaceOrdering {
    static func automatic(_ places: [Place], favorite1ID: UUID?, favorite2ID: UUID?, homeID: UUID?) -> [Place] {
        let byID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        let pinned = [favorite1ID, favorite2ID].compactMap { $0 }.compactMap { byID[$0] }
        let pinnedIDs = Set(pinned.map(\.id))
        let home = homeID.flatMap { byID[$0] }
        let homeLocation = home.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        return pinned + places.enumerated().filter { !pinnedIDs.contains($0.element.id) }
            .sorted { lhs, rhs in
                guard let homeLocation else { return lhs.offset < rhs.offset }
                let left = lhs.element.distance(to: homeLocation) ?? .infinity
                let right = rhs.element.distance(to: homeLocation) ?? .infinity
                return left == right ? lhs.offset < rhs.offset : left < right
            }.map(\.element)
    }
}

enum SolarCycle {
    static func isAfterSunset(_ date: Date, latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return false }
        var calendar = Calendar.current
        calendar.timeZone = .current
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let radians = Double.pi / 180
        let declination = 23.44 * sin(radians * (360 / 365 * Double(day - 81)))
        let lat = latitude * radians
        let dec = declination * radians
        let cosine = (cos(90.833 * radians) - sin(lat) * sin(dec)) / (cos(lat) * cos(dec))
        guard cosine < 1 else { return true }
        guard cosine > -1 else { return false }
        let hourAngle = acos(cosine) / radians
        let offsetHours = Double(calendar.timeZone.secondsFromGMT(for: date)) / 3600
        let solarNoon = 12 - longitude / 15 + offsetHours
        let sunset = solarNoon + hourAngle / 15
        let start = calendar.startOfDay(for: date)
        let sunsetDate = start.addingTimeInterval(sunset * 3600)
        return date >= sunsetDate
    }
}

struct PlannedAlert: Identifiable, Hashable {
    let rule: Rule
    let placeID: UUID?
    let placeName: String
    let eventAt: Date
    let fireAt: Date
    let index: Int
    let total: Int
    let quiet: Bool
    let possible: Bool
    let eventDetail: String?
    var id: String {
        let place = placeID?.uuidString ?? "uten-sted"
        let timestamp = Int(fireAt.timeIntervalSince1970)
        return "\(place)-\(rule.id.uuidString)-\(timestamp)-\(index)"
    }
}

struct LogEntry: Codable, Identifiable {
    var id = UUID()
    let time: Date
    let text: String

    private enum CodingKeys: String, CodingKey { case id, time, text }

    init(id: UUID = UUID(), time: Date, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try values.decode(Date.self, forKey: .time)
        text = try values.decode(String.self, forKey: .text)
    }
}

struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

struct WeatherStatus: Codable, Identifiable, Hashable {
    let ruleID: UUID
    let type: AlertType
    let text: String
    let eventAt: Date
    let isNow: Bool
    var possible: Bool? = nil
    var id: UUID { ruleID }
}

extension WeatherStatus {
    static func uniqueByType(_ statuses: [WeatherStatus]) -> [WeatherStatus] {
        statuses.reduce(into: [WeatherStatus]()) { unique, status in
            guard !unique.contains(where: { $0.type == status.type }) else { return }
            unique.append(status)
        }
    }
}

let leadOptions = [15, 30, 60, 120, 180, 360, 720, 1440]
let intervalOptions = [10, 15, 30, 60, 120]
let dayNames = ["Ma", "Ti", "On", "To", "Fr", "Lø", "Sø"]
let fullDayNames = ["mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag", "søndag"]

func minutesLabel(_ m: Int) -> String { m < 60 ? "\(m) min" : "\(m / 60) t" }
func hourLabel(_ hour: Int) -> String { String(format: "%02d", hour) }
func shortClockLabel(_ date: Date, calendar: Calendar = .current) -> String {
    let hour = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    return minute == 0
        ? String(format: "%02d", hour)
        : "\(String(format: "%02d", hour)).\(String(format: "%02d", minute))"
}

func weekdayLabel(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "nb_NO")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "EEEE"
    return formatter.string(from: date)
}

func eventTimePhrase(_ eventAt: Date, relativeTo reference: Date = Date(), calendar: Calendar = .current) -> String {
    let minutes = max(0, Int((eventAt.timeIntervalSince(reference) / 60).rounded()))
    switch minutes {
    case ...7: return "om noen minutter"
    case 8...22: return "om et kvarter"
    case 23...37: return "om en halvtime"
    case 38...52: return "om tre kvarter"
    case 53...89: return "om en time"
    case 90...149: return "om to timer"
    case 150...209: return "om tre timer"
    default: break
    }

    let clock = shortClockLabel(eventAt, calendar: calendar)
    let weekday = weekdayLabel(eventAt, calendar: calendar)
    let eventHour = calendar.component(.hour, from: eventAt)
    let isNight = eventHour < 6
    if calendar.isDate(eventAt, inSameDayAs: reference) {
        if isNight { return "i natt kl. \(clock)" }
        return "i dag kl. \(clock)"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference),
       calendar.isDate(eventAt, inSameDayAs: tomorrow) {
        if isNight { return "i natt kl. \(clock)" }
        return "i morgen, \(weekday) kl. \(clock)"
    }
    if let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: reference),
       calendar.isDate(eventAt, inSameDayAs: dayAfterTomorrow) {
        if isNight { return "natt til \(weekday) kl. \(clock)" }
        return "i overmorgen, \(weekday) kl. \(clock)"
    }
    if isNight { return "natt til \(weekday) kl. \(clock)" }
    return "\(weekday) kl. \(clock)"
}

func alertWeatherName(for rule: Rule) -> String {
    switch rule.type {
    case .regn: "Regn"
    case .frost: "Frost"
    case .temperatur: "Under \(rule.threshold.formatted(.number.precision(.fractionLength(0...1))))°"
    case .sno: "Snø"
    case .vind: "Vindkast"
    case .dugg: "Duggfall"
    case .sol: "Sol"
    }
}

func weatherAlertText(for rule: Rule, eventAt: Date, referenceAt: Date = Date(), possible: Bool = false, durationHours: Int? = nil) -> String {
    let when = eventTimePhrase(eventAt, relativeTo: referenceAt)
    let weather = alertWeatherName(for: rule)
    switch rule.type {
    case .regn, .sno: return possible ? "Mulig \(weather.lowercased()) \(when)." : "\(weather) \(when)."
    case .frost:
        return possible ? "Mulig frost \(when)." : "Frost \(when)."
    case .vind: return "Vindkast \(when)."
    case .temperatur, .dugg: return "\(weather) \(when)."
    case .sol:
        let hours = max(rule.durationHours, durationHours ?? rule.durationHours)
        let duration = "\(hours) \(hours == 1 ? "time" : "timer")"
        return "\(weather) i \(duration) \(when)."
    }
}
func timeLabel(_ d: Date) -> String { d.formatted(.dateTime.hour().minute()) }
func dayLabel(_ d: Date) -> String {
    Calendar.current.isDateInToday(d) ? "i dag" : Calendar.current.isDateInTomorrow(d) ? "i morgen" : d.formatted(.dateTime.weekday(.wide))
}

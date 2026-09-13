import SwiftUI

enum AppCopy {
    static let name = "D bli Vær!"

    static func heading(placeName: String = "") -> String {
        [name, placeName].filter { !$0.isEmpty }.joined(separator: " ")
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
    var id: String { rawValue }
    var label: String { self == .bokmal ? "Bokmål" : "Inntrøndersk" }

    static func persisted(_ value: String) -> AlertLanguageStyle? {
        if let exact = AlertLanguageStyle(rawValue: value) { return exact }
        switch value.lowercased() {
        case "bokmål", "bokmaal": return .bokmal
        case "inntrøndersk", "inntrondersk": return .inntrondersk
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
enum WeatherLanguage {
    static func text(_ text: String, style: AlertLanguageStyle) -> String {
        guard style == .inntrondersk else { return text }
        var result = text
            .replacingOccurrences(of: "i overmorgen", with: "i overmårrå")
            .replacingOccurrences(of: "I overmorgen", with: "I overmårrå")
            .replacingOccurrences(of: "i morgen", with: "i mårrå")
            .replacingOccurrences(of: "I morgen", with: "I mårrå")
            .replacingOccurrences(of: " til ", with: " te ")
        if result.hasPrefix("Mulig ") {
            result = String(result.dropFirst(6))
            result = result.prefix(1).uppercased() + result.dropFirst()
            if result.hasSuffix(".") { result.removeLast() }
            result += ", sjer d ut som."
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
        case .looseObjects: "Vind"
        case .powerful: "Kraftige vindkast"
        case .veryPowerful: "Svært kraftige vindkast"
        case .extreme: "Ekstreme vindkast"
        }
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
        case .dugg: "°C fra dugg"; case .sol: "% sky"
        }
    }
    var defaultThreshold: Double {
        switch self { case .regn: 0.5; case .frost: 0; case .temperatur: 10; case .sno: 0.3; case .vind: 10; case .dugg: 1; case .sol: 20 }
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
        case .vind: h.effectiveWind >= threshold
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
        case .partlyCloudy, .cloudy: Color(red: 0.27, green: 0.45, blue: 0.62)
        }
    }
}

struct Rule: Codable, Identifiable, Hashable {
    var id = UUID()
    var templateTitle: String = ""
    var customName: String = ""
    var memoSuggestion: String = ""
    var type: AlertType
    var threshold: Double
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
        case repeatsEnabled, quiet, quietFrom, quietTo, days, enabled, activeFromHour, activeToHour, onlyWhenNearby, isDisplayOnly
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        templateTitle = try values.decodeIfPresent(String.self, forKey: .templateTitle) ?? ""
        customName = try values.decodeIfPresent(String.self, forKey: .customName) ?? ""
        memoSuggestion = try values.decodeIfPresent(String.self, forKey: .memoSuggestion) ?? ""
        type = try values.decode(AlertType.self, forKey: .type)
        threshold = try values.decodeIfPresent(Double.self, forKey: .threshold) ?? type.defaultThreshold
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
        let effectiveThreshold = type == .frost ? threshold + max(0, frostMargin) : threshold
        return type.matches(hour, threshold: effectiveThreshold)
    }

    var summary: String {
        let t = threshold.formatted(.number.precision(.fractionLength(0...1)))
        return "\(type.label) \(t) \(type.unit)" + (type.needsDuration ? ", \(durationHours) t" : "")
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
        let windText = wind.formatted(.number.precision(.fractionLength(0...1)))
        let gustText = gust.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "–"
        return "\(windText) / \(gustText) m/s"
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
    var localTemperatureOffset: Double { min(10, max(-10, temperatureOffset ?? 0)) }

    var areNotificationsEnabled: Bool { notificationsEnabled ?? true }
    var showsOnlyRuleAlerts: Bool { rulesOnlyDisplay ?? false }
    var localFrostMargin: Double { max(0, frostMargin ?? 0) }

    private enum CodingKeys: String, CodingKey {
        case id, name, customName, lat, lon, preposition, rules, notificationsEnabled, rulesOnlyDisplay, hiddenAlertTypes, frostMargin, temperatureOffset
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
        name = try values.decode(String.self, forKey: .name)
        customName = try? values.decode(String.self, forKey: .customName)
        lat = try values.decode(Double.self, forKey: .lat)
        lon = try values.decode(Double.self, forKey: .lon)
        let rawPreposition = try? values.decode(String.self, forKey: .preposition)
        preposition = rawPreposition.flatMap { PlacePreposition(rawValue: $0) }
        rules = (try? values.decode([LossyDecodable<Rule>].self, forKey: .rules))?.compactMap(\.value) ?? []
        notificationsEnabled = try? values.decode(Bool.self, forKey: .notificationsEnabled)
        rulesOnlyDisplay = try? values.decode(Bool.self, forKey: .rulesOnlyDisplay)
        hiddenAlertTypes = (try? values.decode([LossyDecodable<AlertType>].self, forKey: .hiddenAlertTypes))
            .map { Set($0.compactMap(\.value)) }
        frostMargin = try? values.decode(Double.self, forKey: .frostMargin)
        temperatureOffset = try? values.decode(Double.self, forKey: .temperatureOffset)
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
            return rule
        }
        return configured + defaults
    }

    func isAlertTypeVisible(_ type: AlertType) -> Bool { !(hiddenAlertTypes ?? []).contains(type) }
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
    case .vind: rule.windGustLevel.notificationWeather
    case .dugg: "Duggfall"
    case .sol: "Sol"
    }
}

func weatherAlertText(for rule: Rule, eventAt: Date, referenceAt: Date = Date(), possible: Bool = false) -> String {
    let when = eventTimePhrase(eventAt, relativeTo: referenceAt)
    let weather = alertWeatherName(for: rule)
    switch rule.type {
    case .regn, .sno: return possible ? "Mulig \(weather.lowercased()) \(when)." : "\(weather) \(when)."
    case .frost:
        return possible ? "Mulig frost \(when)." : "Frost \(when)."
    case .vind: return "Vindkast \(when)."
    case .temperatur, .dugg: return "\(weather) \(when)."
    case .sol:
        let duration = "\(rule.durationHours) \(rule.durationHours == 1 ? "time" : "timer")"
        return "\(weather) i \(duration) \(when)."
    }
}
func timeLabel(_ d: Date) -> String { d.formatted(.dateTime.hour().minute()) }
func dayLabel(_ d: Date) -> String {
    Calendar.current.isDateInToday(d) ? "i dag" : Calendar.current.isDateInTomorrow(d) ? "i morgen" : d.formatted(.dateTime.weekday(.wide))
}

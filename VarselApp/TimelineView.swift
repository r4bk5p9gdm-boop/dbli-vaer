import SwiftUI

enum ForecastDisplayMode: Int, CaseIterable, Identifiable {
    case timeCards = 1
    case weatherBands = 2
    case events = 3

    var id: Int { rawValue }
    var shortLabel: String {
        switch self {
        case .timeCards: "1 Timekort"
        case .weatherBands: "2 Værbånd"
        case .events: "3 Hendelser"
        }
    }
}

struct ForecastVariantsView: View {
    let forecast: [ForecastHour]
    let rules: [Rule]
    let frostMargin: Double
    let mode: ForecastDisplayMode
    let sunThreshold2: Double
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double

    private var days: [ForecastDay] { ForecastDay.make(from: forecast) }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 4) {
                    if !Calendar.current.isDate(day.date, inSameDayAs: weatherDayDate(for: Date())) {
                        ForecastDayHeader(day: day)
                    }
                    switch mode {
                    case .timeCards:
                        TimeCardsForecast(day: day, allForecast: forecast, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold)
                    case .weatherBands:
                        SwiftUI.TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            WeatherBandsForecast(day: day, rules: rules, frostMargin: frostMargin, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, now: timeline.date)
                        }
                    case .events:
                        WeatherEventsForecast(day: day, rules: rules, frostMargin: frostMargin)
                    }
                }
                .padding(9)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }

            VStack(alignment: .leading, spacing: 3) {
                if mode == .weatherBands {
                    Text("Helfarget = hovedvarsel · lyst = mulig ut fra maks og sannsynlighet")
                }
                HStack {
                    Text(forecast.contains { !(($0.radarSamples ?? []).isEmpty) }
                         ? "Nå-varsel 90 min · komplett timevarsel videre"
                         : mode.footer)
                    Spacer()
                    Text("48 timer maks")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private extension ForecastDisplayMode {
    var footer: String {
        switch self {
        case .timeCards: "Temperatur og nedbør i 3-timers steg"
        case .weatherBands: "Når aktive regler slår til"
        case .events: "Bare værhendelser som betyr noe"
        }
    }
}

private struct ForecastDay: Identifiable {
    let date: Date
    let hours: [ForecastHour]
    var id: Date { date }

    static func make(from forecast: [ForecastHour], calendar: Calendar = .current) -> [ForecastDay] {
        // A weather day runs from 07 to 07 so the final band can be the whole night.
        let grouped = Dictionary(grouping: forecast) { weatherDayDate(for: $0.time, calendar: calendar) }
        return grouped.keys.sorted().map { date in
            ForecastDay(date: date, hours: grouped[date, default: []].sorted { $0.time < $1.time })
        }
    }
}

private func weatherDayDate(for date: Date, calendar: Calendar = .current) -> Date {
    let calendarDay = calendar.startOfDay(for: date)
    guard calendar.component(.hour, from: date) < 7 else { return calendarDay }
    return calendar.date(byAdding: .day, value: -1, to: calendarDay) ?? calendarDay
}

private struct WeatherBandPeriod: Identifiable {
    let startHour: Int
    let label: String
    let isNight: Bool
    var id: Int { startHour }

    static let all = [
        WeatherBandPeriod(startHour: 7, label: "Dag", isNight: false),
        WeatherBandPeriod(startHour: 15, label: "Kveld", isNight: false),
        WeatherBandPeriod(startHour: 23, label: "Natt", isNight: true),
    ]
}

private func hourOffset(_ hour: Int, from startHour: Int) -> Int {
    (hour - startHour + 24) % 24
}

private struct ForecastDayHeader: View {
    let day: ForecastDay

    var body: some View {
        Text(dayTitle(day.date))
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayTitle(_ date: Date) -> String {
        let today = weatherDayDate(for: Date())
        let calendar = Calendar.current
        let dayNumber = calendar.component(.day, from: date)
        let monthNames = ["", "jan", "feb", "mars", "apr", "mai", "juni", "juli", "aug", "sept", "okt", "nov", "des"]
        let dateText = "\(dayNumber). \(monthNames[calendar.component(.month, from: date)])"
        if calendar.isDate(date, inSameDayAs: today) {
            let value = weekdayLabel(date)
            let weekday = value.prefix(1).uppercased() + value.dropFirst()
            return "Resten av i dag, \(weekday) \(dateText)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "I morgen, \(dateText)" }
        let value = weekdayLabel(date)
        let weekday = value.prefix(1).uppercased() + value.dropFirst()
        return "\(weekday) \(dateText)"
    }
}

private struct TimeCardsForecast: View {
    let day: ForecastDay
    let allForecast: [ForecastHour]
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double

    private var sampled: [ForecastHour] {
        day.hours.enumerated().compactMap { index, hour in index % 3 == 0 ? hour : nil }
    }
    private var rainScale: Double {
        max(allForecast.map(\.precipitationRate).max() ?? 0, 1)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 7) {
                ForEach(sampled) { hour in
                    VStack(spacing: 6) {
                        Text(hourClock(hour.time))
                            .font(.caption.weight(.semibold))
                        Image(systemName: forecastSymbol(hour))
                            .font(.title3)
                            .symbolRenderingMode(.multicolor)
                            .frame(height: 24)
                        Text(compactTemperatureText(hour.temp))
                            .font(.caption)
                            .foregroundStyle(hour.temp <= temperatureLowThreshold ? Color.secondary : hour.temp >= temperatureHighThreshold ? Color.orange : Color.primary)
                            .accessibilityLabel("Temperatur \(Int(hour.temp.rounded())) grader")
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.08))
                            RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.75))
                            .frame(height: max(2, 34 * hour.precipitationRate / rainScale))
                        }
                        .frame(height: 34)
                        Text(hour.precip >= 0.1 ? hour.precip.formatted(.number.precision(.fractionLength(0...1))) : " ")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    .frame(width: 45)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Klokken \(hourClock(hour.time)), \(Int(hour.temp.rounded())) grader, \(hour.precip.formatted()) millimeter nedbør")
                }
            }
        }
    }
}

private struct WeatherBandsForecast: View {
    let day: ForecastDay
    let rules: [Rule]
    let frostMargin: Double
    let sunThreshold2: Double
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double
    let now: Date

    private let labelWidth: CGFloat = 85
    private var moistureRules: [Rule] {
        rules.filter { [.regn, .sno, .dugg].contains($0.type) }
    }
    private var otherRules: [Rule] {
        rules.filter { ![.regn, .sno, .dugg].contains($0.type) }
    }

    private var isToday: Bool {
        Calendar.current.isDate(day.date, inSameDayAs: weatherDayDate(for: now))
    }

    private var nowFraction: CGFloat {
        let calendar = Calendar.current
        let logicalDay = weatherDayDate(for: now, calendar: calendar)
        let start = calendar.date(byAdding: .hour, value: 7, to: logicalDay) ?? logicalDay
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return min(max(now.timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    let labelWidth: CGFloat = 78
                    let trackWidth = max(0, proxy.size.width - labelWidth)
                    ZStack(alignment: .topLeading) {
                        let markers = [7, 15, 23, 7]
                        ForEach(Array(markers.enumerated()), id: \.offset) { index, hour in
                            Text(String(format: "%02d", hour))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                                .position(
                                    x: labelWidth + trackWidth * CGFloat(index) / 3,
                                    y: 6
                                )
                        }
                    }
                }
                .frame(height: 12)

                if rules.isEmpty {
                    Text("Ingen varsler er aktivert.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if !moistureRules.isEmpty {
                        HStack(spacing: 7) {
                            WeatherBandLabel(
                                title: "Nedbør",
                                systemImage: "drop.fill",
                                color: AlertType.regn.color,
                                showsNotification: moistureRules.contains(where: { !$0.isDisplayOnly })
                            )
                            MoistureBandTrack(day: day, rules: moistureRules)
                        }
                    }
                    ForEach(AlertType.allCases.filter { type in
                        otherRules.contains { $0.type == type }
                    }) { type in
                        let typeRules = otherRules.filter { $0.type == type }
                        HStack(spacing: 7) {
                            WeatherBandLabel(
                                title: type.label,
                                systemImage: type.systemImage,
                                color: type.color,
                                showsNotification: typeRules.contains(where: { !$0.isDisplayOnly })
                            )
                            CombinedDayBandTrack(day: day, rules: typeRules, type: type, frostMargin: frostMargin, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold)
                        }
                    }
                }
            }

            if isToday, !rules.isEmpty {
                GeometryReader { proxy in
                    let trackWidth = max(0, proxy.size.width - labelWidth)
                    let markerX = labelWidth + trackWidth * nowFraction

                    Rectangle()
                        .fill(Color.secondary.opacity(0.07))
                        .frame(width: trackWidth * nowFraction, height: max(0, proxy.size.height - 29))
                        .offset(x: labelWidth, y: 29)

                    VStack(spacing: 1) {
                        Color.clear.frame(height: 15)
                        Capsule()
                            .fill(Color.orange)
                            .frame(width: 2)
                        Text("nå")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.orange)
                    }
                    .frame(height: proxy.size.height)
                    .position(x: markerX, y: proxy.size.height / 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Nå er klokken \(now.formatted(.dateTime.hour().minute()))")
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private struct WeatherBandLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    let showsNotification: Bool

    var body: some View {
        HStack(spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsNotification {
                Image(systemName: "bell.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.orange))
                    .accessibilityLabel("Pushvarsel aktivert for \(title)")
            }
        }
        .font(.caption)
        .lineLimit(1)
        .frame(width: 78, alignment: .leading)
    }
}

private struct CombinedDayBandTrack: View {
    let day: ForecastDay
    let rules: [Rule]
    let type: AlertType
    let frostMargin: Double
    let sunThreshold2: Double
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(WeatherBandPeriod.all) { period in
                CombinedHourBandCell(hours: day.hours, rules: rules, type: type, period: period, frostMargin: frostMargin, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold)
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(type.label), samlet fra \(rules.count) \(rules.count == 1 ? "regel" : "regler")")
    }
}

private struct CombinedHourBandCell: View {
    let hours: [ForecastHour]
    let rules: [Rule]
    let type: AlertType
    let period: WeatherBandPeriod
    let frostMargin: Double
    let sunThreshold2: Double
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(period.isNight ? Color.gray.opacity(0.18) : Color.secondary.opacity(0.11))
                ForEach(hours) { hour in
                    let hourNumber = Calendar.current.component(.hour, from: hour.time)
                    let offset = hourOffset(hourNumber, from: period.startHour)
                    let matchesSunPreview = type == .sol && hour.cloud <= sunThreshold2
                    let matchesTemperaturePreview = type == .temperatur && (hour.temp <= temperatureLowThreshold || hour.temp >= temperatureHighThreshold)
                    if offset < 8, matchesSunPreview || matchesTemperaturePreview || rules.contains(where: {
                        $0.isActive(at: hour.time) && $0.matches(hour, frostMargin: frostMargin)
                    }) {
                        Rectangle()
                            .fill(type == .temperatur && hour.temp >= temperatureHighThreshold
                                  ? Color.orange.opacity(0.78)
                                  : type.color.opacity(type == .sol && hour.cloud > sunThreshold2 ? 0.35 : 0.78))
                            .frame(width: proxy.size.width / 8 + 0.5)
                            .offset(x: proxy.size.width * CGFloat(offset) / 8)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct MoistureBandTrack: View {
    let day: ForecastDay
    let rules: [Rule]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(WeatherBandPeriod.all) { period in
                MoistureHourBandCell(hours: day.hours, rules: rules, period: period)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Regnrad: regn, snø og fare for dugg vises med egne farger")
    }
}

private struct MoistureHourBandCell: View {
    let hours: [ForecastHour]
    let rules: [Rule]
    let period: WeatherBandPeriod

    private func matchingRule(of type: AlertType, for hour: ForecastHour) -> Rule? {
        rules.first { rule in
            rule.type == type
                && rule.isActive(at: hour.time)
                && rule.type.matches(hour, threshold: rule.threshold)
        }
    }

    private func fill(for rule: Rule, at hour: ForecastHour) -> Color {
        // Use the shared AlertType color so row bands match every icon surface.
        let canBePossible = rule.type == .regn || rule.type == .sno
        let opacity = canBePossible && hour.isPossiblePrecipitation(atOrAbove: rule.threshold) ? 0.34 : 0.82
        return rule.type.color.opacity(opacity)
    }

    private func hadRecentPrecipitation(before hour: ForecastHour) -> Bool {
        let start = hour.time.addingTimeInterval(-3 * 3_600)
        return hours.contains { candidate in
            candidate.time >= start
                && candidate.time <= hour.time
                && candidate.precipitationRiskRate >= 0.1
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(period.isNight ? Color.gray.opacity(0.18) : Color.secondary.opacity(0.11))
                ForEach(hours) { hour in
                    let hourNumber = Calendar.current.component(.hour, from: hour.time)
                    let offset = hourOffset(hourNumber, from: period.startHour)
                    if offset < 8 {
                        let precipitationRule = matchingRule(of: .sno, for: hour) ?? matchingRule(of: .regn, for: hour)
                        let dewRule = matchingRule(of: .dugg, for: hour)
                        let x = proxy.size.width * CGFloat(offset) / 8

                        if let precipitationRule {
                            Rectangle()
                                .fill(fill(for: precipitationRule, at: hour))
                                .frame(width: proxy.size.width / 8 + 0.5, height: proxy.size.height)
                                .offset(x: x)
                        } else if hour.precipitationRate >= 0.1 && hour.temp > 1 {
                            Rectangle()
                                .fill(AlertType.regn.color.opacity(0.48))
                                .frame(width: proxy.size.width / 8 + 0.5, height: proxy.size.height)
                                .offset(x: x)
                        } else if let dewRule, !hadRecentPrecipitation(before: hour) {
                            Rectangle()
                                .fill(fill(for: dewRule, at: hour))
                                .frame(width: proxy.size.width / 8 + 0.5, height: proxy.size.height)
                                .offset(x: x)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct DayBandTrack: View {
    let day: ForecastDay
    let rule: Rule

    var body: some View {
        HStack(spacing: 3) {
            ForEach(WeatherBandPeriod.all) { period in
                HourBandCell(hours: day.hours, rule: rule, period: period)
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let matching = day.hours.filter {
            rule.isActive(at: $0.time) && rule.type.matches($0, threshold: rule.threshold)
        }
        guard let first = matching.first, let last = matching.last else {
            return "\(rule.type.label) slår ikke til denne dagen"
        }
        return "\(rule.type.label) fra klokken \(hourClock(first.time)) til \(hourClock(last.time.addingTimeInterval(3_600)))"
    }
}

private struct HourBandCell: View {
    let hours: [ForecastHour]
    let rule: Rule
    let period: WeatherBandPeriod

    private var matchingHours: [ForecastHour] {
        hours.filter { hour in
            let number = Calendar.current.component(.hour, from: hour.time)
            return hourOffset(number, from: period.startHour) < 8
                && rule.isActive(at: hour.time)
                && rule.type.matches(hour, threshold: rule.threshold)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(period.isNight ? Color.gray.opacity(0.18) : Color.secondary.opacity(0.11))
                ForEach(matchingHours) { hour in
                    let hourNumber = Calendar.current.component(.hour, from: hour.time)
                    let offset = hourOffset(hourNumber, from: period.startHour)
                    Rectangle()
                        .fill(rule.type.color.opacity(hour.isPossiblePrecipitation(atOrAbove: rule.threshold) ? 0.30 : 0.78))
                        .frame(width: proxy.size.width / 8 + 0.5)
                        .offset(x: proxy.size.width * CGFloat(offset) / 8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct WeatherEventsForecast: View {
    let day: ForecastDay
    let rules: [Rule]
    let frostMargin: Double

    private var events: [ForecastEvent] {
        rules.flatMap { forecastEvents(for: $0, hours: day.hours, frostMargin: frostMargin) }.sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(spacing: 0) {
            if events.isEmpty {
                Text("Ingen relevante værhendelser denne dagen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(events) { event in
                    HStack(spacing: 10) {
                        Image(systemName: event.rule.type.systemImage)
                            .foregroundStyle(event.rule.type.color)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.subheadline.weight(.semibold))
                            Text(event.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text("\(event.duration)t")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    if event.id != events.last?.id { Divider() }
                }
            }
        }
    }
}

private struct HourSegment: Identifiable {
    let startIndex: Int
    let count: Int
    let total: Int
    var id: String { "\(startIndex)-\(count)" }
    var startFraction: Double { Double(startIndex) / Double(max(total, 1)) }
    var lengthFraction: Double { Double(count) / Double(max(total, 1)) }
}

private struct ForecastEvent: Identifiable {
    let rule: Rule
    let start: Date
    let matchingHours: [ForecastHour]
    var id: String { "\(rule.id)-\(start.timeIntervalSince1970)" }
    var duration: Int { matchingHours.count }

    var title: String {
        let timing = start <= Date().addingTimeInterval(3_600) ? "nå" : "fra kl. \(hourClock(start))"
        return switch rule.type {
        case .regn: "Regn \(timing)"
        case .frost: "Frost \(timing)"
        case .temperatur: "Under \(rule.threshold.formatted(.number.precision(.fractionLength(0...1))))° \(timing)"
        case .sno: "Snø \(timing)"
        case .vind: "Vind \(timing)"
        case .dugg: "Fare for dugg \(timing)"
        case .sol: "Sol \(timing)"
        }
    }

    var detail: String {
        guard let last = matchingHours.last else { return "" }
        let until = "fram til kl. \(hourClock(last.time.addingTimeInterval(3_600)))"
        switch rule.type {
        case .regn:
            let total = matchingHours.reduce(0) { $0 + $1.precip }
            return "ca. \(total.formatted(.number.precision(.fractionLength(0...1)))) mm \(until)"
        case .sno:
            let total = matchingHours.reduce(0.0) { result, hour in
                result + estimatedFreshSnowMillimeters(waterEquivalent: hour.precip, temperature: hour.temp)
            }
            return "anslått \(total.formatted(.number.precision(.fractionLength(0...1)))) mm snø \(until)"
        case .frost:
            let lowest = matchingHours.map(\.temp).min() ?? 0
            return "ned mot \(Int(lowest.rounded()))° \(until)"
        case .temperatur:
            let lowest = matchingHours.map(\.temp).min() ?? 0
            return "ned mot \(lowest.formatted(.number.precision(.fractionLength(0...1))))° \(until)"
        case .vind:
            let strongest = matchingHours.compactMap(\.gust).max() ?? 0
            return "opp mot \(strongest.formatted(.number.precision(.fractionLength(0...1)))) m/s \(until)"
        case .dugg:
            let closest = matchingHours.map { $0.temp - $0.dew }.min() ?? 0
            return "\(closest.formatted(.number.precision(.fractionLength(0...1))))° fra duggpunkt \(until)"
        case .sol:
            return "lite skyer \(until)"
        }
    }
}

private func matchingSegments(rule: Rule, hours: [ForecastHour], frostMargin: Double = 0) -> [HourSegment] {
    var result: [HourSegment] = []
    var start: Int?
    for index in 0...hours.count {
        let matches = index < hours.count && rule.isActive(at: hours[index].time) && rule.matches(hours[index], frostMargin: frostMargin)
        if matches, start == nil { start = index }
        if !matches, let first = start {
            result.append(HourSegment(startIndex: first, count: index - first, total: hours.count))
            start = nil
        }
    }
    return result
}

private func forecastEvents(for rule: Rule, hours: [ForecastHour], frostMargin: Double = 0) -> [ForecastEvent] {
    matchingSegments(rule: rule, hours: hours, frostMargin: frostMargin).compactMap { segment in
        guard segment.startIndex < hours.count else { return nil }
        let matching = Array(hours[segment.startIndex..<min(segment.startIndex + segment.count, hours.count)])
        guard !rule.type.needsDuration || matching.count >= rule.durationHours else { return nil }
        return ForecastEvent(rule: rule, start: matching[0].time, matchingHours: matching)
    }
}

private func hourClock(_ date: Date) -> String {
    String(format: "%02d", localHourComponent(date))
}

/// Uses the user's current calendar/time zone, so forecast labels do not drift
/// when a UTC timestamp crosses local midnight or a DST boundary.
func localHourComponent(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
    calendar.component(.hour, from: date)
}

func forecastSymbol(_ hour: ForecastHour) -> String {
    if hour.precipitationRate >= 0.1 { return hour.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill" }
    if hour.cloud <= 20 { return "sun.max.fill" }
    if hour.cloud <= 65 { return "cloud.sun.fill" }
    return "cloud.fill"
}

struct TimelineView: View {
    let forecast: [ForecastHour]
    let rules: [Rule]
    let placeName: String
    var frostMargin: Double = 0
    var height: CGFloat = 64

    var body: some View {
        Canvas { ctx, size in
            let n = max(forecast.count, 1)
            let colW = size.width / CGFloat(n)
            let plans = rules.map { ($0, Planner.plan(rule: $0, forecast: forecast, placeName: placeName, frostMargin: frostMargin)) }
            let start = forecast.first?.time ?? Date()

            for (i, h) in forecast.enumerated() {
                let x = CGFloat(i) * colW
                let fill: Color = h.precip > 0 ? Color(red: 0.84, green: 0.89, blue: 0.98)
                    : h.cloud < 25 ? Color(red: 1.0, green: 0.95, blue: 0.83) : Color(red: 0.89, green: 0.92, blue: 0.95)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: colW - 1, height: height), cornerRadius: 2), with: .color(fill))
                var j = 0
                for (r, p) in plans where p.hitIndices.contains(i) {
                    ctx.fill(Path(CGRect(x: x, y: height - 8 - CGFloat(j) * 6, width: colW - 1, height: 5)), with: .color(r.type.color))
                    j += 1
                }
                let hour = Calendar.current.component(.hour, from: h.time)
                if hour % 6 == 0 {
                    ctx.draw(Text(hour == 0 ? "i morgen" : "\(hour)").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 2, y: height + 8), anchor: .leading)
                }
            }
            for (r, p) in plans {
                for a in p.alerts {
                    let x = CGFloat(a.fireAt.timeIntervalSince(start) / 3600) * colW
                    var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: height))
                    ctx.stroke(path, with: .color(a.quiet ? .secondary : r.type.color), style: StrokeStyle(lineWidth: 2, dash: a.quiet ? [3, 3] : []))
                }
            }
            var nowLine = Path(); nowLine.move(to: .zero); nowLine.addLine(to: CGPoint(x: 0, y: height))
            ctx.stroke(nowLine, with: .color(.primary), lineWidth: 2)
        }
        .frame(height: height + 20)
    }
}

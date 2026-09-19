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
    let latitude: Double
    let longitude: Double

    private var days: [ForecastDay] { ForecastDay.make(from: forecast) }
    private var visibleDays: [ForecastDay] {
        let calendar = Calendar.current
        let now = Date()
        guard calendar.component(.hour, from: now) >= 5,
              calendar.component(.hour, from: now) < 7 else { return days }
        let today = calendar.startOfDay(for: now)
        return days.filter { $0.date >= today }
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(visibleDays, id: \.id) { day in
                VStack(alignment: .leading, spacing: 4) {
                    if !Calendar.current.isDate(day.date, inSameDayAs: Calendar.current.startOfDay(for: Date())) {
                        ForecastDayHeader(day: day)
                    }
                    switch mode {
                    case .timeCards:
                        TimeCardsForecast(day: day, allForecast: forecast, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold)
                    case .weatherBands:
                        SwiftUI.TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            WeatherBandsForecast(day: day, rules: rules, frostMargin: frostMargin, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, latitude: latitude, longitude: longitude, now: timeline.date)
                        }
                    case .events:
                        WeatherEventsForecast(day: day, rules: rules, frostMargin: frostMargin)
                    }
                }
                .padding(9)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }

        }
    }
}

private struct ForecastDay: Identifiable {
    let date: Date
    let hours: [ForecastHour]
    var id: Date { date }

    static func make(from forecast: [ForecastHour], calendar: Calendar = .current) -> [ForecastDay] {
        // Day headers follow calendar days. The bands themselves still cover
        // 07–15–23–07, so the overnight segment remains visually connected.
        let grouped = Dictionary(grouping: forecast) { calendar.startOfDay(for: $0.time) }
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
    let hours: Int
    var id: Int { startHour }

    static let earlyMorning = WeatherBandPeriod(startHour: 5, label: "", isNight: true, hours: 2)

    static let all = [
        WeatherBandPeriod(startHour: 7, label: "Dag", isNight: false, hours: 8),
        WeatherBandPeriod(startHour: 15, label: "Kveld", isNight: false, hours: 8),
        WeatherBandPeriod(startHour: 23, label: "Natt", isNight: true, hours: 8),
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
        let today = Calendar.current.startOfDay(for: Date())
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
    let latitude: Double
    let longitude: Double
    let now: Date

    private let labelWidth: CGFloat = 85
    private var moistureRules: [Rule] {
        rules.filter { [.regn, .sno, .dugg].contains($0.type) }
    }
    private var otherRules: [Rule] {
        rules.filter { ![.regn, .sno, .dugg, .frost].contains($0.type) }
    }
    private var temperatureRules: [Rule] {
        otherRules.filter { $0.type == .temperatur } + rules.filter { $0.type == .frost }
    }
    private var displayedTypes: [AlertType] {
        AlertType.allCases.filter { type in
            otherRules.contains { $0.type == type } || (type == .temperatur && !temperatureRules.isEmpty)
        }
    }

    private func rulesForType(_ type: AlertType) -> [Rule] {
        type == .temperatur ? temperatureRules : otherRules.filter { $0.type == type }
    }

    private var isToday: Bool {
        Calendar.current.isDate(day.date, inSameDayAs: Calendar.current.startOfDay(for: now))
    }

    private var isMorningCompression: Bool {
        (5...6).contains(Calendar.current.component(.hour, from: now))
    }

    /// Only today's row gets real 05–07 data. Later days use three slightly
    /// narrower, trailing-aligned bands while this mode is active, preserving
    /// the 07–15–23–07 column boundaries without inventing an extra cell.
    private var includesEarlyMorningCell: Bool {
        isToday && isMorningCompression
    }

    private var nowFraction: CGFloat {
        let calendar = Calendar.current
        if includesEarlyMorningCell {
            let startOfToday = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .hour, value: 5, to: startOfToday) ?? startOfToday
            // 05–07 occupies two of the 26 visual hour cells.
            return min(max(now.timeIntervalSince(start) / (26 * 3_600), 0), 2.0 / 26.0)
        }
        let logicalDay = includesEarlyMorningCell ? calendar.startOfDay(for: now) : weatherDayDate(for: now, calendar: calendar)
        let startHour = includesEarlyMorningCell ? 5 : 7
        let start = calendar.date(byAdding: .hour, value: startHour, to: logicalDay) ?? logicalDay
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
                        let markers: [(hour: Int, fraction: CGFloat)] = isMorningCompression
                            ? [(7, 2.0 / 26.0), (15, 10.0 / 26.0), (23, 18.0 / 26.0), (7, 1)]
                            : [(7, 0), (15, 1.0 / 3.0), (23, 2.0 / 3.0), (7, 1)]
                        ForEach(Array(markers.enumerated()), id: \.offset) { _, marker in
                            Text(String(format: "%02d", marker.hour))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                                .position(
                                    x: labelWidth + trackWidth * marker.fraction,
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
                            MoistureBandTrack(day: day, rules: moistureRules, includeEarlyMorning: includesEarlyMorningCell, compressForMorning: isMorningCompression && !isToday)
                        }
                    }
                    ForEach(displayedTypes) { type in
                        let typeRules = rulesForType(type)
                        HStack(spacing: 7) {
                            WeatherBandLabel(
                                title: type.label,
                                systemImage: type == .temperatur && typeRules.contains(where: { $0.type == .frost })
                                    ? "thermometer.snowflake"
                                    : type.systemImage,
                                color: type.color,
                                showsNotification: typeRules.contains(where: { !$0.isDisplayOnly })
                            )
                            CombinedDayBandTrack(day: day, rules: typeRules, type: type, frostMargin: frostMargin, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, latitude: latitude, longitude: longitude, includeEarlyMorning: includesEarlyMorningCell, compressForMorning: isMorningCompression && !isToday)
                        }
                    }
                }
            }

            if isToday, !rules.isEmpty {
                GeometryReader { proxy in
                    let trackWidth = max(0, proxy.size.width - labelWidth)
                    let markerX = labelWidth + trackWidth * nowFraction
                    // Headeren er 12 pt høy med 6 pt mellomrom før første
                    // vær-rad. Nå-streken skal dekke alle radene, men ikke
                    // starte nede i første rad slik den gjorde med 29 pt.
                    let bandsTop: CGFloat = 18
                    let bandsHeight = max(0, proxy.size.height - bandsTop)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.07))
                        .frame(width: trackWidth * nowFraction, height: bandsHeight)
                        .offset(x: labelWidth, y: bandsTop)

                    Capsule()
                        .fill(Color.orange)
                        .frame(width: 2, height: bandsHeight)
                        .position(x: markerX, y: bandsTop + bandsHeight / 2)

                    Text("nå")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.orange)
                        .position(x: markerX, y: proxy.size.height + 5)
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
    let latitude: Double
    let longitude: Double
    let includeEarlyMorning: Bool
    let compressForMorning: Bool

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let gapCount: CGFloat = includeEarlyMorning ? 3 : 2
            let availableWidth = max(0, proxy.size.width - spacing * gapCount)
            let totalHours: CGFloat = (includeEarlyMorning || compressForMorning) ? 26 : 24
            HStack(spacing: spacing) {
                if includeEarlyMorning {
                    CombinedHourBandCell(hours: day.hours, rules: rules, type: type, period: .earlyMorning, frostMargin: frostMargin, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, latitude: latitude, longitude: longitude)
                        .frame(width: availableWidth * 2 / 26)
                }
                ForEach(WeatherBandPeriod.all) { period in
                    CombinedHourBandCell(hours: day.hours, rules: rules, type: type, period: period, frostMargin: frostMargin, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, latitude: latitude, longitude: longitude)
                        .frame(width: availableWidth * 8 / totalHours)
                }
            }
            .frame(maxWidth: .infinity, alignment: compressForMorning ? .trailing : .leading)
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
    let latitude: Double
    let longitude: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(period.isNight ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.08))
                ForEach(hours) { hour in
                    let hourNumber = Calendar.current.component(.hour, from: hour.time)
                    let offset = hourOffset(hourNumber, from: period.startHour)
                    let matchesSunPreview = type == .sol && !SolarCycle.isAfterSunset(hour.time, latitude: latitude, longitude: longitude) && hour.cloud <= sunThreshold2
                    let matchesTemperaturePreview = type == .temperatur && (hour.temp <= temperatureLowThreshold || hour.temp >= temperatureHighThreshold)
                    let matchesFrost = type == .temperatur && rules.contains(where: {
                        $0.type == .frost && $0.isActive(at: hour.time) && $0.matches(hour, frostMargin: frostMargin)
                    })
                    if offset < period.hours, matchesSunPreview || matchesTemperaturePreview || (type != .sol && rules.contains(where: {
                        $0.isActive(at: hour.time) && $0.matches(hour, frostMargin: frostMargin)
                    })) {
                        Rectangle()
                            .fill(type == .temperatur && hour.temp >= temperatureHighThreshold
                                  ? Color.orange.opacity(0.78)
                                  : type == .temperatur && hour.temp <= 0
                                  ? Color.white.opacity(0.92)
                                  : type.color.opacity(type == .sol && hour.cloud > sunThreshold2 ? 0.35 : 0.78))
                            .frame(width: proxy.size.width / CGFloat(period.hours) + 0.5)
                            .offset(x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours))
                        if matchesFrost {
                            Image(systemName: AlertType.frost.systemImage)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(hour.temp <= 0 ? Color.blue : Color.white)
                                    .frame(width: proxy.size.width / CGFloat(period.hours), height: proxy.size.height)
                                    .position(
                                    x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours) + proxy.size.width / CGFloat(period.hours * 2),
                                    y: proxy.size.height / 2
                                )
                        }
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
    let includeEarlyMorning: Bool
    let compressForMorning: Bool

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let gapCount: CGFloat = includeEarlyMorning ? 3 : 2
            let availableWidth = max(0, proxy.size.width - spacing * gapCount)
            let totalHours: CGFloat = (includeEarlyMorning || compressForMorning) ? 26 : 24
            HStack(spacing: spacing) {
                if includeEarlyMorning {
                    MoistureHourBandCell(hours: day.hours, rules: rules, period: .earlyMorning)
                        .frame(width: availableWidth * 2 / 26)
                }
                ForEach(WeatherBandPeriod.all) { period in
                    MoistureHourBandCell(hours: day.hours, rules: rules, period: period)
                        .frame(width: availableWidth * 8 / totalHours)
                }
            }
            .frame(maxWidth: .infinity, alignment: compressForMorning ? .trailing : .leading)
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
                    .fill(period.isNight ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.08))
                ForEach(hours) { hour in
                    let hourNumber = Calendar.current.component(.hour, from: hour.time)
                    let offset = hourOffset(hourNumber, from: period.startHour)
                    if offset < period.hours {
                        let precipitationRule = matchingRule(of: .sno, for: hour) ?? matchingRule(of: .regn, for: hour)
                        let dewRule = matchingRule(of: .dugg, for: hour)
                        let x = proxy.size.width * CGFloat(offset) / CGFloat(period.hours)

                        if let precipitationRule {
                            Rectangle()
                                .fill(fill(for: precipitationRule, at: hour))
                                .frame(width: proxy.size.width / CGFloat(period.hours) + 0.5, height: proxy.size.height)
                                .offset(x: x)
                        } else if hour.precipitationRate >= 0.1 && hour.temp > 1 {
                            Rectangle()
                                .fill(AlertType.regn.color.opacity(0.48))
                                .frame(width: proxy.size.width / CGFloat(period.hours) + 0.5, height: proxy.size.height)
                                .offset(x: x)
                        } else if let dewRule, !hadRecentPrecipitation(before: hour) {
                            Rectangle()
                                .fill(fill(for: dewRule, at: hour))
                                .frame(width: proxy.size.width / CGFloat(period.hours) + 0.5, height: proxy.size.height)
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
                    .fill(period.isNight ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.08))
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

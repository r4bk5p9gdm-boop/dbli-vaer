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
    var languageStyle: AlertLanguageStyle = .bokmal
    let frostMargin: Double
    let mode: ForecastDisplayMode
    let sunThreshold: Double
    let sunThreshold2: Double
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double
    var displayDewThreshold: Double = AlertType.dugg.defaultThreshold
    var displayGustThreshold: Double = AlertType.vind.defaultThreshold
    let latitude: Double
    let longitude: Double
    let todayTitle: String
    let updatedAt: Date?
    let isRefreshing: Bool
    let isStale: Bool

    private var days: [ForecastDay] { ForecastDay.make(from: forecast) }
    private var visibleDays: [ForecastDay] {
        ForecastDaySelection.visibleDays(from: days, now: Date())
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(visibleDays, id: \.id) { day in
                let isToday = Calendar.current.isDate(day.date, inSameDayAs: Calendar.current.startOfDay(for: Date()))
                ForecastDayFrame(
                    title: isToday ? todayTitle : forecastDayTitle(day.date),
                    sourceText: isToday ? "Yr.no" + (updatedAt.map { " · \(timeLabel($0))" } ?? " · ikke hentet") : nil,
                    sourceIsStale: isToday && isStale,
                    isRefreshing: isToday && isRefreshing
                ) {
                    switch mode {
                    case .timeCards:
                        TimeCardsForecast(
                            day: day,
                            allForecast: forecast,
                            temperatureLowThreshold: temperatureLowThreshold,
                            temperatureHighThreshold: temperatureHighThreshold,
                            languageStyle: languageStyle,
                            latitude: latitude,
                            longitude: longitude
                        )
                    case .weatherBands:
                        let bandRules = WeatherBandDisplayRuleOverrides.applying(
                            to: rules,
                            dewThreshold: displayDewThreshold,
                            gustThreshold: displayGustThreshold
                        )
                        SwiftUI.TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            WeatherBandsForecast(day: day, allForecast: forecast, rules: bandRules, frostMargin: frostMargin, sunThreshold: sunThreshold, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, latitude: latitude, longitude: longitude, languageStyle: languageStyle, now: timeline.date)
                        }
                    case .events:
                        WeatherEventsForecast(day: day, rules: rules, frostMargin: frostMargin)
                    }
                }
            }
        }
    }
}

enum WeatherBandDisplayRuleOverrides {
    /// Keeps table thresholds independent from enabled push-alert thresholds.
    static func applying(to rules: [Rule], dewThreshold: Double, gustThreshold: Double) -> [Rule] {
        rules.map { source in
            guard source.type == .dugg || source.type == .vind else { return source }
            var displayRule = source
            displayRule.threshold = source.type == .dugg ? dewThreshold : gustThreshold
            return displayRule
        }
    }
}

struct ForecastDay: Identifiable {
    let date: Date
    let hours: [ForecastHour]
    var id: Date { date }

    static func make(from forecast: [ForecastHour], calendar: Calendar = .current) -> [ForecastDay] {
        // Day headers follow calendar days. The bands themselves still cover
        // 07–15–23–07, so the overnight segment remains visually connected.
        let grouped = Dictionary(grouping: forecast) { calendar.startOfDay(for: $0.time) }
        return grouped.keys.sorted().map { date in
            var seenTimestamps = Set<Date>()
            let uniqueHours = grouped[date, default: []]
                .filter { seenTimestamps.insert($0.time).inserted }
                .sorted { $0.time < $1.time }
            return ForecastDay(date: date, hours: uniqueHours)
        }
    }
}

/// A visual weather day runs from 07 to 07, not from midnight to midnight.
/// This keeps the final night cell honest: 23–07 contains the following
/// morning's 00–06 values, including dew events around 05.
enum WeatherBandHours {
    static func make(
        for day: Date,
        from forecast: [ForecastHour],
        includeEarlyMorning: Bool = false,
        calendar: Calendar = .current
    ) -> [ForecastHour] {
        let dayStart = calendar.startOfDay(for: day)
        let startHour = includeEarlyMorning ? 5 : 7
        guard let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: dayStart),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
              let end = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: nextDay) else {
            return []
        }
        // Keep the first source sample for a timestamp. Forecast feeds may
        // overlap at refresh boundaries; returning both would draw the same
        // hour twice, and an explicit first-wins rule avoids relying on sort
        // stability for equal dates.
        var seenTimestamps = Set<Date>()
        return forecast
            .filter { $0.time >= start && $0.time < end }
            .filter { seenTimestamps.insert($0.time).inserted }
            .sorted { $0.time < $1.time }
    }
}

/// Keeps the three-calendar-day weather band independent from the shorter
/// 24-hour rotating-alert horizon on Home.
enum ForecastDaySelection {
    static func visibleDays(
        from days: [ForecastDay], now: Date, calendar: Calendar = .current
    ) -> [ForecastDay] {
        let relevantDays: [ForecastDay]
        if calendar.component(.hour, from: now) >= 5,
           calendar.component(.hour, from: now) < 7 {
            let today = calendar.startOfDay(for: now)
            relevantDays = days.filter { $0.date >= today }
        } else {
            relevantDays = days
        }
        // Keep Home and expanded places visually stable: exactly the first
        // three available calendar days, never a partial fourth.
        return Array(relevantDays.prefix(3))
    }

    /// Keeps a cached forecast that starts on an older calendar day from
    /// consuming one of Home's three visible days. This is important at
    /// launch: a still-future-covering cache may begin yesterday, but Home
    /// should show today and the next two calendar days.
    static func hoursForVisibleDays(
        from forecast: [ForecastHour], now: Date = Date(), calendar: Calendar = .current
    ) -> [ForecastHour] {
        let days = ForecastDay.make(from: forecast, calendar: calendar)
        let visibleDates = Set(visibleDays(from: days, now: now, calendar: calendar).map(\.date))
        return forecast
            .filter { visibleDates.contains(calendar.startOfDay(for: $0.time)) }
            .sorted { $0.time < $1.time }
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

private func missingHourOffsets(
    for day: Date,
    period: WeatherBandPeriod,
    forecast: [ForecastHour],
    calendar: Calendar = .current
) -> [Int] {
    guard let interval = ForecastHourSelection.bandInterval(
        on: day, startingAt: period.startHour, slotCount: period.hours, calendar: calendar
    ) else { return [] }
    return ForecastHourSelection.missingHourOffsets(
        in: interval, startingAt: period.startHour, slotCount: period.hours,
        forecast: forecast, calendar: calendar
    )
}

private func forecastDayTitle(_ date: Date) -> String {
    let today = Calendar.current.startOfDay(for: Date())
    let calendar = Calendar.current
    let dayNumber = calendar.component(.day, from: date)
    let monthNames = ["", "jan", "feb", "mars", "apr", "mai", "juni", "juli", "aug", "sept", "okt", "nov", "des"]
    let dateText = "\(dayNumber). \(monthNames[calendar.component(.month, from: date)])"
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
       calendar.isDate(date, inSameDayAs: tomorrow) { return "I morgen, \(dateText)" }
    let value = weekdayLabel(date)
    let weekday = value.prefix(1).uppercased() + value.dropFirst()
    return "\(weekday) \(dateText)"
}

private struct ForecastDayFrame<Content: View>: View {
    let title: String
    let sourceText: String?
    let sourceIsStale: Bool
    let isRefreshing: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()
                .padding(.horizontal, 9)
                .padding(.top, 15)
                // The now-label sits just below the weather tracks. Keep it
                // inside the day frame instead of visually touching its edge.
                .padding(.bottom, 17)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.32), lineWidth: 0.7)
                }

            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
                    .background(Color(uiColor: .systemBackground))
                Spacer(minLength: 4)
                if let sourceText {
                    HStack(spacing: 4) {
                        Text(sourceText)
                        if isRefreshing {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(sourceIsStale ? Color.orange.opacity(0.72) : Color.secondary)
                    .padding(.horizontal, 6)
                    .background(Color(uiColor: .systemBackground))
                }
            }
            .padding(.horizontal, 12)
            .offset(y: -8)
        }
        .padding(.top, 8)
    }
}

private struct TimeCardsForecast: View {
    let day: ForecastDay
    let allForecast: [ForecastHour]
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double
    let languageStyle: AlertLanguageStyle
    let latitude: Double
    let longitude: Double

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
                    let label = ForecastHourLabel.make(
                        for: hour.time,
                        among: day.hours.map(\.time)
                    )
                    let condition = CurrentWeatherCondition.resolve(
                        hour,
                        precipitationIsFalling: hour.precipitationRate >= 0.1
                    )
                    let isDaylight = SolarCycle.isDaylight(
                        hour.time,
                        latitude: latitude,
                        longitude: longitude
                    )
                    VStack(spacing: 6) {
                        Text(label.display)
                            .font(.caption.weight(.semibold))
                        Image(systemName: condition.systemImage(isDaylight: isDaylight))
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
                    .accessibilityLabel("\(label.accessibility), \(condition.accessibilityLabel(languageStyle: languageStyle, isDaylight: isDaylight)), \(Int(hour.temp.rounded())) grader, \(hour.precip.formatted()) millimeter nedbør")
                }
            }
        }
    }
}

private struct WeatherBandsForecast: View {
    let day: ForecastDay
    let allForecast: [ForecastHour]
    let rules: [Rule]
    let frostMargin: Double
    let sunThreshold: Double
    let sunThreshold2: Double
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double
    let latitude: Double
    let longitude: Double
    let languageStyle: AlertLanguageStyle
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

    private var hatchLegend: WeatherBandHatchLegend.Texts {
        WeatherBandHatchLegend.texts(
            for: languageStyle,
            includesPartialSun: displayedTypes.contains(.sol)
        )
    }

    @ViewBuilder
    private var partialSunLegendItem: some View {
        if let partialSun = hatchLegend.partialSun {
            HStack(spacing: 4) {
                SolarHatchMark()
                    .frame(width: 12, height: 12)
                    .background(SolarCellMarkerStyle.hatchColor.opacity(0.18))
                Text(partialSun)
            }
        }
    }

    private var missingForecastLegendItem: some View {
        HStack(spacing: 4) {
            ForecastGapMark()
                .frame(width: 12, height: 12)
            Text(hatchLegend.missingForecast)
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

    private var bandHours: [ForecastHour] {
        WeatherBandHours.make(
            for: day.date,
            from: allForecast,
            includeEarlyMorning: includesEarlyMorningCell
        )
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
                                color: AlertType.regn.color
                            )
                            MoistureBandTrack(hours: bandHours, rules: moistureRules, day: day.date, includeEarlyMorning: includesEarlyMorningCell, compressForMorning: isMorningCompression && !isToday)
                        }
                    }
                    ForEach(displayedTypes) { type in
                        let typeRules = rulesForType(type)
                        HStack(spacing: 7) {
                            WeatherBandLabel(
                                title: type.label,
                                systemImage: type == .temperatur && typeRules.contains(where: { $0.type == .frost })
                                    ? AlertType.frost.systemImage
                                    : type.systemImage,
                                color: type.color
                            )
                            CombinedDayBandTrack(hours: bandHours, rules: typeRules, type: type, day: day.date, frostMargin: frostMargin, sunThreshold: sunThreshold, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, latitude: latitude, longitude: longitude, includeEarlyMorning: includesEarlyMorningCell, compressForMorning: isMorningCompression && !isToday)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            partialSunLegendItem
                            missingForecastLegendItem
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            partialSunLegendItem
                            missingForecastLegendItem
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(hatchLegend.accessibility)
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

enum WeatherBandHatchLegend {
    struct Texts {
        let partialSun: String?
        let missingForecast: String
        let accessibility: String
    }

    static func texts(for languageStyle: AlertLanguageStyle, includesPartialSun: Bool = true) -> Texts {
        if languageStyle == .english {
            return Texts(
                partialSun: includesPartialSun ? "Yellow hatch: partial sun" : nil,
                missingForecast: "Gray hatch: missing Yr hours",
                accessibility: includesPartialSun
                    ? "Yellow hatch means partial sun. Gray hatch means Yr forecast hours are missing. Hatching does not mean an alert is missing."
                    : "Gray hatch means Yr forecast hours are missing. Hatching does not mean an alert is missing."
            )
        }
        return Texts(
            partialSun: includesPartialSun
                ? WeatherLanguage.text("Gul skravur: delvis sol", style: languageStyle)
                : nil,
            missingForecast: WeatherLanguage.text("Grå skravur: Yr mangler timer", style: languageStyle),
            accessibility: WeatherLanguage.text(
                includesPartialSun
                    ? "Gul skravur betyr delvis sol. Grå skravur betyr at Yr mangler prognosetimer. Skravur betyr ikke manglende varsling."
                    : "Grå skravur betyr at Yr mangler prognosetimer. Skravur betyr ikke manglende varsling.",
                style: languageStyle
            )
        )
    }
}

private struct WeatherBandLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(title)
        }
        .font(.caption)
        .lineLimit(1)
        .frame(width: 78, alignment: .leading)
    }
}

private struct CombinedDayBandTrack: View {
    let hours: [ForecastHour]
    let rules: [Rule]
    let type: AlertType
    let day: Date
    let frostMargin: Double
    let sunThreshold: Double
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
                    CombinedHourBandCell(hours: hours, rules: rules, type: type, day: day, period: .earlyMorning, frostMargin: frostMargin, sunThreshold: sunThreshold, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, latitude: latitude, longitude: longitude)
                        .frame(width: availableWidth * 2 / 26)
                }
                ForEach(WeatherBandPeriod.all) { period in
                    CombinedHourBandCell(hours: hours, rules: rules, type: type, day: day, period: period, frostMargin: frostMargin, sunThreshold: sunThreshold, sunThreshold2: sunThreshold2, temperatureLowThreshold: temperatureLowThreshold, temperatureHighThreshold: temperatureHighThreshold, latitude: latitude, longitude: longitude)
                        .frame(width: availableWidth * 8 / totalHours)
                }
            }
            .frame(maxWidth: .infinity, alignment: compressForMorning ? .trailing : .leading)
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(type.label), samlet fra \(rules.count) \(rules.count == 1 ? "regel" : "regler"). \(ForecastGapAccessibility.explanation)")
    }
}

private struct CombinedHourBandCell: View {
    let hours: [ForecastHour]
    let rules: [Rule]
    let type: AlertType
    let day: Date
    let period: WeatherBandPeriod
    let frostMargin: Double
    let sunThreshold: Double
    let sunThreshold2: Double
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double
    let latitude: Double
    let longitude: Double

    private func missingOffsets(for period: WeatherBandPeriod) -> [Int] {
        missingHourOffsets(for: day, period: period, forecast: hours)
    }

    private func displayPriority(for hour: ForecastHour) -> Double {
        let solarAppearance = type == .sol
            ? SolarCycle.rowAppearance(
                near: hour.time, cloud: hour.cloud, sunThreshold: sunThreshold, sunThreshold2: sunThreshold2,
                latitude: latitude, longitude: longitude
            )
            : .neutral
        if type == .sol, let fog = solarBandFogLevel(hour) {
            return 600 + fog
        }
        if type == .sol, (solarAppearance == .sunlit || solarAppearance == .partlySunlit) {
            return 500 + max(0, sunThreshold2 - hour.cloud)
        }
        if type == .temperatur,
           hour.temp <= temperatureLowThreshold || hour.temp >= temperatureHighThreshold {
            return 400 + max(temperatureLowThreshold - hour.temp, hour.temp - temperatureHighThreshold)
        }

        let matchingRules = rules.filter {
            $0.isActive(at: hour.time) && $0.matches(hour, frostMargin: frostMargin)
        }
        guard !matchingRules.isEmpty else { return 0 }
        let ruleStrengths = matchingRules.map { rule in
            switch rule.type {
            case .regn, .sno:
                return hour.precipitationRiskRate + (hour.isPossiblePrecipitation(atOrAbove: rule.threshold) ? 0 : 100)
            case .frost:
                return max(0, rule.threshold + max(0, frostMargin) - hour.temp)
            case .temperatur:
                return rule.temperatureDirection == .above
                    ? max(0, hour.temp - rule.threshold)
                    : max(0, rule.threshold - hour.temp)
            case .vind:
                return hour.gust ?? 0
            case .dugg:
                return max(0, rule.threshold - (hour.temp - hour.dew))
            case .sol:
                return max(0, rule.threshold - hour.cloud)
            }
        }
        return 1_000 + (ruleStrengths.max() ?? 0)
    }

    private var displayedHours: [ForecastHour] {
        ForecastHourSelection.strongestPerBandCell(
            from: hours, startingAt: period.startHour, slotCount: period.hours,
            priority: { displayPriority(for: $0) }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(period.isNight ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.08))
                ForEach(missingOffsets(for: period), id: \.self) { offset in
                    ForecastGapMark()
                        .frame(width: proxy.size.width / CGFloat(period.hours), height: proxy.size.height)
                        .offset(x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours))
                }
                ForEach(displayedHours) { hour in
                    let hourNumber = Calendar.current.component(.hour, from: hour.time)
                    let offset = hourOffset(hourNumber, from: period.startHour)
                    let solarAppearance = type == .sol
                        ? SolarCycle.rowAppearance(
                            near: hour.time, cloud: hour.cloud, sunThreshold: sunThreshold, sunThreshold2: sunThreshold2,
                            latitude: latitude, longitude: longitude
                        )
                        : .neutral
                    // Boundary cells show a marker instead of a yellow sun fill.
                    let solarTransition = solarAppearance.transition
                    let hourCellWidth = proxy.size.width / CGFloat(period.hours)
                    let fogLevel = type == .sol ? solarBandFogLevel(hour) : nil
                    let fogSymbol = fogLevel.map { _ in solarBandFogSymbol(for: solarAppearance) }
                    let matchesSunPreview = type == .sol && solarAppearance == .sunlit
                    let matchesPartialSunPreview = type == .sol && solarAppearance == .partlySunlit
                    let matchesTemperaturePreview = type == .temperatur && (hour.temp <= temperatureLowThreshold || hour.temp >= temperatureHighThreshold)
                    let matchesFrost = type == .temperatur && rules.contains(where: {
                        $0.type == .frost && $0.isActive(at: hour.time) && $0.matches(hour, frostMargin: frostMargin)
                    })
                    if offset < period.hours, matchesSunPreview || matchesPartialSunPreview || matchesTemperaturePreview || (type != .sol && rules.contains(where: {
                        $0.isActive(at: hour.time) && $0.matches(hour, frostMargin: frostMargin)
                    })) {
                            Rectangle()
                                .fill(type == .temperatur && hour.temp >= temperatureHighThreshold
                                  ? Color.orange.opacity(0.78)
                                  : type.color.opacity(type == .sol && matchesPartialSunPreview
                                                       ? SolarCellMarkerStyle.partialFillOpacity
                                                       : type == .sol
                                                       ? SolarCellMarkerStyle.solidFillOpacity
                                                       : 0.78))
                            .frame(width: proxy.size.width / CGFloat(period.hours) + 0.5)
                            .offset(x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours))
                        if matchesPartialSunPreview {
                            SolarHatchMark()
                                .frame(width: proxy.size.width / CGFloat(period.hours), height: proxy.size.height)
                                .offset(x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours))
                        }
                        if matchesFrost {
                            Image(systemName: AlertType.frost.systemImage)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Color.white)
                                .shadow(color: .black.opacity(0.28), radius: 0.7, y: 0.4)
                                    .frame(width: proxy.size.width / CGFloat(period.hours), height: proxy.size.height)
                                    .position(
                                    x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours) + proxy.size.width / CGFloat(period.hours * 2),
                                    y: proxy.size.height / 2
                                )
                        }
                    }
                    if offset < period.hours, let fogLevel, let fogSymbol {
                        Image(systemName: fogSymbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(fogSymbol == "sun.haze.fill"
                                ? Color.orange
                                : Color(red: 0.38, green: 0.45, blue: 0.52))
                            .frame(width: hourCellWidth, height: proxy.size.height)
                            .position(
                                x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours) + hourCellWidth / 2,
                                y: proxy.size.height / 2
                            )
                            .accessibilityLabel("Skodde, styrke \(Int(fogLevel.rounded())) prosent")
                    } else if offset < period.hours, let solarTransition {
                        Image(systemName: solarTransition.systemImage)
                            .resizable()
                            .foregroundStyle(Color.orange)
                            .scaledToFit()
                            .frame(width: hourCellWidth, height: proxy.size.height)
                            .position(
                                x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours) + hourCellWidth / 2,
                                y: proxy.size.height / 2
                            )
                            .accessibilityLabel(solarTransition == .sunrise ? "Soloppgang" : "Solnedgang")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct MoistureBandTrack: View {
    let hours: [ForecastHour]
    let rules: [Rule]
    let day: Date
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
                    MoistureHourBandCell(hours: hours, rules: rules, day: day, period: .earlyMorning)
                        .frame(width: availableWidth * 2 / 26)
                }
                ForEach(WeatherBandPeriod.all) { period in
                    MoistureHourBandCell(hours: hours, rules: rules, day: day, period: period)
                        .frame(width: availableWidth * 8 / totalHours)
                }
            }
            .frame(maxWidth: .infinity, alignment: compressForMorning ? .trailing : .leading)
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nedbør: regn, snø og fare for dugg vises med egne farger. \(ForecastGapAccessibility.explanation)")
    }
}

private struct MoistureHourBandCell: View {
    let hours: [ForecastHour]
    let rules: [Rule]
    let day: Date
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
        ForecastBandSignalPriority.hasRecentPrecipitation(before: hour, among: hours)
    }

    private var missingOffsets: [Int] {
        missingHourOffsets(for: day, period: period, forecast: hours)
    }

    private func displayPriority(for hour: ForecastHour) -> Double {
        if let precipitationRule = matchingRule(of: .sno, for: hour)
            ?? matchingRule(of: .regn, for: hour) {
            let isPossible = hour.isPossiblePrecipitation(atOrAbove: precipitationRule.threshold)
            return ForecastBandSignalPriority.score(
                for: isPossible ? .possiblePrecipitation : .certainPrecipitation,
                strength: hour.precipitationRiskRate
            )
        }
        if hour.precipitationRate >= 0.1 && hour.temp > 1 {
            return ForecastBandSignalPriority.score(
                for: .observedPrecipitation, strength: hour.precipitationRate
            )
        }
        if let dewRule = matchingRule(of: .dugg, for: hour), !hadRecentPrecipitation(before: hour) {
            return ForecastBandSignalPriority.score(
                for: .dew, strength: max(0, dewRule.threshold - (hour.temp - hour.dew))
            )
        }
        return ForecastBandSignalPriority.score(for: .none)
    }

    private var displayedHours: [ForecastHour] {
        ForecastHourSelection.strongestPerBandCell(
            from: hours, startingAt: period.startHour, slotCount: period.hours,
            priority: { displayPriority(for: $0) }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(period.isNight ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.08))
                ForEach(missingOffsets, id: \.self) { offset in
                    ForecastGapMark()
                        .frame(width: proxy.size.width / CGFloat(period.hours), height: proxy.size.height)
                        .offset(x: proxy.size.width * CGFloat(offset) / CGFloat(period.hours))
                        .accessibilityLabel("Manglende Yr-prognose; været er ukjent")
                }
                ForEach(displayedHours) { hour in
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

private struct ForecastGapMark: View {
    var body: some View {
        GeometryReader { proxy in
            let stripes = Path { path in
                let spacing: CGFloat = 5
                var startX = -proxy.size.height
                while startX < proxy.size.width {
                    path.move(to: CGPoint(x: startX, y: proxy.size.height))
                    path.addLine(to: CGPoint(x: startX + proxy.size.height, y: 0))
                    startX += spacing
                }
            }
            ZStack {
                // A dark edge and bright core keep the hatch legible against
                // both pale daytime and dark nighttime band backgrounds.
                stripes.stroke(Color.black.opacity(0.7), lineWidth: 1.5)
                stripes.stroke(Color.white.opacity(0.9), lineWidth: 0.65)
            }
        }
        .background(Color.secondary.opacity(0.12))
        .clipped()
        .accessibilityHidden(true)
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

enum ForecastHourLabel {
    static func make(
        for time: Date,
        among times: [Date],
        calendar: Calendar = .autoupdatingCurrent
    ) -> (display: String, accessibility: String) {
        let clock = String(format: "%02d", calendar.component(.hour, from: time))
        let wallHour = calendar.dateComponents([.era, .year, .month, .day, .hour], from: time)
        let sameWallHour = Array(Set(times.filter {
            calendar.dateComponents([.era, .year, .month, .day, .hour], from: $0) == wallHour
        })).sorted()
        guard sameWallHour.count > 1,
              let occurrence = sameWallHour.firstIndex(of: time) else {
            return (clock, "Klokken \(clock)")
        }

        let suffix = occurrence == 0 ? "a" : "b"
        let ordinal = occurrence == 0 ? "første" : "andre"
        return ("\(clock)\(suffix)", "Klokken \(clock), \(ordinal) forekomst")
    }
}

/// Uses the user's current calendar/time zone, so forecast labels do not drift
/// when a UTC timestamp crosses local midnight or a DST boundary.
func localHourComponent(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
    calendar.component(.hour, from: date)
}

func forecastSymbol(_ hour: ForecastHour, isDaylight: Bool = true) -> String {
    CurrentWeatherCondition.resolve(
        hour,
        precipitationIsFalling: hour.precipitationRate >= 0.1
    ).systemImage(isDaylight: isDaylight)
}

func solarBandFogLevel(_ hour: ForecastHour) -> Double? {
    guard let fog = hour.fog, fog.isFinite, fog >= 50 else { return nil }
    return fog
}

func solarBandFogSymbol(for appearance: SolarCycle.RowAppearance) -> String {
    switch appearance {
    case .sunlit, .partlySunlit: "sun.haze.fill"
    case .sunrise, .sunset, .neutral: "cloud.fog.fill"
    }
}

private struct SolarHatchMark: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let height = proxy.size.height
                for startX in stride(
                    from: -height,
                    through: proxy.size.width,
                    by: SolarCellMarkerStyle.hatchSpacing
                ) {
                    path.move(to: CGPoint(x: startX, y: height))
                    path.addLine(to: CGPoint(x: startX + height, y: 0))
                }
            }
            .stroke(
                SolarCellMarkerStyle.hatchColor.opacity(SolarCellMarkerStyle.hatchOpacity),
                lineWidth: SolarCellMarkerStyle.hatchLineWidth
            )
        }
        .clipShape(Rectangle())
        .allowsHitTesting(false)
    }
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

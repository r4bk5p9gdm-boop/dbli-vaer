import Foundation

enum Planner {
    /// Hjemmets rullerende varsel skal være nært og handlingsrettet. Selve
    /// værbåndet har en lengre horisont, men denne flaten stopper ved 24 timer.
    static func isWithinRotatingHomeHorizon(_ eventAt: Date, now: Date = Date()) -> Bool {
        eventAt <= now.addingTimeInterval(24 * 60 * 60)
    }

    private static let rainAlertCooldown: TimeInterval = 6 * 3_600
    private static let dewDryBuffer: TimeInterval = 3 * 3_600

    struct Result {
        var eventAt: Date?
        var alerts: [PlannedAlert] = []
        var skippedReason: String?
        var hitIndices: Set<Int> = []
        var possible = false
    }

    private static func matches(_ rule: Rule, hour: ForecastHour, frostMargin: Double = 0, calendar: Calendar = .current) -> Bool {
        rule.isActive(at: hour.time, calendar: calendar) && rule.matches(hour, frostMargin: frostMargin)
    }

    private static func matches(_ rule: Rule, at index: Int, in forecast: [ForecastHour], frostMargin: Double = 0, calendar: Calendar = .current) -> Bool {
        guard forecast.indices.contains(index), matches(rule, hour: forecast[index], frostMargin: frostMargin, calendar: calendar) else { return false }
        guard rule.type == .dugg else { return true }

        let eventAt = forecast[index].time
        let drySince = eventAt.addingTimeInterval(-dewDryBuffer)
        return !forecast.contains { hour in
            hour.time >= drySince
                && hour.time <= eventAt
                && hour.precipitationRiskRate >= 0.1
        }
    }

    private static func isPrecipitationRule(_ rule: Rule) -> Bool {
        rule.type == .regn || rule.type == .sno
    }

    private static func isPossible(rule: Rule, hour: ForecastHour, frostMargin: Double) -> Bool {
        if rule.type == .frost {
            return frostMargin > 0 && hour.temp > rule.threshold
        }
        return isPrecipitationRule(rule) && hour.isPossiblePrecipitation(atOrAbove: rule.threshold)
    }

    private static func sampleMatches(_ sample: PrecipitationSample, rule: Rule, hour: ForecastHour, calendar: Calendar = .current) -> Bool {
        guard sample.rate >= rule.threshold, rule.isActive(at: sample.time, calendar: calendar) else { return false }
        switch rule.type {
        case .regn: return hour.temp > 1
        case .sno: return hour.temp <= 1
        default: return false
        }
    }

    private static func radarEvent(
        rule: Rule,
        forecast: [ForecastHour],
        run: Range<Int>? = nil,
        now: Date,
        calendar: Calendar = .current
    ) -> (date: Date, isNow: Bool)? {
        guard isPrecipitationRule(rule) else { return nil }
        let selectedHours = run.map { Array(forecast[$0]) } ?? forecast
        let samples = selectedHours.flatMap { hour in
            (hour.radarSamples ?? []).map { (sample: $0, hour: hour) }
        }.sorted { $0.sample.time < $1.sample.time }
        guard !samples.isEmpty else { return nil }

        let nearNow = samples
            .filter { abs($0.sample.time.timeIntervalSince(now)) <= 7.5 * 60 }
            .min { abs($0.sample.time.timeIntervalSince(now)) < abs($1.sample.time.timeIntervalSince(now)) }
        if let nearNow, sampleMatches(nearNow.sample, rule: rule, hour: nearNow.hour, calendar: calendar) {
            return (nearNow.sample.time, true)
        }
        if let upcoming = samples.first(where: {
            $0.sample.time > now && sampleMatches($0.sample, rule: rule, hour: $0.hour, calendar: calendar)
        }) {
            return (upcoming.sample.time, false)
        }
        return nil
    }

    private static func matchingRuns(rule: Rule, forecast: [ForecastHour], frostMargin: Double = 0, calendar: Calendar = .current) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for index in 0...forecast.count {
            let isMatch = index < forecast.count && matches(rule, at: index, in: forecast, frostMargin: frostMargin, calendar: calendar)
            if isMatch, start == nil { start = index }
            if !isMatch, let first = start {
                runs.append(first..<index)
                start = nil
            }
        }
        return runs.filter { !rule.type.needsDuration || $0.count >= rule.durationHours }
    }

    private static func previousDayFireDate(for eventAt: Date, rule: Rule, calendar: Calendar = .current) -> Date? {
        // Calendar date construction (rather than elapsed hours) keeps a
        // fixed evening notification at the correct local wall-clock time
        // across DST transitions.
        guard let hour = rule.previousDayNotificationHour else { return nil }
        let eventDay = calendar.startOfDay(for: eventAt)
        if let notificationWeekday = rule.notificationWeekday {
            let eventWeekday = (calendar.component(.weekday, from: eventAt) + 5) % 7
            let daysBack = (eventWeekday - notificationWeekday + 7) % 7
            guard let candidateDay = calendar.date(byAdding: .day, value: -daysBack, to: eventDay),
                  var candidate = calendar.date(
                    bySettingHour: hour,
                    minute: rule.previousDayNotificationMinute,
                    second: 0,
                    of: candidateDay
                  ) else { return nil }
            if candidate >= eventAt {
                candidate = calendar.date(byAdding: .day, value: -7, to: candidate) ?? candidate
            }
            return candidate
        }
        if rule.notificationDayOffset == 0 {
            return calendar.date(
                bySettingHour: hour,
                minute: rule.previousDayNotificationMinute,
                second: 0,
                of: eventDay
            )
        }
        let eventHour = calendar.component(.hour, from: eventAt)
        let belongsToNightStartingToday = rule.activeFromHour > rule.activeToHour && eventHour >= rule.activeFromHour
        guard let notificationDay = belongsToNightStartingToday
            ? Optional(eventDay)
            : calendar.date(byAdding: .day, value: -1, to: eventDay) else { return nil }
        return calendar.date(
            bySettingHour: hour,
            minute: rule.previousDayNotificationMinute,
            second: 0,
            of: notificationDay
        )
    }

    static func plan(rule: Rule, forecast: [ForecastHour], placeName: String, placeID: UUID? = nil, frostMargin: Double = 0, now: Date = Date(), calendar: Calendar = .current) -> Result {
        var res = Result()
        res.hitIndices = Set(forecast.indices.filter {
            matches(rule, at: $0, in: forecast, frostMargin: frostMargin, calendar: calendar)
        })

        let runs = matchingRuns(rule: rule, forecast: forecast, frostMargin: frostMargin, calendar: calendar)
        if rule.previousDayNotificationHour != nil {
            var seenFireDates: Set<Date> = []
            let scheduledRuns: [(run: Range<Int>, fireAt: Date)] = runs.compactMap { run in
                let eventAt = forecast[run.lowerBound].time
                guard let fireAt = previousDayFireDate(for: eventAt, rule: rule, calendar: calendar),
                      fireAt > now,
                      seenFireDates.insert(fireAt).inserted else { return nil }
                return (run, fireAt)
            }
            guard let first = scheduledRuns.first else { return res }
            res.eventAt = forecast[first.run.lowerBound].time
            res.possible = isPossible(rule: rule, hour: forecast[first.run.lowerBound], frostMargin: frostMargin)
            res.alerts = scheduledRuns.enumerated().map { index, scheduled in
                let eventAt = forecast[scheduled.run.lowerBound].time
                let possible = isPossible(rule: rule, hour: forecast[scheduled.run.lowerBound], frostMargin: frostMargin)
                let hours = Array(forecast[scheduled.run])
                let fireHour = calendar.component(.hour, from: scheduled.fireAt)
                let quiet = rule.quiet && (fireHour >= rule.quietFrom || fireHour < rule.quietTo)
                return PlannedAlert(
                    rule: rule,
                    placeID: placeID,
                    placeName: placeName,
                    eventAt: eventAt,
                    fireAt: scheduled.fireAt,
                    index: index + 1,
                    total: scheduledRuns.count,
                    quiet: quiet,
                    possible: possible,
                    eventDetail: notificationEventDetail(rule: rule, hours: hours, possible: possible, frostMargin: frostMargin)
                )
            }
            return res
        }

        guard let firstRun = runs.first else { return res }
        let firstRadarEvent = radarEvent(rule: rule, forecast: forecast, run: firstRun, now: now, calendar: calendar)
        res.eventAt = firstRadarEvent?.date ?? forecast[firstRun.lowerBound].time
        res.possible = firstRadarEvent == nil
            && isPossible(rule: rule, hour: forecast[firstRun.lowerBound], frostMargin: frostMargin)

        for run in runs {
            let start = run.lowerBound
            let preciseRadarEvent = radarEvent(rule: rule, forecast: forecast, run: run, now: now, calendar: calendar)
            let eventAt = preciseRadarEvent?.date ?? forecast[start].time
            let possible = preciseRadarEvent == nil
                && isPossible(rule: rule, hour: forecast[start], frostMargin: frostMargin)
            let candidates = notificationCandidates(for: eventAt, rule: rule, now: now, calendar: calendar)
            guard !candidates.isEmpty else { continue }

            res.eventAt = eventAt
            res.possible = possible
            let matchingHours = Array(forecast[run])
            let eventDetail = notificationEventDetail(
                rule: rule,
                hours: matchingHours,
                possible: possible,
                frostMargin: frostMargin
            )
            res.alerts = candidates.enumerated().map { index, candidate in
                PlannedAlert(
                    rule: rule,
                    placeID: placeID,
                    placeName: placeName,
                    eventAt: eventAt,
                    fireAt: candidate.date,
                    index: index + 1,
                    total: candidates.count,
                    quiet: candidate.quiet,
                    possible: possible,
                    eventDetail: eventDetail
                )
            }
            return res
        }
        return res
    }

    private static func notificationCandidates(for eventAt: Date, rule: Rule, now: Date, calendar: Calendar = .current) -> [(date: Date, quiet: Bool)] {
        (0..<rule.alertCount).compactMap { index in
            let date = eventAt.addingTimeInterval(
                TimeInterval(-rule.leadMinutes * 60 + index * rule.intervalMinutes * 60)
            )
            guard date > now, date < eventAt else { return nil }
            let hour = calendar.component(.hour, from: date)
            let quiet = rule.quiet && (hour >= rule.quietFrom || hour < rule.quietTo)
            return (date, quiet)
        }
    }

    static func statuses(for place: Place, forecast: [ForecastHour], now: Date = Date()) -> [WeatherStatus] {
        place.rulesForDisplay.compactMap { rule in
            status(for: rule, forecast: forecast, frostMargin: place.localFrostMargin, now: now)
        }.sorted {
            if $0.isNow != $1.isNow { return $0.isNow }
            return $0.eventAt < $1.eventAt
        }
    }

    static func statusDetail(for status: WeatherStatus, place: Place, forecast: [ForecastHour]) -> String? {
        guard let hour = forecast.min(by: {
            abs($0.time.timeIntervalSince(status.eventAt)) < abs($1.time.timeIntervalSince(status.eventAt))
        }) else { return nil }

        let number: (Double) -> String = {
            $0.formatted(.number.precision(.fractionLength(0...1)))
        }
        switch status.type {
        case .regn:
            let amount = status.possible == true
                ? (hour.precipMax ?? hour.precipitationRiskRate)
                : hour.precipitationRate
            let prefix = status.possible == true ? "Mulig " : ""
            return "\(prefix)\(PrecipitationCopy.rain(amount))."
        case .sno:
            let water = status.possible == true
                ? (hour.precipMax ?? hour.precipitationRiskRate)
                : hour.precipitationRate
            let snow = estimatedFreshSnowMillimeters(waterEquivalent: water, temperature: hour.temp)
            let prefix = status.possible == true ? "Mulig " : ""
            return "\(prefix)\(PrecipitationCopy.snow(snow))."
        case .dugg:
            return "\(status.possible == true ? "Mulig duggfall" : "Duggfall") ved \(number(hour.temp))°."
        case .frost:
            let label = status.possible == true || hour.temp > 0 ? "Fare for frost" : "Frost"
            return "\(label) ved \(number(hour.temp))°."
        case .temperatur:
            return "\(hour.yrTemperature == nil ? "Yr melder" : "Lokalt anslag"): \(number(hour.temp))°."
        case .vind:
            if let gust = hour.gust {
                if let duration = matchingDuration(for: status, place: place, forecast: forecast) {
                    let unit = duration == 1 ? "time" : "timer"
                    return "\(windStrengthLabel(for: gust).capitalized) i \(duration) \(unit)."
                }
                return "\(windStrengthLabel(for: gust).capitalized) — vindkast opptil \(number(gust)) m/s."
            }
            return "Vindkast ikke oppgitt."
        case .sol:
            return hour.cloud <= 20 ? "Sol med lite skydekke." : "Solgløtt med noe skyer."
        }
    }

    /// The rotating Home card is a compact two-line surface. Its second line
    /// must have one temporal shape across weather types: description, actual
    /// duration when it is meaningful, then the start clock for future events.
    /// The regular status detail remains deliberately more verbose for rules
    /// and accessibility summaries elsewhere in the app.
    static func rotatingStatusDetail(for status: WeatherStatus, place: Place, forecast: [ForecastHour]) -> String? {
        guard let hour = forecast.min(by: {
            abs($0.time.timeIntervalSince(status.eventAt)) < abs($1.time.timeIntervalSince(status.eventAt))
        }) else { return nil }

        let number = hour.temp.formatted(.number.precision(.fractionLength(0...1)))
        let duration = matchingDuration(for: status, place: place, forecast: forecast)
        let base: String

        switch status.type {
        case .regn:
            let amount = status.possible == true
                ? (hour.precipMax ?? hour.precipitationRiskRate)
                : hour.precipitationRate
            base = "\(status.possible == true ? "Mulig " : "")\(PrecipitationCopy.rain(amount))"
        case .sno:
            let water = status.possible == true
                ? (hour.precipMax ?? hour.precipitationRiskRate)
                : hour.precipitationRate
            let snow = estimatedFreshSnowMillimeters(waterEquivalent: water, temperature: hour.temp)
            base = "\(status.possible == true ? "Mulig " : "")\(PrecipitationCopy.snow(snow))"
        case .dugg:
            base = status.possible == true ? "Mulig duggfall" : "Duggfall"
        case .frost:
            base = "\(status.possible == true || hour.temp > 0 ? "Fare for frost" : "Frost") ved \(number)°"
        case .temperatur:
            base = "Lokalt anslag \(number)°"
        case .vind:
            guard let gust = hour.gust else { return "Vindkast ikke oppgitt." }
            base = windStrengthLabel(for: gust).capitalized
        case .sol:
            base = hour.cloud <= 20 ? "Sol" : "Solgløtt"
        }

        let durationText: String?
        if let duration, duration >= 2 {
            durationText = "i \(duration) timer"
        } else {
            durationText = nil
        }

        if status.isNow {
            let continuingDuration = durationText.map { "\($0) til" }
            return [base, continuingDuration].compactMap { $0 }.joined(separator: " ") + "."
        }

        let start = "fra kl. \(shortClockLabel(hour.time))"
        return [base, durationText, start].compactMap { $0 }.joined(separator: " ") + "."
    }

    /// Consecutive hours that satisfy the same display rule. This is used by
    /// the compact Home copy, where «fresk bris i 3 timer» is easier to scan
    /// than another timestamp or a duplicated alert title.
    private static func matchingDuration(for status: WeatherStatus, place: Place, forecast: [ForecastHour]) -> Int? {
        guard let rule = place.rulesForDisplay.first(where: { $0.id == status.ruleID }),
              let start = forecast.indices.min(by: {
                  abs(forecast[$0].time.timeIntervalSince(status.eventAt))
                      < abs(forecast[$1].time.timeIntervalSince(status.eventAt))
              }) else { return nil }
        var duration = 0
        for index in start..<forecast.endIndex {
            guard matches(rule, at: index, in: forecast, frostMargin: place.localFrostMargin) else { break }
            duration += 1
        }
        return duration == 0 ? nil : duration
    }

    static func status(for rule: Rule, forecast: [ForecastHour], frostMargin: Double = 0, now: Date = Date()) -> WeatherStatus? {
        guard !forecast.isEmpty else { return nil }
        let radar = radarEvent(rule: rule, forecast: forecast, now: now)
        if let radar, radar.isNow {
            let text = rule.type == .sno ? "Snø nå." : "Regn nå."
            return WeatherStatus(ruleID: rule.id, type: rule.type, text: rule.statusText(text), eventAt: radar.date, isNow: true)
        }
        let currentFloor = now.addingTimeInterval(-3_600)
        let currentIndex = forecast.firstIndex { $0.time >= currentFloor } ?? forecast.startIndex
        let currentIsNearNow = forecast[currentIndex].time <= now.addingTimeInterval(10 * 60)
        if currentIsNearNow, matches(rule, at: currentIndex, in: forecast, frostMargin: frostMargin) {
            var duration = 0
            for index in currentIndex..<forecast.endIndex {
                guard matches(rule, at: index, in: forecast, frostMargin: frostMargin) else { break }
                duration += 1
            }
            if !rule.type.needsDuration || duration >= rule.durationHours {
                let text: String
                let possible = isPossible(rule: rule, hour: forecast[currentIndex], frostMargin: frostMargin)
                switch rule.type {
                case .regn: text = possible ? "Mulig regn nå." : "Regn nå."
                case .frost: text = possible ? "Mulig frost nå." : "Frost nå."
                case .temperatur:
                    text = "Under \(rule.threshold.formatted(.number.precision(.fractionLength(0...1))))° nå."
                case .sno: text = possible ? "Mulig snø nå." : "Snø nå."
                case .vind:
                    text = forecast[currentIndex].gust == nil ? "Vind nå." : "Vindkast nå."
                case .dugg: text = "Fare for dugg nå."
                case .sol:
                    text = "Sol i \(duration) \(duration == 1 ? "time" : "timer") nå."
                }
                return WeatherStatus(
                    ruleID: rule.id,
                    type: rule.type,
                    text: rule.statusText(text),
                    eventAt: forecast[currentIndex].time,
                    isNow: true,
                    possible: possible
                )
            }
        }

        guard let nextRun = matchingRuns(rule: rule, forecast: forecast, frostMargin: frostMargin)
            .first(where: { forecast[$0.lowerBound].time > now }) else { return nil }
        let start = nextRun.lowerBound
        let nextRadar = radarEvent(rule: rule, forecast: forecast, run: nextRun, now: now)
        let eventAt = nextRadar?.date ?? forecast[start].time
        guard eventAt > now else { return nil }
        let possible = nextRadar == nil && isPossible(rule: rule, hour: forecast[start], frostMargin: frostMargin)
        let text = weatherAlertText(
            for: rule,
            eventAt: eventAt,
            referenceAt: now,
            possible: possible,
            durationHours: nextRun.count
        )
        return WeatherStatus(ruleID: rule.id, type: rule.type, text: rule.statusText(text), eventAt: eventAt, isNow: false, possible: possible)
    }

    static func planAll(
        places: [Place],
        forecasts: [UUID: [ForecastHour]],
        nearbyPlaceIDs: Set<UUID> = []
    ) -> [PlannedAlert] {
        places.filter(\.areNotificationsEnabled).flatMap { p in
            let placeAlerts = p.rules.filter { rule in
                // Display-only rows are intentionally excluded from push planning.
                rule.enabled && !rule.isDisplayOnly
                    && (!rule.onlyWhenNearby || nearbyPlaceIDs.contains(p.id))
            }.flatMap { r in
                plan(rule: r, forecast: forecasts[p.id] ?? [], placeName: p.nameWithPreposition, placeID: p.id, frostMargin: p.localFrostMargin).alerts
            }
            return removingDuplicateRainAlerts(placeAlerts)
        }.sorted { $0.fireAt < $1.fireAt }
    }

    private static func removingDuplicateRainAlerts(_ alerts: [PlannedAlert]) -> [PlannedAlert] {
        var result: [PlannedAlert] = []

        for alert in alerts.sorted(by: { $0.fireAt < $1.fireAt }) {
            if alert.rule.type == .regn {
                let duplicatesAnotherRule = result.contains { previous in
                    previous.rule.type == .regn
                        && previous.rule.id != alert.rule.id
                        && abs(alert.eventAt.timeIntervalSince(previous.eventAt)) < rainAlertCooldown
                }
                if duplicatesAnotherRule {
                    continue
                }
            }
            result.append(alert)
        }
        return result
    }

    static func notificationEventDetail(rule: Rule, hours: [ForecastHour], possible: Bool, frostMargin: Double = 0) -> String? {
        guard !hours.isEmpty else { return nil }
        let duration = hours.count
        let durationText = "\(duration) \(duration == 1 ? "time" : "timer")"
        let durationSuffix = duration > 1 ? " — i \(durationText)" : ""
        let withTime: (String) -> String = { "\($0) {tid}\(durationSuffix)." }
        let number: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...1))) }

        switch rule.type {
        case .regn:
            let amount = hours.reduce(0.0) { total, hour in
                total + (possible ? hour.precipitationRiskRate : hour.precipitationRate)
            }
            return withTime(PrecipitationCopy.rain(amount / Double(duration)))
        case .sno:
            let amount = hours.reduce(0.0) { total, hour in
                let water = possible ? hour.precipitationRiskRate : hour.precipitationRate
                return total + estimatedFreshSnowMillimeters(waterEquivalent: water, temperature: hour.temp)
            }
            return withTime(PrecipitationCopy.snow(amount / Double(duration)))
        case .vind:
            let gust = hours.compactMap(\.gust).max()
            guard let gust else { return withTime("Vindkast ikke oppgitt") }
            return withTime(windStrengthLabel(for: gust).capitalized + " — vindkast opptil \(number(gust)) m/s")
        case .frost:
            let lowest = hours.map(\.temp).min() ?? 0
            let description = possible || (frostMargin > 0 && lowest > 0) ? "Fare for frost" : "Frost"
            return withTime("\(description) ved \(number(lowest))°")
        case .temperatur:
            let relation = rule.temperatureDirection == .above ? "Over" : "Under"
            return withTime("\(relation) \(number(rule.threshold))°")
        case .dugg:
            let temperature = hours.min { abs($0.temp - $0.dew) < abs($1.temp - $1.dew) }?.temp ?? 0
            return withTime("\(possible ? "Mulig duggfall" : "Duggfall") ved \(number(temperature))°")
        case .sol:
            return withTime("Sol")
        }
    }
}

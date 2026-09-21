import ActivityKit
import Foundation

enum LiveWeatherActivitySettings {
    static let enabledKey = "varsel.liveWeatherActivitiesEnabled"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }
}

enum LiveWeatherActivityPolicy {
    static let earliestStart: TimeInterval = 10 * 60
    static let latestStart: TimeInterval = 60 * 60

    static func canStart(_ status: WeatherStatus, now: Date) -> Bool {
        guard !status.isNow else { return false }
        let seconds = status.eventAt.timeIntervalSince(now)
        return seconds >= earliestStart && seconds <= latestStart
    }

    static func canStart(at notificationAt: Date, now: Date) -> Bool {
        let seconds = notificationAt.timeIntervalSince(now)
        return seconds >= earliestStart && seconds <= latestStart
    }

    static func canContinue(_ status: WeatherStatus, now: Date) -> Bool {
        status.isNow || (status.eventAt >= now && status.eventAt.timeIntervalSince(now) <= latestStart)
    }

    static func forecastIsFresh(fetchedAt: Date, now: Date, maxAge: TimeInterval = 6 * 3_600) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age <= maxAge
    }

    /// Live Activities must never be started from weather data whose age is
    /// unknown. The normal forecast UI may keep that cache for offline use,
    /// but a countdown is only useful when its underlying event is fresh.
    static func forecastIsUsable(fetchedAt: Date?, now: Date, maxAge: TimeInterval = 6 * 3_600) -> Bool {
        guard let fetchedAt else { return false }
        return forecastIsFresh(fetchedAt: fetchedAt, now: now, maxAge: maxAge)
    }
}

@MainActor
enum LiveWeatherActivityManager {
    private static let forecastFreshness: TimeInterval = 6 * 3_600
    private struct Candidate {
        let place: Place
        let rule: Rule
        let status: WeatherStatus
        let detail: String
        let expectedEndAt: Date
    }

    static func sync(
        places: [Place],
        forecasts: [UUID: [ForecastHour]],
        nearbyPlaceIDs: Set<UUID>,
        forecastUpdatedAt: [UUID: Date] = [:],
        now: Date = Date()
    ) async {
        guard LiveWeatherActivitySettings.isEnabled,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endAll()
            return
        }

        let activities = Activity<WeatherActivityAttributes>.activities
        let continuation = bestContinuationCandidate(
            for: activities,
            places: places,
            forecasts: forecasts,
            nearbyPlaceIDs: nearbyPlaceIDs,
            forecastUpdatedAt: forecastUpdatedAt,
            now: now
        )
        let candidate = continuation ?? bestStartCandidate(
            places: places,
            forecasts: forecasts,
            nearbyPlaceIDs: nearbyPlaceIDs,
            forecastUpdatedAt: forecastUpdatedAt,
            now: now
        )

        guard let candidate else {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let state = WeatherActivityAttributes.ContentState(
            eventAt: candidate.status.eventAt,
            expectedEndAt: candidate.expectedEndAt,
            detail: candidate.detail,
            possible: candidate.status.possible ?? false,
            updatedAt: now
        )
        let content = ActivityContent(
            state: state,
            staleDate: candidate.expectedEndAt,
            relevanceScore: relevanceScore(for: candidate.rule.type)
        )

        if let current = activities.first(where: {
            $0.attributes.placeID == candidate.place.id && $0.attributes.ruleID == candidate.rule.id
        }) {
            await current.update(content)
            for activity in activities where activity.id != current.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        for activity in activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let attributes = WeatherActivityAttributes(
            placeID: candidate.place.id,
            ruleID: candidate.rule.id,
            placeName: candidate.place.nameWithPreposition,
            alertType: candidate.rule.type.rawValue,
            weatherName: alertWeatherName(for: candidate.rule)
        )
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    static func endAll() async {
        for activity in Activity<WeatherActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func bestStartCandidate(
        places: [Place],
        forecasts: [UUID: [ForecastHour]],
        nearbyPlaceIDs: Set<UUID>,
        forecastUpdatedAt: [UUID: Date],
        now: Date
    ) -> Candidate? {
        sortedCandidates(
            places
            .filter(\.areNotificationsEnabled)
            .flatMap { place in
                place.rules.compactMap { rule -> Candidate? in
                    makeCandidate(
                        place: place,
                        rule: rule,
                        forecast: forecasts[place.id],
                        forecastFetchedAt: forecastUpdatedAt[place.id],
                        nearbyPlaceIDs: nearbyPlaceIDs,
                        now: now,
                        isContinuation: false
                    )
                }
            }
        ).first
    }

    private static func bestContinuationCandidate(
        for activities: [Activity<WeatherActivityAttributes>],
        places: [Place],
        forecasts: [UUID: [ForecastHour]],
        nearbyPlaceIDs: Set<UUID>,
        forecastUpdatedAt: [UUID: Date],
        now: Date
    ) -> Candidate? {
        sortedCandidates(activities.compactMap { activity in
            // Missing/deleted rules intentionally produce no candidate; sync()
            // then ends the orphaned activity.
            guard let place = places.first(where: { $0.id == activity.attributes.placeID }),
                  place.areNotificationsEnabled,
                  let rule = place.rules.first(where: { $0.id == activity.attributes.ruleID }) else { return nil }
            return makeCandidate(
                place: place,
                rule: rule,
                forecast: forecasts[place.id],
                forecastFetchedAt: forecastUpdatedAt[place.id],
                nearbyPlaceIDs: nearbyPlaceIDs,
                now: now,
                isContinuation: true
            )
        }).first
    }

    private static func makeCandidate(
        place: Place,
        rule: Rule,
        forecast: [ForecastHour]?,
        forecastFetchedAt: Date?,
        nearbyPlaceIDs: Set<UUID>,
        now: Date,
        isContinuation: Bool
    ) -> Candidate? {
        guard rule.enabled, !rule.isDisplayOnly,
              rule.type == .regn || rule.type == .sno,
              !rule.onlyWhenNearby || nearbyPlaceIDs.contains(place.id),
              let forecast,
              LiveWeatherActivityPolicy.forecastIsUsable(
                fetchedAt: forecastFetchedAt, now: now, maxAge: forecastFreshness
              ),
              let status = Planner.status(
                for: rule,
                forecast: forecast,
                frostMargin: place.localFrostMargin,
                now: now
              ) else { return nil }
        let notificationAt = Planner.plan(
            rule: rule,
            forecast: forecast,
            placeName: place.nameWithPreposition,
            placeID: place.id,
            frostMargin: place.localFrostMargin,
            now: now
        ).alerts.first?.fireAt
        if isContinuation {
            guard LiveWeatherActivityPolicy.canContinue(status, now: now) else { return nil }
        } else {
            guard let notificationAt,
                  LiveWeatherActivityPolicy.canStart(at: notificationAt, now: now) else { return nil }
        }
        let summary = precipitationSummary(
            rule: rule,
            eventAt: status.eventAt,
            forecast: forecast,
            possible: status.possible ?? false
        )
        return Candidate(
            place: place,
            rule: rule,
            status: status,
            detail: summary.detail,
            expectedEndAt: summary.endAt
        )
    }

    private static func sortedCandidates(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted {
            if $0.status.isNow != $1.status.isNow { return $0.status.isNow }
            if $0.status.eventAt != $1.status.eventAt { return $0.status.eventAt < $1.status.eventAt }
            return severity($0.rule.type) > severity($1.rule.type)
        }
    }

    private static func precipitationSummary(
        rule: Rule,
        eventAt: Date,
        forecast: [ForecastHour],
        possible: Bool
    ) -> (detail: String, endAt: Date) {
        let startIndex = forecast.indices.min {
            abs(forecast[$0].time.timeIntervalSince(eventAt)) < abs(forecast[$1].time.timeIntervalSince(eventAt))
        } ?? forecast.startIndex
        var hours: [ForecastHour] = []
        for index in startIndex..<forecast.endIndex {
            let hour = forecast[index]
            guard rule.isActive(at: hour.time), rule.matches(hour) else { break }
            hours.append(hour)
        }
        if hours.isEmpty, forecast.indices.contains(startIndex) { hours = [forecast[startIndex]] }
        let duration = max(1, hours.count)
        let endAt = eventAt.addingTimeInterval(TimeInterval(duration) * 3_600)
        let durationText = duration == 1 ? "omtrent 1 time" : "omtrent \(duration) timer"

        if rule.type == .sno {
            let amount = hours.reduce(0.0) { total, hour in
                let water = possible ? hour.precipitationRiskRate : hour.precipitationRate
                return total + estimatedFreshSnowMillimeters(waterEquivalent: water, temperature: hour.temp)
            }
            return ("Anslått \(amount.formatted(.number.precision(.fractionLength(0...1)))) mm snø · \(durationText)", endAt)
        }

        let amount = hours.reduce(0.0) { total, hour in
            total + (possible ? hour.precipitationRiskRate : hour.precipitationRate)
        }
        let prefix = possible ? "Opptil" : "Ca."
        return ("\(prefix) \(amount.formatted(.number.precision(.fractionLength(0...1)))) mm · \(durationText)", endAt)
    }

    private static func severity(_ type: AlertType) -> Int { type == .sno ? 2 : 1 }
    private static func relevanceScore(for type: AlertType) -> Double { type == .sno ? 100 : 90 }
}

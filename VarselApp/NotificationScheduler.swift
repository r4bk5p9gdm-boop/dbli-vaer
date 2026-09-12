import UserNotifications

enum NotificationRoute {
    static let placeIDKey = "placeID"
    static let requested = Notification.Name("varsel.openPlaceFromNotification")
    private static let pendingPlaceIDKey = "varsel.pendingNotificationPlaceID"

    @MainActor
    static func request(placeID: String) {
        UserDefaults.standard.set(placeID, forKey: pendingPlaceIDKey)
        NotificationCenter.default.post(name: requested, object: nil, userInfo: [placeIDKey: placeID])
    }

    static func consumePendingPlaceID() -> String? {
        let value = UserDefaults.standard.string(forKey: pendingPlaceIDKey)
        UserDefaults.standard.removeObject(forKey: pendingPlaceIDKey)
        return value
    }
}

enum NotificationCopy {
    static func title(for rule: Rule, possible: Bool = false, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        let weather = alertWeatherName(for: rule)
        let possibility = possible && languageStyle == .bokmal ? "kan bli" : "bli"
        return AppCopy.weatherHeadline(weatherName: weather, possibility: possibility)
    }

    static func title(for rule: Rule, placeName: String, possible: Bool = false, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        let weather = alertWeatherName(for: rule)
        let possibility = possible && languageStyle == .bokmal ? "kan bli" : "bli"
        let title = AppCopy.weatherHeadline(weatherName: weather, placeName: placeName, possibility: possibility)
        return possible && languageStyle == .inntrondersk ? "\(title), sjer d ut som" : title
    }

    static func message(for rule: Rule, eventAt: Date, referenceAt: Date, possible: Bool = false, eventDetail: String? = nil, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        var timing = WeatherLanguage.text(eventTimePhrase(eventAt, relativeTo: referenceAt), style: languageStyle)
        if rule.type == .sol {
            timing = "\(rule.durationHours) \(rule.durationHours == 1 ? "time" : "timer") \(timing)"
        } else {
            timing = timing.prefix(1).uppercased() + timing.dropFirst()
        }
        if !timing.hasSuffix(".") { timing += "." }
        if let eventDetail {
            let styledDetail = WeatherLanguage.text(eventDetail, style: languageStyle)
            timing += "\n\(styledDetail)"
        }
        if let name = rule.cleanedCustomName { timing += "\n\(name)" }
        return timing
    }

    static let activationRequiredBody = "Appen må startes for å aktivere varsler."
}

struct NotificationScheduleResult: Equatable {
    let requestedCount: Int
    let scheduledCount: Int
    let failedCount: Int
    let firstScheduledAt: Date?
}

/// Persisted with a request so an offline refresh can retain only alerts
/// whose rule and location still match the user's current settings.
struct NotificationPlanContext: Codable, Hashable {
    let placeID: UUID
    let placeName: String
    let latitude: Double
    let longitude: Double
    let frostMargin: Double
    let temperatureOffset: Double?
    let rule: Rule
    let languageStyle: AlertLanguageStyle

    init(place: Place, rule: Rule, languageStyle: AlertLanguageStyle) {
        placeID = place.id
        placeName = place.nameWithPreposition
        latitude = place.lat
        longitude = place.lon
        frostMargin = place.localFrostMargin
        temperatureOffset = place.temperatureOffset
        self.rule = rule
        self.languageStyle = languageStyle
    }
}

/// A complete replacement must finish before the next replacement removes
/// pending requests. Actor isolation alone would still interleave at each add.
@MainActor
final class NotificationSchedulingQueue {
    private var tail: Task<NotificationScheduleResult, Never>?
    private var generation = 0

    func enqueue(
        _ operation: @escaping @MainActor () async -> NotificationScheduleResult
    ) -> Task<NotificationScheduleResult, Never> {
        let previous = tail
        generation += 1
        let currentGeneration = generation
        let task = Task { @MainActor in
            _ = await previous?.value
            let result = await operation()
            if generation == currentGeneration { tail = nil }
            return result
        }
        tail = task
        return task
    }
}

enum NotificationScheduler {
    @MainActor private static let schedulingQueue = NotificationSchedulingQueue()
    static let pendingNotificationLimit = 64
    static let planContextKey = "weatherPlanContext"

    static func nextFireDate(for request: UNNotificationRequest) -> Date? {
        if let trigger = request.trigger as? UNTimeIntervalNotificationTrigger { return trigger.nextTriggerDate() }
        if let trigger = request.trigger as? UNCalendarNotificationTrigger { return trigger.nextTriggerDate() }
        return nil
    }

    static func nearestRequestIDs(_ dates: [(id: String, date: Date)]) -> Set<String> {
        Set(dates.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }.prefix(pendingNotificationLimit).map(\.id))
    }

    static func requestsToPreserve(
        _ requests: [UNNotificationRequest],
        places: [Place],
        missingForecastPlaceIDs: Set<UUID>,
        nearbyPlaceIDs: Set<UUID>,
        languageStyle: AlertLanguageStyle,
        now: Date
    ) -> [UNNotificationRequest] {
        requests.filter { request in
            guard let date = nextFireDate(for: request), date > now,
                  let data = request.content.userInfo[planContextKey] as? Data,
                  let context = try? JSONDecoder().decode(NotificationPlanContext.self, from: data),
                  missingForecastPlaceIDs.contains(context.placeID),
                  let place = places.first(where: { $0.id == context.placeID }),
                  place.areNotificationsEnabled,
                  let rule = place.rules.first(where: { $0.id == context.rule.id }),
                  rule.enabled, !rule.isDisplayOnly,
                  !rule.onlyWhenNearby || nearbyPlaceIDs.contains(place.id)
            else { return false }
            return context == NotificationPlanContext(place: place, rule: rule, languageStyle: languageStyle)
        }.sorted {
            let first = nextFireDate(for: $0) ?? .distantFuture
            let second = nextFireDate(for: $1) ?? .distantFuture
            return first == second ? $0.identifier < $1.identifier : first < second
        }.prefix(pendingNotificationLimit).map { $0 }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @discardableResult
    @MainActor
    static func reschedule(
        _ alerts: [PlannedAlert],
        languageStyle: AlertLanguageStyle = .bokmal,
        places: [Place] = [],
        missingForecastPlaceIDs: Set<UUID> = [],
        nearbyPlaceIDs: Set<UUID> = []
    ) async -> NotificationScheduleResult {
        await schedulingQueue.enqueue {
            await replacePendingAlerts(
                alerts, languageStyle: languageStyle, places: places,
                missingForecastPlaceIDs: missingForecastPlaceIDs, nearbyPlaceIDs: nearbyPlaceIDs
            )
        }.value
    }

    @MainActor
    private static func replacePendingAlerts(
        _ alerts: [PlannedAlert],
        languageStyle: AlertLanguageStyle,
        places: [Place],
        missingForecastPlaceIDs: Set<UUID>,
        nearbyPlaceIDs: Set<UUID>
    ) async -> NotificationScheduleResult {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let now = Date()
        var preserved = requestsToPreserve(
            pending, places: places, missingForecastPlaceIDs: missingForecastPlaceIDs,
            nearbyPlaceIDs: nearbyPlaceIDs, languageStyle: languageStyle, now: now
        )
        var requested = alertsToSchedule(alerts, now: now)
        let nearestIDs = nearestRequestIDs(
            preserved.compactMap { request in
                nextFireDate(for: request).map { (id: request.identifier, date: $0) }
            } + requested.map { (id: $0.id, date: $0.fireAt) }
        )
        preserved = preserved.filter { nearestIDs.contains($0.identifier) }
        requested = requested.filter { nearestIDs.contains($0.id) }
        let preservedIDs = Set(preserved.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { !preservedIDs.contains($0) })
        var scheduledCount = preserved.count
        var failedCount = 0
        var firstScheduledAt = preserved.compactMap { nextFireDate(for: $0) }.min()
        for a in requested {
            let c = UNMutableNotificationContent()
            c.title = NotificationCopy.title(for: a.rule, placeName: a.placeName, possible: a.possible, languageStyle: languageStyle)
            c.body = NotificationCopy.message(for: a.rule, eventAt: a.eventAt, referenceAt: a.fireAt, possible: a.possible, eventDetail: a.eventDetail, languageStyle: languageStyle)
            c.sound = a.quiet ? nil : .default
            c.interruptionLevel = a.quiet ? .passive : .active
            c.threadIdentifier = a.rule.id.uuidString
            if let placeID = a.placeID {
                c.userInfo = [NotificationRoute.placeIDKey: placeID.uuidString]
                if let place = places.first(where: { $0.id == placeID }),
                   let data = try? JSONEncoder().encode(NotificationPlanContext(place: place, rule: a.rule, languageStyle: languageStyle)) {
                    c.userInfo[planContextKey] = data
                }
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, a.fireAt.timeIntervalSince(now)), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: a.id, content: c, trigger: trigger))
                scheduledCount += 1
                firstScheduledAt = min(firstScheduledAt ?? a.fireAt, a.fireAt)
            } catch {
                failedCount += 1
            }
        }
        return NotificationScheduleResult(
            requestedCount: requested.count + preserved.count,
            scheduledCount: scheduledCount,
            failedCount: failedCount,
            firstScheduledAt: firstScheduledAt
        )
    }

    /// Makes the iOS 64-notification limit deterministic even if a caller
    /// supplies unsorted or accidentally repeated alerts.
    static func alertsToSchedule(
        _ alerts: [PlannedAlert],
        now: Date,
        limit: Int = pendingNotificationLimit
    ) -> [PlannedAlert] {
        guard limit > 0 else { return [] }
        var seenIDs: Set<String> = []
        return Array(alerts
            .filter { $0.fireAt > now }
            .sorted {
                if $0.fireAt != $1.fireAt { return $0.fireAt < $1.fireAt }
                if $0.eventAt != $1.eventAt { return $0.eventAt < $1.eventAt }
                return $0.id < $1.id
            }
            // One evening notification can represent several weather events.
            // Keep the nearest event regardless of the caller's input order.
            .filter { seenIDs.insert($0.id).inserted }
            .prefix(limit))
    }

    static func sendTest(for place: Place, languageStyle: AlertLanguageStyle = .bokmal) async -> Bool {
        guard await requestPermission() else { return false }
        let configuredRule = place.rules.first(where: { $0.enabled })
        let rule = configuredRule ?? Rule(type: .regn)
        let possible = configuredRule == nil
        let now = Date()
        let eventAt = now.addingTimeInterval(60 * 60)
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.title(for: rule, placeName: place.nameWithPreposition, possible: possible, languageStyle: languageStyle)
        content.body = NotificationCopy.message(for: rule, eventAt: eventAt, referenceAt: now, possible: possible, languageStyle: languageStyle)
        content.sound = .default
        content.interruptionLevel = .active
        content.userInfo = [NotificationRoute.placeIDKey: place.id.uuidString]
        let request = UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }
}

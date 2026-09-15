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
        let key = titleKey(for: rule, possible: possible, languageStyle: languageStyle)
        let fallback = languageStyle == .english ? "It’s {vaertype}! {sted}" : (possible && languageStyle == .bokmal ? "D kan bli {vaertype}! {sted}" : "D bli {vaertype}! {sted}")
        return LanguageCatalog.value(key, language: languageStyle.catalogCode, fallback: fallback, arguments: ["vaertype": localizedWeatherName(for: rule, languageStyle: languageStyle), "sted": "", "temperatur": rule.threshold.formatted(.number.precision(.fractionLength(0...1)))]).trimmingCharacters(in: .whitespaces)
    }

    static func title(for rule: Rule, placeName: String, possible: Bool = false, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        let key = titleKey(for: rule, possible: possible, languageStyle: languageStyle)
        let fallback = languageStyle == .english ? "It’s {vaertype}! {sted}" : (possible && languageStyle == .inntrondersk ? "D bli {vaertype}! {sted}, sjer d ut som" : (possible ? "D kan bli {vaertype}! {sted}" : "D bli {vaertype}! {sted}"))
        return LanguageCatalog.value(key, language: languageStyle.catalogCode, fallback: fallback, arguments: ["vaertype": localizedWeatherName(for: rule, languageStyle: languageStyle), "sted": placeName, "temperatur": rule.threshold.formatted(.number.precision(.fractionLength(0...1)))]).trimmingCharacters(in: .whitespaces)
    }

    private static func localizedWeatherName(for rule: Rule, languageStyle: AlertLanguageStyle) -> String {
        guard languageStyle == .english else { return alertWeatherName(for: rule) }
        switch rule.type {
        case .regn: return LanguageCatalog.value("weather.rain", language: "en", fallback: "Rain")
        case .sno: return LanguageCatalog.value("weather.snow", language: "en", fallback: "Snow")
        case .dugg: return LanguageCatalog.value("weather.dew", language: "en", fallback: "Dew")
        case .frost: return LanguageCatalog.value("weather.frost", language: "en", fallback: "Frost")
        case .temperatur:
            return LanguageCatalog.value(
                "weather.temperature_below", language: "en", fallback: "Below {temperatur}°",
                arguments: ["temperatur": rule.threshold.formatted(.number.precision(.fractionLength(0...1)))]
            )
        case .vind: return LanguageCatalog.value("weather.wind", language: "en", fallback: "Wind")
        case .sol: return LanguageCatalog.value("weather.sun", language: "en", fallback: "Sun")
        }
    }

    private static func titleKey(for rule: Rule, possible: Bool, languageStyle: AlertLanguageStyle) -> String {
        guard languageStyle == .english, !possible else { return possible ? "push.title_possible" : "push.title" }
        switch rule.type {
        case .regn: return "push.title.rain"
        case .sno: return "push.title.snow"
        case .sol: return "push.title.sun"
        case .vind: return "push.title.wind"
        case .frost: return "push.title.frost"
        case .dugg: return "push.title.dew"
        case .temperatur: return "push.title.temperature_below"
        }
    }

    static func message(for rule: Rule, eventAt: Date, referenceAt: Date, possible: Bool = false, eventDetail: String? = nil, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        var timing = WeatherLanguage.text(eventTimePhrase(eventAt, relativeTo: referenceAt), style: languageStyle)
        if rule.type == .sol {
            let unit = languageStyle == .english
                ? (rule.durationHours == 1 ? "hour" : "hours")
                : (rule.durationHours == 1 ? "time" : "timer")
            timing = "\(rule.durationHours) \(unit) \(timing)"
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

    static func activationRequiredBody(languageStyle: AlertLanguageStyle = .bokmal) -> String {
        LanguageCatalog.value(
            "push.activation_required", language: languageStyle.catalogCode,
            fallback: "Appen må startes for å aktivere varsler."
        )
    }
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

protocol NotificationCenterClient: AnyObject {
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: NotificationCenterClient {}

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

    /// Remove only requests that are definitely stale. A failed replacement
    /// keeps an existing request with the same identifier as a safe fallback.
    static func stalePendingRequestIDs(
        pendingIDs: [String], preservedIDs: Set<String>,
        successfulIDs: Set<String>, failedIDs: Set<String>
    ) -> [String] {
        pendingIDs.filter {
            !preservedIDs.contains($0) &&
            !successfulIDs.contains($0) &&
            !failedIDs.contains($0)
        }
    }

    static func failedReplacementFallbackIDs(
        pending: [UNNotificationRequest], failedIDs: Set<String>,
        replacementContexts: [String: Data]
    ) -> Set<String> {
        Set(failedIDs.filter { id in
            guard let old = pending.first(where: { $0.identifier == id }),
                  let oldContext = old.content.userInfo[planContextKey] as? Data,
                  let replacementContext = replacementContexts[id] else { return false }
            return oldContext == replacementContext
        })
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
    static func replacePendingAlerts(
        _ alerts: [PlannedAlert],
        languageStyle: AlertLanguageStyle,
        places: [Place],
        missingForecastPlaceIDs: Set<UUID>,
        nearbyPlaceIDs: Set<UUID>,
        center: any NotificationCenterClient = UNUserNotificationCenter.current()
    ) async -> NotificationScheduleResult {
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
        var scheduledCount = preserved.count
        var failedCount = 0
        var successfulIDs: Set<String> = []
        var failedIDs: Set<String> = []
        var replacementContexts: [String: Data] = [:]
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
                    replacementContexts[a.id] = data
                }
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, a.fireAt.timeIntervalSince(now)), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: a.id, content: c, trigger: trigger))
                scheduledCount += 1
                successfulIDs.insert(a.id)
                firstScheduledAt = min(firstScheduledAt ?? a.fireAt, a.fireAt)
            } catch {
                failedCount += 1
                failedIDs.insert(a.id)
            }
        }
        let staleIDs = stalePendingRequestIDs(
            pendingIDs: pending.map(\.identifier), preservedIDs: preservedIDs,
            successfulIDs: successfulIDs,
            failedIDs: failedReplacementFallbackIDs(
                pending: pending, failedIDs: failedIDs, replacementContexts: replacementContexts
            )
        )
        center.removePendingNotificationRequests(withIdentifiers: staleIDs)
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
                let firstSeverity = severity(of: $0.rule.type)
                let secondSeverity = severity(of: $1.rule.type)
                if firstSeverity != secondSeverity { return firstSeverity > secondSeverity }
                return $0.id < $1.id
            }
            // One evening notification can represent several weather events.
            // Keep the nearest event regardless of the caller's input order.
            .filter { seenIDs.insert($0.id).inserted }
            .prefix(limit))
    }

    private static func severity(of type: AlertType) -> Int {
        switch type {
        case .frost, .sno: return 3
        case .vind: return 2
        default: return 1
        }
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

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
        return "D \(possibility) \(weather)!"
    }

    static func title(for rule: Rule, placeName: String, possible: Bool = false, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        let title = "\(title(for: rule, possible: possible, languageStyle: languageStyle)) \(placeName)"
        return possible && languageStyle == .inntrondersk ? "\(title), sjer d ut som" : title
    }

    static func message(for rule: Rule, eventAt: Date, referenceAt: Date, possible: Bool = false, eventDetail: String? = nil, languageStyle: AlertLanguageStyle = .bokmal) -> String {
        var timing = eventTimePhrase(eventAt, relativeTo: referenceAt)
        if languageStyle == .inntrondersk {
            timing = timing
                .replacingOccurrences(of: "i overmorgen", with: "i overmårrå")
                .replacingOccurrences(of: "i morgen", with: "i mårrå")
        }
        if rule.type == .sol {
            timing = "\(rule.durationHours) \(rule.durationHours == 1 ? "time" : "timer") \(timing)"
        } else {
            timing = timing.prefix(1).uppercased() + timing.dropFirst()
        }
        if !timing.hasSuffix(".") { timing += "." }
        if let eventDetail {
            let styledDetail = languageStyle == .inntrondersk
                ? eventDetail.replacingOccurrences(of: " til ", with: " te ")
                : eventDetail
            timing += "\n\(styledDetail)"
        }
        if let name = rule.cleanedCustomName { timing += "\n\(name)" }
        return timing
    }

    static let activationRequiredBody = "Appen må startes for å aktivere varsler."
}

enum NotificationScheduler {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(_ alerts: [PlannedAlert], languageStyle: AlertLanguageStyle = .bokmal) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        let now = Date()
        // iOS allows at most 64 pending local notifications per app.
        for a in alerts.filter({ $0.fireAt > now }).prefix(64) {
            let c = UNMutableNotificationContent()
            c.title = NotificationCopy.title(for: a.rule, placeName: a.placeName, possible: a.possible, languageStyle: languageStyle)
            c.body = NotificationCopy.message(for: a.rule, eventAt: a.eventAt, referenceAt: a.fireAt, possible: a.possible, eventDetail: a.eventDetail, languageStyle: languageStyle)
            c.sound = a.quiet ? nil : .default
            c.interruptionLevel = a.quiet ? .passive : .active
            c.threadIdentifier = a.rule.id.uuidString
            if let placeID = a.placeID {
                c.userInfo = [NotificationRoute.placeIDKey: placeID.uuidString]
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, a.fireAt.timeIntervalSince(now)), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: a.id, content: c, trigger: trigger))
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

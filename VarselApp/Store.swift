import Foundation
import WidgetKit

struct PersistedStoreState: Codable {
    var places: [Place]
    var selectedID: UUID?
    var log: [LogEntry]

    private enum CodingKeys: String, CodingKey { case places, selectedID, log }

    init(places: [Place], selectedID: UUID?, log: [LogEntry]) {
        self.places = places
        self.selectedID = selectedID
        self.log = log
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        places = (try? values.decode([LossyDecodable<Place>].self, forKey: .places))?.compactMap(\.value) ?? []
        selectedID = try? values.decode(UUID.self, forKey: .selectedID)
        log = (try? values.decode([LossyDecodable<LogEntry>].self, forKey: .log))?.compactMap(\.value) ?? []
    }
}

struct ForecastLocation: Hashable {
    let latitudeE4: Int
    let longitudeE4: Int

    init(place: Place) {
        latitudeE4 = Int((place.lat * 10_000).rounded())
        longitudeE4 = Int((place.lon * 10_000).rounded())
    }

    var latitude: Double { Double(latitudeE4) / 10_000 }
    var longitude: Double { Double(longitudeE4) / 10_000 }
}

@MainActor
final class Store: ObservableObject {
    // Foreground and background work must share live rules and forecasts.
    // A separate instance can overwrite newer settings when its log is saved.
    static let shared = Store()
    static let forecastRequestConcurrencyLimit = 4
    @Published var places: [Place] { didSet { save() } }
    @Published var selectedID: UUID? { didSet { save() } }
    @Published var forecasts: [UUID: [ForecastHour]] = [:]
    @Published private(set) var forecastErrors: [UUID: String] = [:]
    @Published var log: [LogEntry] = [] { didSet { save() } }
    @Published var lastUpdate: Date?
    @Published var isRefreshing = false
    @Published var notificationsAuthorized: Bool?
    @Published var alertLanguageStyle: AlertLanguageStyle {
        didSet {
            UserDefaults.standard.set(alertLanguageStyle.rawValue, forKey: languageStyleKey)
            Task { await replan() }
        }
    }
    @Published private(set) var nearbyPlaceIDs: Set<UUID> = []

    private let key = "varsel.state"
    private let languageStyleKey = "varsel.alertLanguageStyle"
    private let launchPlacesVersionKey = "varsel.launchPlacesVersion"
    private let launchPlacesVersion = 9
    private var proximityMonitor: ProximityMonitor!

    static var launchPlaces: [Place] {
        var weekendSun = Rule(type: .sol)
        weekendSun.templateTitle = "Sol i helga"
        weekendSun.memoSuggestion = "Finn fram tursekken!"
        weekendSun.threshold = 25
        weekendSun.durationHours = 5
        weekendSun.activeFromHour = 8
        weekendSun.activeToHour = 20
        weekendSun.days = [5, 6]
        weekendSun.previousDayNotificationHour = 21
        weekendSun.notificationWeekday = 3
        weekendSun.leadMinutes = 180
        weekendSun.repeatsEnabled = false
        return [
            Place(name: "Klinga", lat: 64.4094, lon: 11.47786, preposition: .pa),
            Place(name: "Namsos", lat: 64.46624, lon: 11.49572, preposition: .nerri),
            Place(name: "Hornburu", lat: 64.199133, lon: 11.403575, preposition: .oppa),
            Place(name: "Selbu", lat: 63.22474, lon: 11.03138, preposition: .oppi, rules: [weekendSun]),
            Place(name: "Bangdalen", lat: 64.37042, lon: 11.51629, preposition: .inni),
        ]
    }

    private init() {
        alertLanguageStyle = AlertLanguageStyle.persisted(
            UserDefaults.standard.string(forKey: "varsel.alertLanguageStyle") ?? ""
        ) ?? .bokmal
        if let d = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode(PersistedStoreState.self, from: d),
           !p.places.isEmpty {
            places = p.places; selectedID = p.selectedID; log = p.log
        } else {
            places = Self.launchPlaces; selectedID = places.first?.id; log = []
            UserDefaults.standard.set(launchPlacesVersion, forKey: launchPlacesVersionKey)
        }

        if selectedID.map({ id in places.contains { $0.id == id } }) != true {
            selectedID = places.first?.id
        }

        if UserDefaults.standard.integer(forKey: launchPlacesVersionKey) < launchPlacesVersion {
            for launchPlace in Self.launchPlaces {
                if let index = places.firstIndex(where: {
                    $0.name.compare(launchPlace.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }) {
                    places[index].preposition = launchPlace.preposition
                } else {
                    places.append(launchPlace)
                }
            }
            let standardNames = Self.launchPlaces.map(\.name)
            let standardNameSet = Set(standardNames.map { $0.lowercased() })
            let orderedStandards = standardNames.compactMap { standardName in
                places.first { $0.name.compare(standardName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            }
            let otherPlaces = places.filter { !standardNameSet.contains($0.name.lowercased()) }
            places = orderedStandards + otherPlaces
            for placeIndex in places.indices {
                for ruleIndex in places[placeIndex].rules.indices {
                    let rule = places[placeIndex].rules[ruleIndex]
                    let isNightRule = rule.activeFromHour > rule.activeToHour
                    let isNextDayRule = rule.leadMinutes >= 12 * 60
                    if rule.previousDayNotificationHour == nil && (isNightRule || isNextDayRule) {
                        places[placeIndex].rules[ruleIndex].previousDayNotificationHour = 21
                        places[placeIndex].rules[ruleIndex].previousDayNotificationMinute = 0
                        places[placeIndex].rules[ruleIndex].repeatsEnabled = false
                    }
                    let usesOldNightWindow = (rule.activeFromHour == 22 && rule.activeToHour == 7)
                        || (rule.activeFromHour == 20 && rule.activeToHour == 8)
                    if usesOldNightWindow && places[placeIndex].rules[ruleIndex].previousDayNotificationHour != nil {
                        places[placeIndex].rules[ruleIndex].activeFromHour = 23
                        places[placeIndex].rules[ruleIndex].activeToHour = 7
                    }
                }
                if places[placeIndex].frostMargin == nil {
                    let searchableName = "\(places[placeIndex].name) \(places[placeIndex].customName ?? "")"
                    if searchableName.range(of: "Andersmovegen", options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                        places[placeIndex].frostMargin = 2.5
                    }
                }
            }
            if let selbuIndex = places.firstIndex(where: {
                $0.name.compare("Selbu", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }), !places[selbuIndex].rules.contains(where: { $0.templateTitle == "Sol i helga" }) {
                places[selbuIndex].rules.append(Self.launchPlaces[3].rules[0])
            }
            let oldAutomaticNotes: [String: String] = [
                "Regn neste dag": "Husk regntøy",
                "Regn i natt": "Ta inn det som ikke tåler regn",
                "Dugg i morgen": "Fare for kondens",
                "Sol i morgen": "Klipp gresset!",
                "Snø i natt": "Beregn ekstra kjøretid",
                "Snø i morgen": "Finn fram snøskuffa",
                "Frost i natt": "Dekk til plantene",
                "Vind i natt": "Sikre løse gjenstander",
                "Vind i morgen": "Ta inn putene",
                "Sol i helga": "Finn fram tursekken!",
                "Kraftige vindkast": "Sikre utemøbler og trampoline",
                "Ekstreme vindkast": "Følg farevarslene fra MET",
                "Regn i dag": "Husk regntøy",
                "Sol i dag": "Utnytt dagen!",
                "Snø i dag": "Beregn ekstra kjøretid",
                "Vind i dag": "Fest løse gjenstander",
                "Regn senere i dag": "Husk regntøy",
                "Snø senere i dag": "Beregn ekstra kjøretid",
                "Vindkast senere i dag": "Fest løse gjenstander",
                "Regn i helga": "Planlegg helga",
            ]
            for placeIndex in places.indices {
                for ruleIndex in places[placeIndex].rules.indices {
                    guard let suggestion = oldAutomaticNotes[places[placeIndex].rules[ruleIndex].templateTitle] else { continue }
                    places[placeIndex].rules[ruleIndex].memoSuggestion = suggestion
                    if places[placeIndex].rules[ruleIndex].customName == suggestion {
                        places[placeIndex].rules[ruleIndex].customName = ""
                    }
                }
            }
            UserDefaults.standard.set(launchPlacesVersion, forKey: launchPlacesVersionKey)
        }

        let monitor = ProximityMonitor()
        proximityMonitor = monitor
        nearbyPlaceIDs = monitor.nearbyPlaceIDs
        monitor.onChange = { [weak self] nearbyIDs in
            guard let self else { return }
            self.nearbyPlaceIDs = nearbyIDs
            Task { await self.replan() }
        }
        monitor.configure(for: places)
    }

    var selected: Place? { places.first { $0.id == selectedID } ?? places.first }
    var selectedForecast: [ForecastHour] { selected.flatMap { forecasts[$0.id] } ?? [] }
    var error: String? { selected.flatMap { forecastErrors[$0.id] } }

    func update(_ place: Place) {
        if let i = places.firstIndex(where: { $0.id == place.id }) { places[i] = place } else { places.append(place) }
        proximityMonitor.configure(for: places)
    }

    func requestNearbyAuthorization() {
        proximityMonitor.requestBackgroundAuthorization()
        proximityMonitor.configure(for: places)
    }

    static func placesNeededForBackgroundRefresh(_ places: [Place], selectedID: UUID?) -> [Place] {
        places.filter { place in
            place.id == selectedID || (
                place.areNotificationsEnabled
                    && place.rules.contains { $0.enabled && !$0.isDisplayOnly }
            )
        }
    }

    static func groupedByForecastLocation(_ places: [Place]) -> [ForecastLocation: [Place]] {
        Dictionary(grouping: places, by: ForecastLocation.init(place:))
    }

    /// Resolve against live places after a network suspension. A response for
    /// a removed or relocated place must not restore its obsolete forecast.
    static func currentRecipients(for requestedPlaces: [Place], in currentPlaces: [Place]) -> [Place] {
        let requestedLocations = Dictionary(
            requestedPlaces.map { ($0.id, ForecastLocation(place: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return currentPlaces.filter { requestedLocations[$0.id] == ForecastLocation(place: $0) }
    }

    static func shouldFinalizeRefresh(successfulPlaceCount: Int, failedPlaceCount: Int) -> Bool {
        // An empty place list is intentional; a complete network failure is not.
        successfulPlaceCount > 0 || failedPlaceCount == 0
    }

    @discardableResult
    func refreshAll(backgroundOnly: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isRefreshing else { return true }
        isRefreshing = true
        defer { isRefreshing = false }

        let requestedPlaces = backgroundOnly
            ? Self.placesNeededForBackgroundRefresh(places, selectedID: selectedID)
            : places
        let locationGroups = Self.groupedByForecastLocation(requestedPlaces)
        var failedNames: [String] = []
        var successfulPlaceCount = 0
        let locations = Array(locationGroups.keys)
        for batchStart in stride(from: 0, to: locations.count, by: Self.forecastRequestConcurrencyLimit) {
            guard !Task.isCancelled else { return false }
            let batchEnd = min(batchStart + Self.forecastRequestConcurrencyLimit, locations.count)
            let batch = locations[batchStart..<batchEnd]
            await withTaskGroup(of: (ForecastLocation, Result<[ForecastHour], Error>).self) { group in
                for location in batch {
                    group.addTask {
                        do {
                            return (location, .success(try await YrService.fetch(lat: location.latitude, lon: location.longitude)))
                        } catch {
                            return (location, .failure(error))
                        }
                    }
                }
                for await (location, result) in group {
                    // Cancellation is not a forecast failure, and must not
                    // replace useful data or trigger an incomplete alert plan.
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    let matchingPlaces = Self.currentRecipients(
                        for: locationGroups[location] ?? [], in: places
                    )
                    switch result {
                    case .success(let forecast):
                        successfulPlaceCount += matchingPlaces.count
                        for place in matchingPlaces {
                            forecasts[place.id] = forecast
                            forecastErrors.removeValue(forKey: place.id)
                        }
                    case .failure(let error):
                        for place in matchingPlaces {
                            failedNames.append(place.displayName)
                            forecastErrors[place.id] = forecastErrorMessage(for: place, error: error)
                        }
                    }
                }
            }
        }
        guard !Task.isCancelled else { return false }
        guard Self.shouldFinalizeRefresh(
            successfulPlaceCount: successfulPlaceCount, failedPlaceCount: failedNames.count
        ) else { return false }
        lastUpdate = Date()
        await replan()
        return failedNames.isEmpty
    }

    func replan() async {
        guard !Task.isCancelled else { return }
        let alerts = Planner.planAll(places: places, forecasts: forecasts, nearbyPlaceIDs: nearbyPlaceIDs)
        let scheduleResult = await NotificationScheduler.reschedule(
            alerts, languageStyle: alertLanguageStyle, places: places,
            missingForecastPlaceIDs: Set(places.filter { (forecasts[$0.id] ?? []).isEmpty }.map(\.id)),
            nearbyPlaceIDs: nearbyPlaceIDs
        )
        await LiveWeatherActivityManager.sync(
            places: places,
            forecasts: forecasts,
            nearbyPlaceIDs: nearbyPlaceIDs
        )
        updateWidget()
        let text = Self.notificationPlanLogText(scheduleResult)
        log.insert(LogEntry(time: Date(), text: text), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }

    static func notificationPlanLogText(_ result: NotificationScheduleResult) -> String {
        if result.requestedCount == 0 {
            return "Varslingsplan oppdatert – ingen varsler planlagt."
        }
        if result.failedCount > 0 {
            if result.scheduledCount == 0 {
                return "Kunne ikke aktivere \(result.requestedCount) planlagte varsler."
            }
            return "Varslingsplan delvis oppdatert – \(result.scheduledCount) av \(result.requestedCount) varsler aktivert."
        }
        let first = result.firstScheduledAt.map { ", første \(eventTimePhrase($0))" } ?? ""
        return "Varslingsplan oppdatert – \(result.scheduledCount) varsler planlagt\(first)."
    }

    func select(_ place: Place) {
        selectedID = place.id
        updateWidget()
    }

    func add(_ place: Place) async {
        places.append(place)
        selectedID = place.id
        proximityMonitor.configure(for: places)
        do {
            let forecast = try await YrService.fetch(lat: place.lat, lon: place.lon)
            guard !Task.isCancelled,
                  !Self.currentRecipients(for: [place], in: places).isEmpty else { return }
            forecasts[place.id] = forecast
            forecastErrors.removeValue(forKey: place.id)
            lastUpdate = Date()
        } catch {
            guard !Task.isCancelled,
                  let currentPlace = Self.currentRecipients(for: [place], in: places).first else { return }
            forecastErrors[place.id] = forecastErrorMessage(for: currentPlace, error: error)
        }
        await replan()
    }

    func removePlaces(at offsets: IndexSet) {
        let removedIDs = Set(offsets.compactMap { places.indices.contains($0) ? places[$0].id : nil })
        places.remove(atOffsets: offsets)
        for id in removedIDs {
            forecasts.removeValue(forKey: id)
            forecastErrors.removeValue(forKey: id)
        }
        if selectedID.map(removedIDs.contains) == true { selectedID = places.first?.id }
        proximityMonitor.configure(for: places)
        Task { await replan() }
    }

    func removePlaces(ids: Set<UUID>) {
        let offsets = IndexSet(places.indices.filter { ids.contains(places[$0].id) })
        removePlaces(at: offsets)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(PersistedStoreState(places: places, selectedID: selectedID, log: log)) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    private func updateWidget() {
        guard let place = selected else {
            SharedWidgetData.clear()
            WatchSyncManager.shared.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        let forecast = forecasts[place.id] ?? []
        let updatedAt = lastUpdate ?? Date()
        SharedWidgetData.save(place: place, forecast: forecast, updatedAt: updatedAt)
        WatchSyncManager.shared.send(place: place, forecast: forecast, updatedAt: updatedAt)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func forecastErrorMessage(for place: Place, error: Error) -> String {
        let hasOldForecast = !(forecasts[place.id] ?? []).isEmpty
        let prefix = hasOldForecast ? "Viser sist hentede prognose for \(place.displayName). " : ""
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return prefix + "Ingen nettforbindelse. Dra ned for å prøve igjen."
            case .timedOut:
                return prefix + "MET brukte for lang tid. Dra ned for å prøve igjen."
            case .badServerResponse:
                return prefix + "MET kunne ikke levere prognosen akkurat nå."
            default: break
            }
        }
        if error is DecodingError {
            return prefix + "Prognosen fra MET kunne ikke leses."
        }
        return prefix + "Kunne ikke oppdatere prognosen. Dra ned for å prøve igjen."
    }
}

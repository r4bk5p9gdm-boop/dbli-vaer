import Foundation
import WidgetKit

@MainActor
final class Store: ObservableObject {
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
    private struct Persisted: Codable { var places: [Place]; var selectedID: UUID?; var log: [LogEntry] }

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

    init() {
        alertLanguageStyle = AlertLanguageStyle(
            rawValue: UserDefaults.standard.string(forKey: "varsel.alertLanguageStyle") ?? ""
        ) ?? .bokmal
        if let d = UserDefaults.standard.data(forKey: key), let p = try? JSONDecoder().decode(Persisted.self, from: d) {
            places = p.places; selectedID = p.selectedID; log = p.log
        } else {
            places = Self.launchPlaces; selectedID = places.first?.id; log = []
            UserDefaults.standard.set(launchPlacesVersion, forKey: launchPlacesVersionKey)
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

    @discardableResult
    func refreshAll() async -> Bool {
        guard !isRefreshing else { return true }
        isRefreshing = true
        defer { isRefreshing = false }

        let requestedPlaces = places
        var failedNames: [String] = []
        await withTaskGroup(of: (Place, Result<[ForecastHour], Error>).self) { group in
            for place in requestedPlaces {
                group.addTask {
                    do { return (place, .success(try await YrService.fetch(lat: place.lat, lon: place.lon))) }
                    catch { return (place, .failure(error)) }
                }
            }
            for await (place, result) in group {
                switch result {
                case .success(let forecast):
                    forecasts[place.id] = forecast
                    forecastErrors.removeValue(forKey: place.id)
                case .failure(let error):
                    failedNames.append(place.displayName)
                    forecastErrors[place.id] = forecastErrorMessage(for: place, error: error)
                }
            }
        }
        lastUpdate = Date()
        await replan()
        return failedNames.isEmpty
    }

    func replan() async {
        let alerts = Planner.planAll(places: places, forecasts: forecasts, nearbyPlaceIDs: nearbyPlaceIDs)
        await NotificationScheduler.reschedule(alerts, languageStyle: alertLanguageStyle)
        await LiveWeatherActivityManager.sync(
            places: places,
            forecasts: forecasts,
            nearbyPlaceIDs: nearbyPlaceIDs
        )
        updateWidget()
        let text = alerts.isEmpty ? "Varslingsplan oppdatert – ingen varsler planlagt."
            : "Varslingsplan oppdatert – \(alerts.count) varsler planlagt, første \(eventTimePhrase(alerts[0].fireAt))."
        log.insert(LogEntry(time: Date(), text: text), at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
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
            forecasts[place.id] = try await YrService.fetch(lat: place.lat, lon: place.lon)
            forecastErrors.removeValue(forKey: place.id)
            lastUpdate = Date()
        } catch {
            forecastErrors[place.id] = forecastErrorMessage(for: place, error: error)
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
        if let d = try? JSONEncoder().encode(Persisted(places: places, selectedID: selectedID, log: log)) {
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

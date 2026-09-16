import Foundation
import WidgetKit
import CoreLocation

struct CalibrationForecast: Codable, Identifiable {
    var id = UUID()
    let place: Place
    let fetchedAt: Date
    let hours: [ForecastHour]
}

struct LocalWeatherObservation: Codable, Identifiable {
    var id = UUID()
    let place: Place
    let observedAt: Date
    let registeredAt: Date
    let measuredTemperature: Double?
    let frost: Bool?
    let surface: String
    let forecastFetchedAt: Date?
    let evidence: [ForecastHour]
    let nightForecast: CalibrationForecast?

    var suggestedTemperatureOffset: Double? {
        guard let measuredTemperature, let hour = evidence.first else { return nil }
        return measuredTemperature - (hour.yrTemperature ?? hour.temp)
    }
}

struct CalibrationHistory: Codable {
    var forecasts: [CalibrationForecast] = []
    var observations: [LocalWeatherObservation] = []
    static let retention: TimeInterval = 48 * 3600
    private static let key = "varsel.calibrationHistory.v1"

    mutating func prune(now: Date) {
        forecasts.removeAll { $0.fetchedAt < now.addingTimeInterval(-Self.retention) || $0.fetchedAt > now }
    }

    mutating func record(place: Place, hours: [ForecastHour], fetchedAt: Date) {
        prune(now: fetchedAt)
        guard !hours.isEmpty else { save(); return }
        // Retain forecast versions: a later update must not erase what was
        // available when an earlier observation was made.
        forecasts.append(CalibrationForecast(place: place, fetchedAt: fetchedAt,
            hours: hours.filter { $0.time <= fetchedAt.addingTimeInterval(Self.retention) }.map { $0.locallyAdjusted(by: 0) }))
        save()
    }

    func observation(place: Place, at date: Date, temperature: Double?, frost: Bool?, surface: String, now: Date = Date()) -> LocalWeatherObservation {
        let nightStart = Calendar.current.startOfDay(for: date).addingTimeInterval(-3600)
        let cutoff = temperature == nil && frost != nil ? nightStart : date
        let source = forecasts.filter {
            $0.place.id == place.id && ForecastLocation(place: $0.place) == ForecastLocation(place: place)
                && $0.fetchedAt <= cutoff && $0.fetchedAt >= now.addingTimeInterval(-Self.retention)
        }.max { $0.fetchedAt < $1.fetchedAt }
        let evidence: [ForecastHour]
        if temperature != nil {
            let nearest = source?.hours.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
            evidence = nearest.map { abs($0.time.timeIntervalSince(date)) <= 1800 ? [$0] : [] } ?? []
        } else {
            evidence = source?.hours.filter { $0.time >= nightStart && $0.time <= date } ?? []
        }
        let nightSource = frost == nil ? nil : forecasts.filter {
            $0.place.id == place.id && ForecastLocation(place: $0.place) == ForecastLocation(place: place)
                && $0.fetchedAt <= nightStart && $0.fetchedAt >= now.addingTimeInterval(-Self.retention)
        }.max { $0.fetchedAt < $1.fetchedAt }
        let night = nightSource.map { CalibrationForecast(place: $0.place, fetchedAt: $0.fetchedAt,
            hours: $0.hours.filter { $0.time >= nightStart && $0.time <= date }) }
        return LocalWeatherObservation(place: source?.place ?? place, observedAt: date, registeredAt: now,
            measuredTemperature: temperature, frost: frost, surface: surface,
            forecastFetchedAt: source?.fetchedAt, evidence: evidence, nightForecast: night)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key), var history = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        history.prune(now: Date())
        history.save()
        return history
    }
}

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

enum ForecastRefreshError: Error {
    case emptyForecast
}

/// Serialize full and background refreshes without falsely reporting success
/// for a refresh that was skipped. Each operation reads live places on start.
@MainActor
final class ForecastRefreshQueue {
    private var tail: Task<Bool, Never>?
    private var generation = 0

    func enqueue(_ operation: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        // Chained tasks serialize rapid refreshes; cancelling an obsolete
        // waiter lets the newest queued operation run next.
        let previous = tail
        generation += 1
        let currentGeneration = generation
        let task = Task { @MainActor in
            defer { if generation == currentGeneration { tail = nil } }
            _ = await previous?.value
            guard !Task.isCancelled else { return false }
            return await operation()
        }
        tail = task
        return task
    }
}

@MainActor
final class Store: ObservableObject {
    static func shouldApplyCurrentLocation(selectionAtRequestStart: UUID?, currentSelection: UUID?) -> Bool {
        selectionAtRequestStart == currentSelection
    }
    // Foreground and background work must share live rules and forecasts.
    // A separate instance can overwrite newer settings when its log is saved.
    static let shared = Store()
    static let forecastRequestConcurrencyLimit = 4
    @Published var places: [Place] {
        didSet {
            for id in Self.invalidatedForecastIDs(previous: oldValue, current: places) {
                forecasts.removeValue(forKey: id)
                forecastErrors.removeValue(forKey: id)
                forecastUpdatedAt.removeValue(forKey: id)
            }
            save()
        }
    }
    @Published var selectedID: UUID? {
        didSet {
            // Direct selection changes (notification routes, restored state or
            // imports) are manual unless the GPS startup flow explicitly marks
            // them as current-location selections immediately afterward.
            selectionIsCurrentLocation = false
            save()
        }
    }
    /// True when the current home page was selected from the phone's live position.
    /// Manual place selection clears this marker so the UI never implies GPS data
    /// for a place the user chose explicitly.
    @Published private(set) var selectionIsCurrentLocation = false
    @Published var homeFavorites: HomeFavorites = {
        guard let data = UserDefaults.standard.data(forKey: "varsel.homeFavorites"),
              let value = try? JSONDecoder().decode(HomeFavorites.self, from: data) else { return HomeFavorites() }
        return value
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(homeFavorites) {
                UserDefaults.standard.set(data, forKey: "varsel.homeFavorites")
            }
        }
    }
    var resolvedHomeFavorites: HomeFavorites {
        homeFavorites.resolved(availableIDs: Set(places.map(\.id)))
    }
    @Published var sharedPlaceSelection: SharedPlaceSelection = {
        guard let data = UserDefaults.standard.data(forKey: "varsel.sharedPlaces"), let value = try? JSONDecoder().decode(SharedPlaceSelection.self, from: data) else { return SharedPlaceSelection() }
        return value
    }() {
        didSet { if let data = try? JSONEncoder().encode(sharedPlaceSelection) { UserDefaults.standard.set(data, forKey: "varsel.sharedPlaces") } }
    }
    var resolvedSharedPlaceIDs: [UUID] { sharedPlaceSelection.resolved(available: places) }
    @Published private var rawForecasts: [UUID: [ForecastHour]] = [:]
    var forecasts: [UUID: [ForecastHour]] {
        get {
            rawForecasts.map { id, hours in
                (id, hours.map { $0.locallyAdjusted(by: places.first(where: { $0.id == id })?.localTemperatureOffset ?? 0) })
            }.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        set { rawForecasts = newValue.mapValues { $0.map { $0.locallyAdjusted(by: 0) } } }
    }
    @Published private(set) var calibration = CalibrationHistory.load()
    @Published private(set) var forecastErrors: [UUID: String] = [:]
    @Published var log: [LogEntry] = [] { didSet { save() } }
    @Published var lastUpdate: Date?
    private var forecastUpdatedAt: [UUID: Date] = [:]
    @Published var isRefreshing = false
    @Published var notificationsAuthorized: Bool?
    @Published var alertLanguageStyle: AlertLanguageStyle {
        didSet {
            UserDefaults.standard.set(alertLanguageStyle.rawValue, forKey: languageStyleKey)
            updateWidget()
            Task { await replan() }
        }
    }
    @Published private(set) var nearbyPlaceIDs: Set<UUID> = []
    private var lastReplanSignature: Int?
    private var lastReplanAt: Date?

    private let key = "varsel.state"
    private let languageStyleKey = "varsel.alertLanguageStyle"
    private let launchPlacesVersionKey = "varsel.launchPlacesVersion"
    private let launchPlacesVersion = 9
    private var proximityMonitor: ProximityMonitor!
    private let refreshQueue = ForecastRefreshQueue()

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
            // Restored selection is authoritative when GPS is unavailable;
            // location lookup is only attempted by the explicit startup flow.
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

    /// Select the saved place nearest the phone at launch, or add a lightweight
    /// current-location place when no saved place is nearby.
    func selectCurrentLocationIfPossible() async {
        // Do not let a slow GPS lookup overwrite a place the user selected
        // while the lookup was in flight (for example from a notification or
        // a swipe). The startup selection is only valid if the selection is
        // still the one that was visible when the request began.
        let selectionAtRequestStart = selectedID
        // Clear a previous GPS badge before attempting a new lookup. If
        // permission is denied or the request fails, the existing place remains
        // visible but is never presented as freshly position-based.
        selectionIsCurrentLocation = false
        // Location is an optional enhancement; manual selection and its
        // existing notifications remain fully usable when access is denied.
        let locationManager = LocationManager()
        guard let location = try? await locationManager.current() else { return }
        guard Self.shouldApplyCurrentLocation(
            selectionAtRequestStart: selectionAtRequestStart,
            currentSelection: selectedID
        ) else { return }
        let nearest = places.min { a, b in
            CLLocation(latitude: a.lat, longitude: a.lon).distance(from: location)
                < CLLocation(latitude: b.lat, longitude: b.lon).distance(from: location)
        }
        if let nearest,
           CLLocation(latitude: nearest.lat, longitude: nearest.lon).distance(from: location) <= 15_000 {
            select(nearest, fromCurrentLocation: true)
            return
        }
        let name = await LocationManager.name(for: location)
        if let existing = places.first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            select(existing, fromCurrentLocation: true)
            return
        }
        let place = Place(name: name, lat: location.coordinate.latitude, lon: location.coordinate.longitude, preposition: .pa)
        places.append(place)
        select(place, fromCurrentLocation: true)
    }

    func update(_ place: Place) {
        if let i = places.firstIndex(where: { $0.id == place.id }) { places[i] = place } else { places.append(place) }
        proximityMonitor.configure(for: places)
    }

    func requestNearbyAuthorization() {
        proximityMonitor.requestBackgroundAuthorization()
        proximityMonitor.configure(for: places)
    }

    func recordObservation(place: Place, at date: Date, temperature: Double?, frost: Bool?, surface: String) {
        calibration.prune(now: Date())
        calibration.observations.insert(calibration.observation(place: place, at: date, temperature: temperature, frost: frost, surface: surface), at: 0)
        calibration.save()
    }

    func removeObservation(id: UUID) {
        calibration.observations.removeAll { $0.id == id }
        calibration.save()
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

    /// Returns one stable request location per API coordinate. Quantizing to
    /// Yr's four-decimal precision keeps aliases on the same request, while
    /// sorting makes refresh order deterministic for logs and retries.
    static func forecastLocations(in places: [Place]) -> [ForecastLocation] {
        groupedByForecastLocation(places).keys.sorted {
            ($0.latitudeE4, $0.longitudeE4) < ($1.latitudeE4, $1.longitudeE4)
        }
    }

    static func invalidatedForecastIDs(previous: [Place], current: [Place]) -> Set<UUID> {
        Set(previous.filter { old in
            guard let new = current.first(where: { $0.id == old.id }) else { return true }
            return ForecastLocation(place: old) != ForecastLocation(place: new)
        }.map(\.id))
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
        // Cancellation returns before this decision; a zero-success run with
        // failures must never finalize and replan partial data.
        successfulPlaceCount > 0 || failedPlaceCount == 0
    }

    static func shouldDebounceReplan(
        lastSignature: Int?, currentSignature: Int, lastAt: Date?, now: Date,
        interval: TimeInterval = 5
    ) -> Bool {
        guard interval > 0, lastSignature == currentSignature, let lastAt else { return false }
        return now.timeIntervalSince(lastAt) < interval
    }

    /// A successful HTTP response is not useful when decoding produced no
    /// hours. Treat it as a failed place so the previous forecast remains
    /// available instead of being replaced by an empty result.
    nonisolated static func isUsableForecast(_ forecast: [ForecastHour]) -> Bool {
        !forecast.isEmpty
    }

    @discardableResult
    func refreshAll(backgroundOnly: Bool = false) async -> Bool {
        guard !Task.isCancelled else { return false }
        let work = refreshQueue.enqueue { await self.performRefresh(backgroundOnly: backgroundOnly) }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func performRefresh(backgroundOnly: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        calibration.prune(now: Date())
        calibration.save()
        isRefreshing = true
        defer { isRefreshing = false }

        let requestedPlaces = backgroundOnly
            ? Self.placesNeededForBackgroundRefresh(places, selectedID: selectedID)
            : places
        let locationGroups = Self.groupedByForecastLocation(requestedPlaces)
        var failedNames: [String] = []
        var successfulPlaceCount = 0
        let locations = Self.forecastLocations(in: requestedPlaces)
        for batchStart in stride(from: 0, to: locations.count, by: Self.forecastRequestConcurrencyLimit) {
            guard !Task.isCancelled else { return false }
            let batchEnd = min(batchStart + Self.forecastRequestConcurrencyLimit, locations.count)
            let batch = locations[batchStart..<batchEnd]
            await withTaskGroup(of: (ForecastLocation, Result<[ForecastHour], Error>).self) { group in
                for location in batch {
                    group.addTask {
                        do {
                            let forecast = try await YrService.fetch(lat: location.latitude, lon: location.longitude)
                            guard Self.isUsableForecast(forecast) else {
                                throw ForecastRefreshError.emptyForecast
                            }
                            return (location, .success(forecast))
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
                    // Handle each coordinate independently: a failed location
                    // must not prevent successful siblings from being stored.
                    switch result {
                    case .success(let forecast):
                        successfulPlaceCount += matchingPlaces.count
                        for place in matchingPlaces {
                            forecasts[place.id] = forecast
                            forecastUpdatedAt[place.id] = Date()
                            calibration.record(place: place, hours: forecast, fetchedAt: Date())
                            forecastErrors.removeValue(forKey: place.id)
                        }
                    case .failure(let error):
                        // Do not touch forecasts or timestamps on failure;
                        // surface a place-specific error while keeping good data.
                        for place in matchingPlaces {
                            failedNames.append(place.displayName)
                            forecastErrors[place.id] = forecastErrorMessage(for: place, error: error, style: alertLanguageStyle)
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
        let now = Date()
        let signature = replanSignature()
        guard !Self.shouldDebounceReplan(
            lastSignature: lastReplanSignature, currentSignature: signature,
            lastAt: lastReplanAt, now: now
        ) else { return }
        lastReplanSignature = signature
        lastReplanAt = now
        // The computed `forecasts` property applies local offsets and creates
        // a map. Reuse one snapshot throughout this replan instead of making
        // three identical copies for planning, missing-data checks and Live
        // Activity synchronization.
        let currentForecasts = forecasts
        let alerts = Planner.planAll(places: places, forecasts: currentForecasts, nearbyPlaceIDs: nearbyPlaceIDs)
        let scheduleResult = await NotificationScheduler.reschedule(
            alerts, languageStyle: alertLanguageStyle, places: places,
            missingForecastPlaceIDs: Set(places.filter { (currentForecasts[$0.id] ?? []).isEmpty }.map(\.id)),
            nearbyPlaceIDs: nearbyPlaceIDs
        )
        await LiveWeatherActivityManager.sync(
            places: places,
            forecasts: currentForecasts,
            nearbyPlaceIDs: nearbyPlaceIDs,
            forecastUpdatedAt: forecastUpdatedAt
        )
        updateWidget()
        let text = Self.notificationPlanLogText(scheduleResult)
        log.insert(LogEntry(time: now, text: text), at: 0)
        log = Self.retainedLog(log, now: now)
    }

    private func replanSignature() -> Int {
        var hasher = Hasher()
        let currentForecasts = forecasts
        places.sorted { $0.id.uuidString < $1.id.uuidString }.forEach { hasher.combine($0) }
        currentForecasts.keys.sorted { $0.uuidString < $1.uuidString }.forEach { id in
            hasher.combine(id)
            currentForecasts[id, default: []].sorted { $0.time < $1.time }.forEach { hasher.combine($0) }
        }
        nearbyPlaceIDs.sorted { $0.uuidString < $1.uuidString }.forEach { hasher.combine($0) }
        hasher.combine(Self.configurationSignature(languageStyle: alertLanguageStyle, separator: WeatherTextSeparator.current))
        return hasher.finalize()
    }

    static func configurationSignature(languageStyle: AlertLanguageStyle, separator: WeatherTextSeparator) -> Int {
        var hasher = Hasher()
        hasher.combine(languageStyle.rawValue)
        hasher.combine(separator.rawValue)
        return hasher.finalize()
    }

    static func retainedLog(_ entries: [LogEntry], now: Date, maxAge: TimeInterval = 72 * 3_600, maxCount: Int = 50) -> [LogEntry] {
        guard maxCount > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-maxAge)
        return Array(entries.filter { $0.time >= cutoff }.prefix(maxCount))
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

    func select(_ place: Place, fromCurrentLocation: Bool = false) {
        selectedID = place.id
        selectionIsCurrentLocation = fromCurrentLocation
        updateWidget()
    }

    func add(_ place: Place) async {
        places.append(place)
        selectedID = place.id
        selectionIsCurrentLocation = false
        proximityMonitor.configure(for: places)
        do {
            let forecast = try await YrService.fetch(lat: place.lat, lon: place.lon)
            guard !Task.isCancelled,
                  !Self.currentRecipients(for: [place], in: places).isEmpty else { return }
            forecasts[place.id] = forecast
            forecastUpdatedAt[place.id] = Date()
            calibration.record(place: place, hours: forecast, fetchedAt: Date())
            forecastErrors.removeValue(forKey: place.id)
            lastUpdate = Date()
        } catch {
            guard !Task.isCancelled,
                  let currentPlace = Self.currentRecipients(for: [place], in: places).first else { return }
            forecastErrors[place.id] = forecastErrorMessage(for: currentPlace, error: error, style: alertLanguageStyle)
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

    static func widgetSnapshot(
        place: Place?, forecast: [ForecastHour], updatedAt: Date?, cached: WidgetWeatherSnapshot?, now: Date = Date()
    ) -> WidgetWeatherSnapshot? {
        guard let place else { return nil }
        let cutoff = now.addingTimeInterval(-6 * 3_600)
        if !forecast.isEmpty, let updatedAt, updatedAt >= cutoff {
            return WidgetWeatherSnapshot(
                place: place,
                forecast: forecast.map { $0.locallyAdjusted(by: place.localTemperatureOffset) },
                updatedAt: updatedAt
            )
        }
        // Snapshot identity requires both the same UUID and Yr coordinate;
        // a renamed or moved place must never inherit another place's data.
        guard let cached, cached.place.id == place.id,
              ForecastLocation(place: cached.place) == ForecastLocation(place: place),
              !cached.forecast.isEmpty, cached.updatedAt >= cutoff else { return nil }
        return WidgetWeatherSnapshot(place: place, forecast: cached.forecast.map { $0.locallyAdjusted(by: place.localTemperatureOffset) }, updatedAt: cached.updatedAt)
    }

    func refreshDisplaySettings() {
        objectWillChange.send()
        updateWidget()
        Task { await replan() }
    }

    private func updateWidget() {
        // `forecasts` is populated per location only after a complete Yr
        // response, so this snapshot cannot contain an in-flight partial list.
        let sharedPrimary = resolvedSharedPlaceIDs.first.flatMap { id in places.first { $0.id == id } }
        let widgetPlace = sharedPrimary ?? selected
        let snapshot = Self.widgetSnapshot(
            place: widgetPlace, forecast: widgetPlace.flatMap { forecasts[$0.id] } ?? [],
            updatedAt: widgetPlace.flatMap { forecastUpdatedAt[$0.id] }, cached: SharedWidgetData.load()
        )
        guard let snapshot else {
            // Removing the selected place (or moving it) must clear both the
            // forecast snapshot and the shared-place list in one transaction.
            // This is the only intentional reload without a weather snapshot.
            SharedWidgetData.clear()
            WatchSyncManager.shared.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        // Widget persistence is best-effort; the caller continues with
        // Watch sync and notification planning regardless of storage outcome.
        SharedWidgetData.save(
            place: snapshot.place, forecast: snapshot.forecast, updatedAt: snapshot.updatedAt,
            languageStyle: alertLanguageStyle, textSeparator: WeatherTextSeparator.current
        )
        let sharedPlaces = resolvedSharedPlaceIDs.compactMap { id in places.first { $0.id == id } }
        SharedWidgetData.saveSharedPlaces(sharedPlaces)
        WatchSyncManager.shared.send(place: snapshot.place, forecast: snapshot.forecast, updatedAt: snapshot.updatedAt, languageStyle: alertLanguageStyle, textSeparator: WeatherTextSeparator.current)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func forecastErrorMessage(for place: Place, error: Error, style: AlertLanguageStyle) -> String {
        let hasOldForecast = !(forecasts[place.id] ?? []).isEmpty
        let prefix = hasOldForecast
            ? (style == .english ? "Showing the last forecast for \(place.displayName). " : "Viser sist hentede prognose for \(place.displayName). ")
            : ""
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return prefix + (style == .english ? "No internet connection. Pull to try again." : "Ingen nettforbindelse. Dra ned for å prøve igjen.")
            case .timedOut:
                return prefix + (style == .english ? "MET took too long. Pull to try again." : "MET brukte for lang tid. Dra ned for å prøve igjen.")
            case .badServerResponse:
                return prefix + (style == .english ? "MET could not provide the forecast right now." : "MET kunne ikke levere prognosen akkurat nå.")
            default: break
            }
        }
        if error is DecodingError {
            return prefix + (style == .english ? "The forecast from MET could not be read." : "Prognosen fra MET kunne ikke leses.")
        }
        return prefix + (style == .english ? "Could not update the forecast. Pull to try again." : "Kunne ikke oppdatere prognosen. Dra ned for å prøve igjen.")
    }
}

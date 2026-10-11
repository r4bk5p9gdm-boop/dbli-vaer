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
    private var observationsArchiveCanBeReplaced = true
    static let retention: TimeInterval = 48 * 3600
    private static let legacyKey = "varsel.calibrationHistory.v1"
    private static let forecastsKey = "varsel.calibrationForecasts.v1"
    private static var observationsFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("D bli Vær", isDirectory: true)
            .appendingPathComponent("calibration-observations-v1.json")
    }

    private enum CodingKeys: String, CodingKey {
        case forecasts, observations
    }

    init(forecasts: [CalibrationForecast] = [], observations: [LocalWeatherObservation] = []) {
        self.forecasts = forecasts
        self.observations = observations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        forecasts = try values.decode([CalibrationForecast].self, forKey: .forecasts)
        observations = try values.decode([LocalWeatherObservation].self, forKey: .observations)
        observationsArchiveCanBeReplaced = true
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(forecasts, forKey: .forecasts)
        try values.encode(observations, forKey: .observations)
    }

    func observations(for placeID: UUID, limit: Int) -> [LocalWeatherObservation] {
        guard limit > 0 else { return [] }
        var page: [LocalWeatherObservation] = []
        page.reserveCapacity(min(limit, observations.count))
        for observation in observations where observation.place.id == placeID {
            page.append(observation)
            if page.count == limit { break }
        }
        return page
    }

    mutating func prune(now: Date) {
        forecasts.removeAll { $0.fetchedAt < now.addingTimeInterval(-Self.retention) || $0.fetchedAt > now }
    }

    mutating func record(place: Place, hours: [ForecastHour], fetchedAt: Date) {
        prune(now: fetchedAt)
        guard !hours.isEmpty else { saveForecasts(); return }
        // Retain forecast versions: a later update must not erase what was
        // available when an earlier observation was made.
        forecasts.append(CalibrationForecast(place: place, fetchedAt: fetchedAt,
            hours: hours.filter { $0.time <= fetchedAt.addingTimeInterval(Self.retention) }.map { $0.locallyAdjusted(by: 0) }))
        saveForecasts()
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

    @discardableResult
    func saveForecasts(defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(forecasts) else { return false }
        defaults.set(data, forKey: Self.forecastsKey)
        return true
    }

    @discardableResult
    func saveObservations(to url: URL? = nil) -> Bool {
        guard observationsArchiveCanBeReplaced,
              let url = url ?? Self.observationsFileURL,
              let data = try? JSONEncoder().encode(observations) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func load(
        now: Date = Date(), defaults: UserDefaults = .standard,
        observationsURL: URL? = nil
    ) -> Self {
        let legacy = defaults.data(forKey: legacyKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        let forecasts = defaults.data(forKey: forecastsKey)
            .flatMap { try? JSONDecoder().decode([CalibrationForecast].self, from: $0) }
            ?? legacy?.forecasts ?? []
        let archiveURL = observationsURL ?? Self.observationsFileURL
        var observationsArchiveCanBeReplaced = true
        var archivedObservations: [LocalWeatherObservation]?
        if let archiveURL, FileManager.default.fileExists(atPath: archiveURL.path) {
            if let data = try? Data(contentsOf: archiveURL),
               let decoded = try? JSONDecoder().decode([LocalWeatherObservation].self, from: data) {
                archivedObservations = decoded
            } else {
                observationsArchiveCanBeReplaced = quarantineUnreadableObservationsArchive(at: archiveURL)
            }
        }
        let observations = archivedObservations ?? legacy?.observations ?? []
        var history = Self(forecasts: forecasts, observations: observations)
        history.observationsArchiveCanBeReplaced = observationsArchiveCanBeReplaced
        let forecastCountBeforePruning = history.forecasts.count
        history.prune(now: now)

        if legacy != nil {
            // Keep the old combined archive until both new stores are safely
            // written, so a file-system failure cannot discard observations.
            if history.saveObservations(to: archiveURL), history.saveForecasts(defaults: defaults) {
                defaults.removeObject(forKey: legacyKey)
            }
        } else if history.forecasts.count != forecastCountBeforePruning {
            history.saveForecasts(defaults: defaults)
        }
        return history
    }

    private static func quarantineUnreadableObservationsArchive(at url: URL) -> Bool {
        let manager = FileManager.default
        let fileName = url.deletingPathExtension().lastPathComponent
        let recoveryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(fileName).unreadable-\(UUID().uuidString).json")
        do {
            try manager.moveItem(at: url, to: recoveryURL)
            return true
        } catch {
            // If another recovery attempt already moved it, the original path
            // is safe to recreate. Otherwise keep future writes away from the
            // only remaining copy of the unreadable archive.
            return !manager.fileExists(atPath: url.path)
        }
    }
}

struct PersistedStoreState: Codable {
    var places: [Place]
    var selectedID: UUID?
    var log: [LogEntry]
    /// Forecast cache is persisted with configuration so launch can render
    /// the last known bands before the network responds.
    var forecasts: [UUID: [ForecastHour]] = [:]
    var forecastUpdatedAt: [UUID: Date] = [:]
    var lastUpdate: Date?

    private enum CodingKeys: String, CodingKey { case places, selectedID, log, forecasts, forecastUpdatedAt, lastUpdate }

    init(places: [Place], selectedID: UUID?, log: [LogEntry], forecasts: [UUID: [ForecastHour]] = [:], forecastUpdatedAt: [UUID: Date] = [:], lastUpdate: Date? = nil) {
        self.places = places
        self.selectedID = selectedID
        self.log = log
        self.forecasts = forecasts
        self.forecastUpdatedAt = forecastUpdatedAt
        self.lastUpdate = lastUpdate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPlaces = (try? values.decode([LossyDecodable<Place>].self, forKey: .places))?.compactMap(\.value) ?? []
        var seenPlaceIDs = Set<UUID>()
        places = decodedPlaces.filter { seenPlaceIDs.insert($0.id).inserted }
        let decodedSelection = try? values.decode(UUID.self, forKey: .selectedID)
        if let decodedSelection {
            selectedID = places.contains(where: { $0.id == decodedSelection })
                ? decodedSelection
                : places.first?.id
        } else {
            selectedID = nil
        }
        log = (try? values.decode([LossyDecodable<LogEntry>].self, forKey: .log))?.compactMap(\.value) ?? []
        let lossyForecasts = (try? values.decode([UUID: LossyDecodable<[ForecastHour]>].self, forKey: .forecasts)) ?? [:]
        forecasts = lossyForecasts.compactMapValues(\.value)
        let lossyTimestamps = (try? values.decode([UUID: LossyDecodable<Date>].self, forKey: .forecastUpdatedAt)) ?? [:]
        forecastUpdatedAt = lossyTimestamps.compactMapValues(\.value)
        lastUpdate = try? values.decode(Date.self, forKey: .lastUpdate)
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
    typealias ForecastFetcher = @Sendable (_ latitude: Double, _ longitude: Double) async throws -> [ForecastHour]
    typealias NotificationRescheduler = @MainActor (
        [PlannedAlert], AlertLanguageStyle, [Place], Set<UUID>, Set<UUID>
    ) async -> NotificationScheduleResult
    static func shouldApplyCurrentLocation(selectionAtRequestStart: UUID?, currentSelection: UUID?) -> Bool {
        selectionAtRequestStart == currentSelection
    }

    static func shouldApplyCurrentLocationFix(
        selectionAtRequestStart: UUID?,
        currentSelection: UUID?,
        location: CLLocation,
        now: Date = Date()
    ) -> Bool {
        shouldApplyCurrentLocation(
            selectionAtRequestStart: selectionAtRequestStart,
            currentSelection: currentSelection
        ) && LocationFixPolicy.accepts(location, now: now)
    }

    static func nearestSavedPlace(
        in places: [Place], to location: CLLocation, maxDistance: CLLocationDistance = 15_000
    ) -> Place? {
        guard let nearest = places.min(by: {
            CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: location)
                < CLLocation(latitude: $1.lat, longitude: $1.lon).distance(from: location)
        }) else { return nil }
        return CLLocation(latitude: nearest.lat, longitude: nearest.lon).distance(from: location) <= maxDistance
            ? nearest
            : nil
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
            let resolvedFavorites = homeFavorites.resolved(availableIDs: Set(places.map(\.id)))
            if homeFavorites != resolvedFavorites {
                homeFavorites = resolvedFavorites
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
    /// Last page representing the phone's current position. Retained while
    /// swiping to favorites so the position page remains reachable.
    @Published private(set) var currentLocationPlaceID: UUID?
    /// Direction of travel from the last live position fix. It is intentionally
    /// optional: a stationary or low-quality fix must not make the UI pretend
    /// that it knows which way the phone is facing.
    @Published private(set) var currentLocationCourse: CLLocationDirection?
    @Published var homeFavorites: HomeFavorites = {
        guard let data = UserDefaults.standard.data(forKey: "varsel.homeFavorites"),
              let value = try? JSONDecoder().decode(HomeFavorites.self, from: data) else { return HomeFavorites() }
        return value
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(homeFavorites) {
                UserDefaults.standard.set(data, forKey: "varsel.homeFavorites")
            }
            updateWidget()
        }
    }
    var resolvedHomeFavorites: HomeFavorites {
        homeFavorites.resolved(availableIDs: Set(places.map(\.id)))
    }
    var homeSwipePlaceIDs: [UUID] {
        let favorites = resolvedHomeFavorites
        let ids = HomeSwipeSelection.orderedHomeIDs(
            positionID: currentLocationPlaceID,
            favorite1ID: favorites.right,
            favorite2ID: favorites.left
        )
        let available = Set(places.map(\.id))
        return ids.filter { available.contains($0) }
    }
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
    @Published private(set) var nearbyMonitoringFailedPlaceIDs: Set<UUID> = []
    @Published private(set) var nearbyMonitoringOverflowPlaceIDs: Set<UUID> = []
    @Published private(set) var nearbyAuthorizationUnavailable = false
    private var lastReplanSignature: Int?
    private var lastReplanAt: Date?

    private let key: String
    private let forecastFetcher: ForecastFetcher
    private let notificationRescheduler: NotificationRescheduler
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

    /// The production store uses Yr directly. Keeping the fetch behind this
    /// narrow seam lets refresh behaviour be tested with deterministic
    /// successful and failing locations without changing the live request.
    init(
        forecastFetcher: @escaping ForecastFetcher = { latitude, longitude in
            try await YrService.fetch(lat: latitude, lon: longitude)
        },
        persistenceKey: String = "varsel.state",
        notificationRescheduler: @escaping NotificationRescheduler = {
            alerts, languageStyle, places, missingForecastPlaceIDs, nearbyPlaceIDs in
            await NotificationScheduler.reschedule(
                alerts, languageStyle: languageStyle, places: places,
                missingForecastPlaceIDs: missingForecastPlaceIDs, nearbyPlaceIDs: nearbyPlaceIDs
            )
        }
    ) {
        self.forecastFetcher = forecastFetcher
        self.key = persistenceKey
        self.notificationRescheduler = notificationRescheduler
        alertLanguageStyle = AlertLanguageStyle.persisted(
            UserDefaults.standard.string(forKey: "varsel.alertLanguageStyle") ?? ""
        ) ?? .bokmal
        var restoredForecasts: [UUID: [ForecastHour]] = [:]
        var restoredForecastUpdatedAt: [UUID: Date] = [:]
        var restoredLastUpdate: Date?
        var needsPersistedStateRepair = false
        let restoredSavedPlaces: Bool
        if let d = UserDefaults.standard.data(forKey: key),
           let p = try? JSONDecoder().decode(PersistedStoreState.self, from: d),
           !p.places.isEmpty {
            // Restored selection is authoritative when GPS is unavailable;
            // location lookup is only attempted by the explicit startup flow.
            places = p.places; selectedID = p.selectedID; log = p.log
            restoredForecasts = p.forecasts
            restoredForecastUpdatedAt = p.forecastUpdatedAt
            restoredLastUpdate = p.lastUpdate
            restoredSavedPlaces = true
        } else {
            places = Self.launchPlaces; selectedID = places.first?.id; log = []
            UserDefaults.standard.set(launchPlacesVersion, forKey: launchPlacesVersionKey)
            restoredSavedPlaces = false
        }
        let knownPlaceIDs = Set(places.map(\.id))
        rawForecasts = restoredForecasts.filter { knownPlaceIDs.contains($0.key) }
        forecastUpdatedAt = restoredForecastUpdatedAt.filter {
            knownPlaceIDs.contains($0.key) && rawForecasts[$0.key]?.isEmpty == false
        }
        needsPersistedStateRepair = rawForecasts.count != restoredForecasts.count
            || forecastUpdatedAt.count != restoredForecastUpdatedAt.count
        lastUpdate = restoredLastUpdate

        if selectedID.map({ id in places.contains { $0.id == id } }) != true {
            selectedID = places.first?.id
            needsPersistedStateRepair = true
        }

        if UserDefaults.standard.integer(forKey: launchPlacesVersionKey) < launchPlacesVersion {
            needsPersistedStateRepair = true
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
            let orderedStandards = standardNames.compactMap { standardName in
                places.first { $0.name.compare(standardName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            }
            let otherPlaces = places.filter { place in
                !standardNames.contains {
                    place.name.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }
            }
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

        // Place migrations can merge names that differ only by case or
        // diacritics. Reconcile every place-keyed value after that merge so a
        // discarded duplicate cannot remain selected or retain an orphaned
        // forecast cache.
        let migratedPlaceIDs = Set(places.map(\.id))
        let migratedForecasts = rawForecasts.filter { migratedPlaceIDs.contains($0.key) }
        let migratedForecastUpdatedAt = forecastUpdatedAt.filter {
            migratedPlaceIDs.contains($0.key) && migratedForecasts[$0.key]?.isEmpty == false
        }
        if migratedForecasts.count != rawForecasts.count
            || migratedForecastUpdatedAt.count != forecastUpdatedAt.count {
            rawForecasts = migratedForecasts
            forecastUpdatedAt = migratedForecastUpdatedAt
            needsPersistedStateRepair = true
        }
        if selectedID.map({ id in migratedPlaceIDs.contains(id) }) != true {
            selectedID = places.first?.id
            needsPersistedStateRepair = true
        }

        let resolvedHomeFavorites = homeFavorites.resolved(availableIDs: Set(places.map(\.id)))
        if homeFavorites != resolvedHomeFavorites {
            homeFavorites = resolvedHomeFavorites
            if let data = try? JSONEncoder().encode(resolvedHomeFavorites) {
                UserDefaults.standard.set(data, forKey: "varsel.homeFavorites")
            }
        }

        let monitor = ProximityMonitor()
        proximityMonitor = monitor
        nearbyPlaceIDs = monitor.nearbyPlaceIDs
        nearbyAuthorizationUnavailable = monitor.authorizationUnavailable
        monitor.onChange = { [weak self] nearbyIDs in
            guard let self else { return }
            self.nearbyPlaceIDs = nearbyIDs
            Task { await self.replan() }
        }
        monitor.onMonitoringFailureChange = { [weak self] failedIDs in
            self?.nearbyMonitoringFailedPlaceIDs = failedIDs
        }
        monitor.onMonitoringOverflowChange = { [weak self] overflowIDs in
            self?.nearbyMonitoringOverflowPlaceIDs = overflowIDs
        }
        monitor.onAuthorizationAvailabilityChange = { [weak self] unavailable in
            guard let self else { return }
            self.nearbyAuthorizationUnavailable = unavailable
            if !unavailable {
                self.proximityMonitor.configure(for: self.places)
            }
        }
        monitor.configure(for: places)
        if !restoredSavedPlaces || needsPersistedStateRepair { save() }
    }

    var selected: Place? { places.first { $0.id == selectedID } ?? places.first }
    var selectedForecast: [ForecastHour] { selected.flatMap { forecasts[$0.id] } ?? [] }
    var error: String? { selected.flatMap { forecastErrors[$0.id] } }
    func forecastUpdatedAt(for placeID: UUID) -> Date? { forecastUpdatedAt[placeID] }

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
        currentLocationCourse = nil
        // Location is an optional enhancement; manual selection and its
        // existing notifications remain fully usable when access is denied.
        let locationManager = LocationManager()
        guard let location = try? await locationManager.current() else { return }
        guard Self.shouldApplyCurrentLocationFix(
            selectionAtRequestStart: selectionAtRequestStart,
            currentSelection: selectedID,
            location: location
        ) else { return }
        if let nearest = Self.nearestSavedPlace(in: places, to: location) {
            updateCurrentLocationCourse(from: location)
            select(nearest, fromCurrentLocation: true)
            return
        }
        let name = await LocationManager.name(for: location)
        guard Self.shouldApplyCurrentLocationFix(
            selectionAtRequestStart: selectionAtRequestStart,
            currentSelection: selectedID,
            location: location
        ) else { return }
        updateCurrentLocationCourse(from: location)
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
        guard place.hasValidCoordinates else { return }
        if let i = places.firstIndex(where: { $0.id == place.id }) { places[i] = place } else { places.append(place) }
        proximityMonitor.configure(for: places)
    }

    func requestNearbyAuthorization() {
        proximityMonitor.requestBackgroundAuthorization()
        proximityMonitor.configure(for: places)
    }

    func retryNearbyMonitoring() {
        proximityMonitor.configure(for: places)
    }

    @discardableResult
    func recordObservation(place: Place, at date: Date, temperature: Double?, frost: Bool?, surface: String) -> Bool {
        calibration.prune(now: Date())
        let observation = calibration.observation(place: place, at: date, temperature: temperature, frost: frost, surface: surface)
        calibration.observations.insert(observation, at: 0)
        guard calibration.saveObservations() else {
            calibration.observations.removeAll { $0.id == observation.id }
            return false
        }
        return true
    }

    @discardableResult
    func removeObservation(id: UUID) -> Bool {
        let previous = calibration.observations
        calibration.observations.removeAll { $0.id == id }
        guard calibration.saveObservations() else {
            calibration.observations = previous
            return false
        }
        return true
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
        Dictionary(grouping: places.filter(\.hasValidCoordinates), by: ForecastLocation.init(place:))
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

    static let forecastFutureTimestampTolerance: TimeInterval = 5 * 60

    static func isForecastStale(_ updatedAt: Date?, now: Date = Date(), threshold: TimeInterval = WeatherGlance.staleAfter) -> Bool {
        guard let updatedAt else { return true }
        let age = now.timeIntervalSince(updatedAt)
        return age > threshold || age < -forecastFutureTimestampTolerance
    }

    /// Keep cached values available to the UI/widgets as an offline fallback,
    /// but never use a stale cache to create a new push notification plan.
    static func forecastsForPlanning(
        _ forecasts: [UUID: [ForecastHour]],
        updatedAt: [UUID: Date],
        now: Date = Date()
    ) -> [UUID: [ForecastHour]] {
        forecasts.filter { id, _ in !isForecastStale(updatedAt[id], now: now) }
    }

    static func shouldReplaceForecast(existingAt: Date?, incomingAt: Date, now: Date = Date()) -> Bool {
        guard let existingAt else { return true }
        if existingAt.timeIntervalSince(now) > forecastFutureTimestampTolerance { return true }
        return incomingAt >= existingAt
    }

    static func shouldDebounceReplan(
        lastSignature: Int?, currentSignature: Int, lastAt: Date?, now: Date,
        interval: TimeInterval = 5
    ) -> Bool {
        guard interval > 0, lastSignature == currentSignature, let lastAt else { return false }
        return now.timeIntervalSince(lastAt) < interval
    }

    /// MET's location forecast can be shorter than its usual horizon, but a
    /// response with fewer than three distinct future hours is not enough for
    /// the app's near-term bands and alert planning. Three hours is deliberately
    /// modest: it accepts a single six-hour MET block (expanded to hourly
    /// values) while rejecting truncated one- or two-hour responses.
    nonisolated static let minimumUsableForecastHours = 3

    nonisolated static func isUsableForecast(_ forecast: [ForecastHour], now: Date = Date()) -> Bool {
        let usableTimes = Set(forecast.lazy.map(\.time).filter { $0 >= now }).sorted()
        guard usableTimes.count >= minimumUsableForecastHours,
              let first = usableTimes.first,
              let latest = usableTimes.last else { return false }
        let firstHours = usableTimes.prefix(minimumUsableForecastHours)
        guard zip(firstHours, firstHours.dropFirst()).allSatisfy({ pair in
            abs(pair.1.timeIntervalSince(pair.0) - 3_600) <= 60
        }) else { return false }
        return first.timeIntervalSince(now) <= 6 * 3_600
            && latest.timeIntervalSince(now) >= TimeInterval(minimumUsableForecastHours - 1) * 3_600
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
        calibration.saveForecasts()
        isRefreshing = true
        defer { isRefreshing = false }

        let requestedPlaces = backgroundOnly
            ? Self.placesNeededForBackgroundRefresh(places, selectedID: selectedID)
            : places
        let locationGroups = Self.groupedByForecastLocation(requestedPlaces)
        var failedNames: [String] = []
        var successfulPlaceCount = 0
        let locations = Self.forecastLocations(in: requestedPlaces)
        let fetchForecast = forecastFetcher
        for batchStart in stride(from: 0, to: locations.count, by: Self.forecastRequestConcurrencyLimit) {
            guard !Task.isCancelled else { return false }
            let batchEnd = min(batchStart + Self.forecastRequestConcurrencyLimit, locations.count)
            let batch = locations[batchStart..<batchEnd]
            await withTaskGroup(of: (ForecastLocation, Result<[ForecastHour], Error>).self) { group in
                for location in batch {
                    group.addTask {
                        do {
                            let forecast = try await fetchForecast(location.latitude, location.longitude)
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
                        let fetchedAt = Date()
                        for place in matchingPlaces {
                            guard Self.shouldReplaceForecast(existingAt: forecastUpdatedAt[place.id], incomingAt: fetchedAt) else { continue }
                            forecasts[place.id] = forecast
                            forecastUpdatedAt[place.id] = fetchedAt
                            calibration.record(place: place, hours: forecast, fetchedAt: fetchedAt)
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
        save()
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
        let planningForecasts = Self.forecastsForPlanning(
            currentForecasts, updatedAt: forecastUpdatedAt, now: now
        )
        let alerts = Planner.planAll(places: places, forecasts: planningForecasts, nearbyPlaceIDs: nearbyPlaceIDs)
        let scheduleResult = await notificationRescheduler(
            alerts, alertLanguageStyle, places,
            Set(places.filter { (planningForecasts[$0.id] ?? []).isEmpty }.map(\.id)),
            nearbyPlaceIDs
        )
        guard !Task.isCancelled else {
            if lastReplanSignature == signature, lastReplanAt == now {
                lastReplanSignature = nil
                lastReplanAt = nil
            }
            return
        }
        if scheduleResult.failedCount > 0,
           lastReplanSignature == signature, lastReplanAt == now {
            // Keep the in-flight guard during the await, but let an unchanged
            // plan retry promptly when any notification replacement failed.
            lastReplanSignature = nil
            lastReplanAt = nil
        }
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
        // Keep the last GPS course while browsing favorites. Returning to the
        // position page should restore its arrow without changing the place.
        if fromCurrentLocation { currentLocationPlaceID = place.id }
        updateWidget()
    }

    func updateCurrentLocationCourse(from location: CLLocation) {
        // A newer location fix may rotate the position badge, but it must not
        // change the selected place or the forecast shown in the weather bands.
        currentLocationCourse = Self.usableCourse(from: location)
    }

    static func usableCourse(from location: CLLocation) -> CLLocationDirection? {
        guard location.course >= 0, location.speed >= 0.5 else { return nil }
        return location.course
    }

    func add(_ place: Place) async {
        guard place.hasValidCoordinates else { return }
        places.append(place)
        selectedID = place.id
        selectionIsCurrentLocation = false
        proximityMonitor.configure(for: places)
        // Persist the place before the first network request so setup and
        // manual place selection remain durable when the device is offline.
        save()
        do {
            let forecast = try await forecastFetcher(place.lat, place.lon)
            guard !Task.isCancelled,
                  Self.isUsableForecast(forecast),
                  !Self.currentRecipients(for: [place], in: places).isEmpty else { return }
            let fetchedAt = Date()
            guard Self.shouldReplaceForecast(existingAt: forecastUpdatedAt[place.id], incomingAt: fetchedAt) else { return }
            forecasts[place.id] = forecast
            forecastUpdatedAt[place.id] = fetchedAt
            calibration.record(place: place, hours: forecast, fetchedAt: fetchedAt)
            forecastErrors.removeValue(forKey: place.id)
            lastUpdate = Date()
            // Persist before replanning so a successful manual fetch survives
            // suspension or termination during notification setup.
            save()
        } catch {
            guard !Task.isCancelled,
                  let currentPlace = Self.currentRecipients(for: [place], in: places).first else { return }
            forecastErrors[place.id] = forecastErrorMessage(for: currentPlace, error: error, style: alertLanguageStyle)
            save()
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
        if places.isEmpty { places = Self.launchPlaces }
        if selectedID.map({ selectedID in places.contains { $0.id == selectedID } }) != true {
            selectedID = places.first?.id
        }
        proximityMonitor.configure(for: places)
        Task { await replan() }
    }

    func removePlaces(ids: Set<UUID>) {
        let offsets = IndexSet(places.indices.filter { ids.contains(places[$0].id) })
        removePlaces(at: offsets)
    }

    @discardableResult
    func applyConfigurationImport(_ plan: ConfigurationImportPlan) -> Bool {
        guard plan.canApply else { return false }
        places = plan.places
        selectedID = plan.selectedPlaceID
        selectionIsCurrentLocation = false
        if let currentLocationPlaceID, !places.contains(where: { $0.id == currentLocationPlaceID }) {
            self.currentLocationPlaceID = nil
            currentLocationCourse = nil
        }
        if let settings = plan.appSettings {
            homeFavorites = settings.homeFavorites
            settings.persist()
        }
        // The language-style observer publishes Widget/Watch data. Persist the
        // imported shared separator first so that publication sees one coherent
        // set of display preferences rather than the previous separator.
        alertLanguageStyle = plan.alertLanguageStyle
        proximityMonitor.configure(for: places)
        save()
        Task { await replan() }
        return true
    }

    private func save() {
        let cachedForecasts = rawForecasts.filter { !$0.value.isEmpty }
        let cachedTimestamps = forecastUpdatedAt.filter { cachedForecasts[$0.key] != nil }
        if let d = try? JSONEncoder().encode(PersistedStoreState(
            places: places, selectedID: selectedID, log: log,
            forecasts: cachedForecasts, forecastUpdatedAt: cachedTimestamps,
            lastUpdate: lastUpdate
        )) {
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
        // Snapshots contain the adjustment that was active when they were
        // written.  If the user changes the local offset while offline, move
        // the cached value by just that delta — never the whole new offset.
        // This keeps a widget in sync with its place setting without mutating
        // the raw Yr cache used by any other saved place.
        let offsetDelta = place.localTemperatureOffset - cached.place.localTemperatureOffset
        return WidgetWeatherSnapshot(
            place: place,
            forecast: cached.forecast.map { $0.locallyAdjusted(by: offsetDelta) },
            updatedAt: cached.updatedAt,
            languageStyle: cached.languageStyle,
            textSeparator: cached.textSeparator
        )
    }

    func refreshDisplaySettings() {
        objectWillChange.send()
        updateWidget()
        Task { await replan() }
    }

    private func updateWidget() {
        // `forecasts` is populated per location only after a complete Yr
        // response, so this snapshot cannot contain an in-flight partial list.
        let watchSource = WatchPlaceSource(rawValue: UserDefaults.standard.string(forKey: WatchPlaceSettings.sourceKey) ?? "position") ?? .position
        let watchPlaceID = UserDefaults.standard.string(forKey: WatchPlaceSettings.fixedPlaceIDKey).flatMap(UUID.init(uuidString:))
        let watchPlaceIDToUse = WatchPlaceSettings.resolvedPlaceID(
            source: watchSource,
            fixedPlaceID: watchPlaceID,
            selectedID: selected?.id,
            currentLocationID: currentLocationPlaceID,
            availableIDs: Set(places.map(\.id))
        )
        // Watch and CarPlay deliberately share one source. This prevents a
        // glance in the car from showing a different place than the Watch.
        let companionPlace = watchPlaceIDToUse.flatMap { id in places.first { $0.id == id } }
        let snapshot = Self.widgetSnapshot(
            place: companionPlace, forecast: companionPlace.flatMap { forecasts[$0.id] } ?? [],
            updatedAt: companionPlace.flatMap { forecastUpdatedAt[$0.id] }, cached: SharedWidgetData.load()
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
        let snapshotChanged = SharedWidgetData.save(
            place: snapshot.place, forecast: snapshot.forecast, updatedAt: snapshot.updatedAt,
            languageStyle: alertLanguageStyle, textSeparator: WeatherTextSeparator.current
        )
        let sharedPlacesChanged = SharedWidgetData.saveSharedPlaces([snapshot.place])
        WatchSyncManager.shared.send(
            place: snapshot.place, forecast: snapshot.forecast, updatedAt: snapshot.updatedAt,
            languageStyle: alertLanguageStyle, textSeparator: WeatherTextSeparator.current
        )
        if snapshotChanged || sharedPlacesChanged {
            WidgetCenter.shared.reloadAllTimelines()
        }
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

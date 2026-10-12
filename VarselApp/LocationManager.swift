import CoreLocation

enum LocationFixPolicy {
    static let maximumAge: TimeInterval = 120
    static let maximumFutureOffset: TimeInterval = 60
    static let maximumHorizontalAccuracy: CLLocationAccuracy = 100

    static func accepts(_ location: CLLocation, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        let coordinate = location.coordinate
        return age <= maximumAge
            && age >= -maximumFutureOffset
            && location.horizontalAccuracy.isFinite
            && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= maximumHorizontalAccuracy
            && coordinate.latitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && coordinate.longitude.isFinite
            && (-180...180).contains(coordinate.longitude)
    }
}

enum LocationAuthorizationDecision: Equatable {
    case requestWhenInUseAuthorization
    case requestLocation
    case fail(CLError.Code)

    static func forRawStatus(_ rawStatus: Int32) -> Self {
        switch rawStatus {
        case CLAuthorizationStatus.notDetermined.rawValue:
            .requestWhenInUseAuthorization
        case CLAuthorizationStatus.authorizedAlways.rawValue,
             CLAuthorizationStatus.authorizedWhenInUse.rawValue:
            .requestLocation
        default:
            // Denied, restricted, and future unknown statuses are terminal.
            .fail(.denied)
        }
    }
}

@MainActor
protocol OneShotLocationClient: AnyObject {
    var authorizationStatusRawValue: Int32 { get }
    var onAuthorizationChange: ((Int32) -> Void)? { get set }
    var onLocations: (([CLLocation]) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func requestLocation()
    func invalidate()
}

@MainActor
private final class CoreLocationOneShotClient: NSObject, OneShotLocationClient, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorizationChange: ((Int32) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?

    var authorizationStatusRawValue: Int32 { manager.authorizationStatus.rawValue }

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestLocation() { manager.requestLocation() }

    func invalidate() {
        manager.delegate = nil
        onAuthorizationChange = nil
        onLocations = nil
        onFailure = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onAuthorizationChange?(manager.authorizationStatus.rawValue)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.onLocations?(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.onFailure?(error) }
    }
}

@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let reverseGeocodingTimeout: TimeInterval = 8
    private let clientFactory: () -> any OneShotLocationClient
    private var client: (any OneShotLocationClient)?
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var requestID: UUID?
    private var timeout: Task<Void, Never>?

    enum RequestError: LocalizedError {
        case busy, timedOut
        var errorDescription: String? {
            switch self {
            case .busy: "Henter allerede posisjon. Prøv igjen om litt."
            case .timedOut: "Posisjonen lot vente på seg. Prøv igjen."
            }
        }
    }

    override init() {
        clientFactory = { CoreLocationOneShotClient() }
        super.init()
    }

    init(clientFactory: @escaping () -> any OneShotLocationClient) {
        self.clientFactory = clientFactory
        super.init()
    }

    func current() async throws -> CLLocation {
        try Task.checkCancellation()
        guard continuation == nil else { throw RequestError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                continuation = c
                requestID = id
                // A fresh manager prevents late callbacks from a previous request
                // from completing the next request.
                let source = clientFactory()
                client = source
                source.onAuthorizationChange = { [weak self, weak source] status in
                    guard let self, let source, self.client === source, self.requestID == id else { return }
                    self.requestIfAuthorized(source, statusRawValue: status)
                }
                source.onLocations = { [weak self, weak source] locations in
                    guard let self, let source, self.client === source, self.requestID == id,
                          let location = locations.last,
                          LocationFixPolicy.accepts(location) else { return }
                    self.finish(.success(location))
                }
                source.onFailure = { [weak self, weak source] error in
                    guard let self, let source, self.client === source, self.requestID == id else { return }
                    self.finish(.failure(error))
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                    catch { return }
                    guard self?.requestID == id else { return }
                    self?.finish(.failure(RequestError.timedOut))
                }
                requestIfAuthorized(source, statusRawValue: source.authorizationStatusRawValue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.requestID == id else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let pending = continuation
        continuation = nil
        requestID = nil
        timeout?.cancel()
        timeout = nil
        client?.invalidate()
        client = nil
        pending?.resume(with: result)
    }

    private func requestIfAuthorized(_ source: any OneShotLocationClient, statusRawValue: Int32) {
        switch LocationAuthorizationDecision.forRawStatus(statusRawValue) {
        case .requestWhenInUseAuthorization:
            source.requestWhenInUseAuthorization()
        case .requestLocation:
            source.requestLocation()
        case let .fail(code):
            finish(.failure(CLError(code)))
        }
    }

    static func name(
        for loc: CLLocation,
        timeout: TimeInterval = reverseGeocodingTimeout,
        clientFactory: (@MainActor () -> any ReverseGeocoderClient)? = nil,
        languageStyle: AlertLanguageStyle = .bokmal
    ) async -> String {
        let fallbackName = LanguageCatalog.value(
            "location.current", language: languageStyle.catalogCode,
            fallback: languageStyle == .english ? "My location" : languageStyle == .inntrondersk ? "Mi posisjon" : "Min posisjon"
        )
        guard !Task.isCancelled else { return fallbackName }
        let client = (clientFactory ?? { CoreLocationReverseGeocoderClient() })()
        let request = ReverseGeocodeRequest(client: client, timeout: timeout, fallbackName: fallbackName)
        return await request.name(for: loc)
    }
}

@MainActor
protocol ReverseGeocoderClient: AnyObject {
    func reverseGeocode(
        _ location: CLLocation,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    )
    func cancel()
}

@MainActor
private final class CoreLocationReverseGeocoderClient: ReverseGeocoderClient {
    private let geocoder = CLGeocoder()

    func reverseGeocode(
        _ location: CLLocation,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        geocoder.reverseGeocodeLocation(location) { placemarks, _ in
            let name = placemarks?.first?.locality ?? placemarks?.first?.name
            Task { @MainActor in completion(name) }
        }
    }

    func cancel() { geocoder.cancelGeocode() }
}

@MainActor
private final class ReverseGeocodeRequest {
    private let client: any ReverseGeocoderClient
    private let timeout: TimeInterval
    private let fallbackName: String
    private var continuation: CheckedContinuation<String, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(client: any ReverseGeocoderClient, timeout: TimeInterval, fallbackName: String) {
        self.client = client
        self.timeout = timeout.isFinite ? min(max(timeout, 0.1), 30) : LocationManager.reverseGeocodingTimeout
        self.fallbackName = fallbackName
    }

    func name(for location: CLLocation) async -> String {
        guard !Task.isCancelled else { return fallbackName }
        let timeoutSeconds = timeout
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self, timeoutSeconds] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)) }
                    catch { return }
                    self?.finish(with: fallbackName, cancelGeocoder: true)
                }
                client.reverseGeocode(location) { [weak self] name in
                    let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.finish(with: cleanedName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(with: fallbackName, cancelGeocoder: true)
            }
        }
    }

    private func finish(with name: String, cancelGeocoder: Bool = false) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if cancelGeocoder { client.cancel() }
        continuation.resume(returning: name)
    }
}

@MainActor
final class ProximityMonitor: NSObject, CLLocationManagerDelegate {
    static let radiusMeters: CLLocationDistance = 5_000
    static let maximumMonitoredRegions = NearbyMonitoringRegionPolicy.maximumCount

    private let manager = CLLocationManager()
    private let identifierPrefix = "weather-place-"
    private let savedNearbyKey = "nearby.weather.place.ids"
    private var wantsAlwaysAuthorization = false
    private(set) var nearbyPlaceIDs: Set<UUID>
    private(set) var authorizationUnavailable: Bool
    private(set) var failedPlaceIDs: Set<UUID> = []
    private(set) var overflowPlaceIDs: Set<UUID> = []
    var onChange: ((Set<UUID>) -> Void)?
    var onMonitoringFailureChange: ((Set<UUID>) -> Void)?
    var onMonitoringOverflowChange: ((Set<UUID>) -> Void)?
    var onAuthorizationAvailabilityChange: ((Bool) -> Void)?

    override init() {
        let saved = UserDefaults.standard.stringArray(forKey: savedNearbyKey) ?? []
        nearbyPlaceIDs = Set(saved.compactMap(UUID.init(uuidString:)))
        authorizationUnavailable = false
        super.init()
        manager.delegate = self
        authorizationUnavailable = NearbyAuthorizationPolicy.isUnavailable(manager.authorizationStatus.rawValue)
        if authorizationUnavailable {
            updateNearbyIDs([])
        }
    }

    func configure(for places: [Place]) {
        let nearbyPlaces = places.filter {
            $0.rules.contains { $0.enabled && $0.onlyWhenNearby }
        }
        let monitoredPlaces = Array(nearbyPlaces.prefix(Self.maximumMonitoredRegions))
        let overflowIDs = NearbyMonitoringRegionPolicy.overflowIDs(for: nearbyPlaces.map(\.id))
        updateOverflowPlaceIDs(overflowIDs)
        let wantedIDs = Set(monitoredPlaces.map(\.id))
        updateFailedPlaceIDs(NearbyMonitoringFailureState.reconciled(failedPlaceIDs, wantedPlaceIDs: wantedIDs))

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            updateFailedPlaceIDs(wantedIDs)
            return
        }

        for region in manager.monitoredRegions where region.identifier.hasPrefix(identifierPrefix) {
            manager.stopMonitoring(for: region)
        }

        updateNearbyIDs(nearbyPlaceIDs.intersection(wantedIDs))
        for place in monitoredPlaces {
            let center = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
            let maximumRadius = manager.maximumRegionMonitoringDistance
            guard maximumRadius > 0 else {
                updateFailedPlaceIDs(NearbyMonitoringFailureState.markedFailed(place.id, in: failedPlaceIDs))
                continue
            }
            let radius = min(Self.radiusMeters, maximumRadius)
            let region = CLCircularRegion(
                center: center,
                radius: radius,
                identifier: identifierPrefix + place.id.uuidString
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            manager.requestState(for: region)
        }
    }

    func requestBackgroundAuthorization() {
        wantsAlwaysAuthorization = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            wantsAlwaysAuthorization = false
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            wantsAlwaysAuthorization = false
        case .denied, .restricted:
            wantsAlwaysAuthorization = false
        @unknown default:
            wantsAlwaysAuthorization = false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager === manager else { return }
            let unavailable = NearbyAuthorizationPolicy.isUnavailable(manager.authorizationStatus.rawValue)
            self.updateAuthorizationUnavailable(unavailable)
            if wantsAlwaysAuthorization, manager.authorizationStatus == .authorizedWhenInUse {
                wantsAlwaysAuthorization = false
                manager.requestAlwaysAuthorization()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in set(region: region, isNearby: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        Task { @MainActor in
            guard self.manager === manager, let id = self.placeID(for: region) else { return }
            self.updateFailedPlaceIDs(NearbyMonitoringFailureState.markedStarted(id, in: self.failedPlaceIDs))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard let region else { return }
        Task { @MainActor in
            guard self.manager === manager, let id = self.placeID(for: region) else { return }
            self.set(region: region, isNearby: false)
            self.updateFailedPlaceIDs(NearbyMonitoringFailureState.markedFailed(id, in: self.failedPlaceIDs))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in set(region: region, isNearby: false) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        Task { @MainActor in
            switch state {
            case .inside: set(region: region, isNearby: true)
            case .outside: set(region: region, isNearby: false)
            case .unknown: break
            }
        }
    }

    private func set(region: CLRegion, isNearby: Bool) {
        guard !authorizationUnavailable else { return }
        guard let id = placeID(for: region) else { return }
        var updated = nearbyPlaceIDs
        if isNearby { updated.insert(id) } else { updated.remove(id) }
        updateNearbyIDs(updated)
    }

    private func placeID(for region: CLRegion) -> UUID? {
        guard region.identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(region.identifier.dropFirst(identifierPrefix.count)))
    }

    private func updateNearbyIDs(_ updated: Set<UUID>) {
        guard updated != nearbyPlaceIDs else { return }
        nearbyPlaceIDs = updated
        UserDefaults.standard.set(updated.map(\.uuidString), forKey: savedNearbyKey)
        onChange?(updated)
    }

    private func updateFailedPlaceIDs(_ updated: Set<UUID>) {
        guard updated != failedPlaceIDs else { return }
        failedPlaceIDs = updated
        onMonitoringFailureChange?(updated)
    }

    private func updateOverflowPlaceIDs(_ updated: Set<UUID>) {
        guard updated != overflowPlaceIDs else { return }
        overflowPlaceIDs = updated
        onMonitoringOverflowChange?(updated)
    }

    private func updateAuthorizationUnavailable(_ unavailable: Bool) {
        guard unavailable != authorizationUnavailable else { return }
        authorizationUnavailable = unavailable
        onAuthorizationAvailabilityChange?(unavailable)
        if unavailable {
            updateNearbyIDs([])
        }
    }
}

enum NearbyAuthorizationPolicy {
    static func isUnavailable(_ rawStatus: Int32) -> Bool {
        switch rawStatus {
        case CLAuthorizationStatus.authorizedAlways.rawValue:
            false
        default:
            true
        }
    }
}

enum NearbyMonitoringFailureState {
    static func reconciled(_ failedIDs: Set<UUID>, wantedPlaceIDs: Set<UUID>) -> Set<UUID> {
        failedIDs.intersection(wantedPlaceIDs)
    }

    static func markedFailed(_ placeID: UUID, in failedIDs: Set<UUID>) -> Set<UUID> {
        failedIDs.union([placeID])
    }

    static func markedStarted(_ placeID: UUID, in failedIDs: Set<UUID>) -> Set<UUID> {
        failedIDs.subtracting([placeID])
    }
}

enum NearbyMonitoringRegionPolicy {
    static let maximumCount = 20

    static func overflowIDs(for orderedPlaceIDs: [UUID]) -> Set<UUID> {
        Set(orderedPlaceIDs.dropFirst(maximumCount))
    }
}

enum NearbyMonitoringOverflowSummary {
    static func text(placeNames: [String], languageStyle: AlertLanguageStyle) -> String {
        guard !placeNames.isEmpty else { return "" }
        let visibleNames = Array(placeNames.prefix(3)).joined(separator: ", ")
        let remainingCount = max(0, placeNames.count - 3)
        let names = visibleNames + (remainingCount > 0 ? " +\(remainingCount)" : "")
        return languageStyle == .english
            ? "Not monitored: \(names). iOS supports nearby alerts for up to 20 places; turn off nearby-only for a place that does not need it to free a slot."
            : "Overvåkes ikke: \(names). iOS støtter nærhetsvarsler for opptil 20 steder; slå av «Bare når jeg er i nærheten» for et sted som ikke trenger det, for å frigjøre en plass."
    }
}

import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func current() async throws -> CLLocation {
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        Task { @MainActor in
            if let l = locs.last { continuation?.resume(returning: l) }
            continuation = nil
        }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        Task { @MainActor in continuation?.resume(throwing: e); continuation = nil }
    }

    static func name(for loc: CLLocation) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(loc)
        return marks?.first?.locality ?? marks?.first?.name ?? "Min posisjon"
    }
}

@MainActor
final class ProximityMonitor: NSObject, CLLocationManagerDelegate {
    static let radiusMeters: CLLocationDistance = 5_000

    private let manager = CLLocationManager()
    private let identifierPrefix = "weather-place-"
    private let savedNearbyKey = "nearby.weather.place.ids"
    private var wantsAlwaysAuthorization = false
    private(set) var nearbyPlaceIDs: Set<UUID>
    var onChange: ((Set<UUID>) -> Void)?

    override init() {
        let saved = UserDefaults.standard.stringArray(forKey: savedNearbyKey) ?? []
        nearbyPlaceIDs = Set(saved.compactMap(UUID.init(uuidString:)))
        super.init()
        manager.delegate = self
    }

    func configure(for places: [Place]) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let monitoredPlaces = Array(places.filter {
            $0.rules.contains { $0.enabled && $0.onlyWhenNearby }
        }.prefix(20))
        let wantedIDs = Set(monitoredPlaces.map(\.id))

        for region in manager.monitoredRegions where region.identifier.hasPrefix(identifierPrefix) {
            manager.stopMonitoring(for: region)
        }

        updateNearbyIDs(nearbyPlaceIDs.intersection(wantedIDs))
        for place in monitoredPlaces {
            let center = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
            let maximumRadius = manager.maximumRegionMonitoringDistance
            guard maximumRadius > 0 else { continue }
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
            if wantsAlwaysAuthorization, manager.authorizationStatus == .authorizedWhenInUse {
                wantsAlwaysAuthorization = false
                manager.requestAlwaysAuthorization()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in set(region: region, isNearby: true) }
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
        guard region.identifier.hasPrefix(identifierPrefix),
              let id = UUID(uuidString: String(region.identifier.dropFirst(identifierPrefix.count))) else { return }
        var updated = nearbyPlaceIDs
        if isNearby { updated.insert(id) } else { updated.remove(id) }
        updateNearbyIDs(updated)
    }

    private func updateNearbyIDs(_ updated: Set<UUID>) {
        guard updated != nearbyPlaceIDs else { return }
        nearbyPlaceIDs = updated
        UserDefaults.standard.set(updated.map(\.uuidString), forKey: savedNearbyKey)
        onChange?(updated)
    }
}

import XCTest
import UserNotifications
import CoreLocation
import SwiftUI
@testable import VarselApp

private final class FakeNotificationCenter: NotificationCenterClient {
    enum Failure: Error { case rejected }
    var pending: [UNNotificationRequest]
    var failedIDs: Set<String> = []
    var afterAdd: (() -> Void)?

    init(pending: [UNNotificationRequest] = []) { self.pending = pending }

    func pendingNotificationRequests() async -> [UNNotificationRequest] { pending }

    func add(_ request: UNNotificationRequest) async throws {
        if failedIDs.contains(request.identifier) { throw Failure.rejected }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
        afterAdd?()
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

@MainActor
private final class FakeOneShotLocationClient: OneShotLocationClient {
    var authorizationStatusRawValue = CLAuthorizationStatus.authorizedWhenInUse.rawValue
    var onAuthorizationChange: ((Int32) -> Void)?
    var onLocations: (([CLLocation]) -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var locationRequestCount = 0
    private(set) var authorizationRequestCount = 0

    func requestWhenInUseAuthorization() { authorizationRequestCount += 1 }
    func requestLocation() { locationRequestCount += 1 }
    // Keep callbacks available to model a callback already queued when invalidated.
    func invalidate() {}
    func deliver(_ location: CLLocation) { onLocations?([location]) }
}

@MainActor
private final class FakeWatchApplicationContextClient: WatchApplicationContextClient {
    var isSupported = true
    var isActivated = true
    var failuresRemaining = 0
    var onUpdate: (() -> Void)?
    private(set) var attempts: [[String: Data]] = []

    func updateApplicationContext(_ context: [String: Data]) throws {
        attempts.append(context)
        onUpdate?()
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NSError(domain: "WatchSync", code: 1)
        }
    }
}

@MainActor
private final class FakeReverseGeocoderClient: ReverseGeocoderClient {
    private(set) var cancelCount = 0
    private var completion: (@MainActor @Sendable (String?) -> Void)?
    var hasPendingCompletion: Bool { completion != nil }

    func reverseGeocode(
        _ location: CLLocation,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        self.completion = completion
    }

    func cancel() { cancelCount += 1 }
    func deliver(_ name: String?) { completion?(name) }
}

private actor ForecastFetchCounter {
    private var storedValue = 0
    func increment() { storedValue += 1 }
    func value() -> Int { storedValue }
}

private actor ForecastRefreshConcurrencyProbe {
    private let concurrencyLimit: Int
    private var activeRequests = 0
    private var maximumConcurrentRequests = 0
    private var startedLocations = Set<String>()
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasReleasedRequests = false
    private var thresholdWaiter: CheckedContinuation<Bool, Never>?

    init(concurrencyLimit: Int) {
        self.concurrencyLimit = concurrencyLimit
    }

    func recordAndWait(latitude: Double, longitude: Double) async {
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        startedLocations.insert("\(Int((latitude * 10_000).rounded())):\(Int((longitude * 10_000).rounded()))")
        if maximumConcurrentRequests >= concurrencyLimit {
            thresholdWaiter?.resume(returning: true)
            thresholdWaiter = nil
        }

        guard !hasReleasedRequests else {
            activeRequests -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseWaiters.append(continuation)
        }
        activeRequests -= 1
    }

    func waitForLimitOrTimeout() async -> Bool {
        guard maximumConcurrentRequests < concurrencyLimit else { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            thresholdWaiter = continuation
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.finishThresholdWaitIfNeeded()
            }
        }
    }

    func releaseAll() {
        hasReleasedRequests = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func snapshot() -> (maximumConcurrentRequests: Int, startedLocations: Set<String>) {
        (maximumConcurrentRequests, startedLocations)
    }

    private func finishThresholdWaitIfNeeded() {
        thresholdWaiter?.resume(returning: maximumConcurrentRequests >= concurrencyLimit)
        thresholdWaiter = nil
    }
}

@MainActor
final class PlannerTests: XCTestCase {
    func testReverseGeocoderTimeoutFallsBackAndIgnoresLateResponse() async {
        let client = FakeReverseGeocoderClient()
        let location = CLLocation(latitude: 64.4, longitude: 11.5)

        let name = await LocationManager.name(
            for: location,
            timeout: 0.1,
            clientFactory: { client }
        )

        XCTAssertEqual(name, "Min posisjon")
        XCTAssertEqual(client.cancelCount, 1)
        client.deliver("Trondheim")
        XCTAssertEqual(client.cancelCount, 1)
    }

    func testReverseGeocoderTrimsSuccessfulNameWithoutCancelling() async {
        let client = FakeReverseGeocoderClient()
        let location = CLLocation(latitude: 64.4, longitude: 11.5)
        let request = Task { @MainActor in
            await LocationManager.name(for: location, timeout: 1, clientFactory: { client })
        }

        for _ in 0..<20 where !client.hasPendingCompletion {
            // Yield until the lookup has registered its completion before delivering.
            await Task.yield()
        }
        XCTAssertTrue(client.hasPendingCompletion)
        client.deliver("  Trondheim  ")

        let name = await request.value
        XCTAssertEqual(name, "Trondheim")
        XCTAssertEqual(client.cancelCount, 0)
    }

    func testReverseGeocoderFallbackUsesSelectedLanguageAndPreservesResolvedName() async {
        let location = CLLocation(latitude: 63.4305, longitude: 10.3951)
        let localizedFallbacks: [(AlertLanguageStyle, String)] = [
            (.bokmal, "Min posisjon"),
            (.inntrondersk, "Mi posisjon"),
            (.english, "My location")
        ]

        for (languageStyle, expectedFallback) in localizedFallbacks {
            let client = FakeReverseGeocoderClient()
            let request = Task { @MainActor in
                await LocationManager.name(
                    for: location,
                    timeout: 1,
                    clientFactory: { client },
                    languageStyle: languageStyle
                )
            }
            for _ in 0..<20 where !client.hasPendingCompletion { await Task.yield() }
            XCTAssertTrue(client.hasPendingCompletion)
            client.deliver("  ")
            let resolvedName = await request.value
            XCTAssertEqual(resolvedName, expectedFallback)
        }

        let client = FakeReverseGeocoderClient()
        let request = Task { @MainActor in
            await LocationManager.name(
                for: location,
                timeout: 1,
                clientFactory: { client },
                languageStyle: .english
            )
        }
        for _ in 0..<20 where !client.hasPendingCompletion { await Task.yield() }
        XCTAssertTrue(client.hasPendingCompletion)
        client.deliver(" Trondheim ")
        let resolvedName = await request.value
        XCTAssertEqual(resolvedName, "Trondheim")
    }

    func testCancelledReverseGeocoderFallsBackAndCancelsClient() async {
        let client = FakeReverseGeocoderClient()
        let location = CLLocation(latitude: 64.4, longitude: 11.5)
        let request = Task { @MainActor in
            await LocationManager.name(for: location, timeout: 1, clientFactory: { client })
        }
        for _ in 0..<20 where !client.hasPendingCompletion { await Task.yield() }
        XCTAssertTrue(client.hasPendingCompletion)

        request.cancel()
        let name = await request.value

        XCTAssertEqual(name, "Min posisjon")
        XCTAssertEqual(client.cancelCount, 1)
        client.deliver("Trondheim")
        XCTAssertEqual(client.cancelCount, 1)
    }

    func testPlaceDistanceRejectsMalformedCoordinates() {
        let home = CLLocation(latitude: 64, longitude: 11)
        XCTAssertEqual(Place(name: "Hjem", lat: 64, lon: 11).distance(to: home) ?? .nan, 0, accuracy: 0.001)
        XCTAssertNotNil(Place(name: "Klinga", lat: 64.01, lon: 11.01).distance(to: home))
        XCTAssertNil(Place(name: "Ugyldig", lat: 91, lon: 11).distance(to: home))
        XCTAssertNil(Place(name: "Manglende", lat: .nan, lon: 11).distance(to: home))
        XCTAssertNil(Place(name: "Ugyldig lengdegrad", lat: 64, lon: 181).distance(to: home))
        XCTAssertNil(Place(name: "Klinga", lat: 64, lon: 11).distance(to: CLLocation(latitude: .nan, longitude: 11)))
    }

    func testAutomaticPlaceOrderingPinsFavoritesThenSortsByHomeDistance() {
        let home = Place(name: "Hjem", lat: 64, lon: 11)
        let near = Place(name: "Nær", lat: 64.01, lon: 11.01)
        let far = Place(name: "Fjern", lat: 65, lon: 12)
        let favorite = Place(name: "Favoritt", lat: 66, lon: 13)
        let result = PlaceOrdering.automatic([far, near, favorite, home], favorite1ID: favorite.id, favorite2ID: nil, homeID: home.id)
        XCTAssertEqual(result.map(\.id), [favorite.id, home.id, near.id, far.id])
    }

    func testExpandedPlaceSurvivesReorderingAndClearsWhenPlaceIsRemoved() {
        let expanded = UUID()
        let other = UUID()
        var state = PlaceExpansionState()
        state.toggle(expanded)

        state.reconcile(availablePlaceIDs: Set([other, expanded]))
        XCTAssertEqual(state.expandedPlaceID, expanded)

        // Forecast refreshes do not affect this place-ID-only state.
        state.reconcile(availablePlaceIDs: Set([expanded, other]))
        XCTAssertEqual(state.expandedPlaceID, expanded)

        state.reconcile(availablePlaceIDs: Set([other]))
        XCTAssertNil(state.expandedPlaceID)
    }

    func testExpandedPlaceToggleClosesItOrMovesExpansionToAnotherPlace() {
        let first = UUID()
        let second = UUID()
        var state = PlaceExpansionState()

        state.toggle(first)
        XCTAssertEqual(state.expandedPlaceID, first)
        state.toggle(first)
        XCTAssertNil(state.expandedPlaceID)

        state.toggle(first)
        state.toggle(second)
        XCTAssertEqual(state.expandedPlaceID, second)
        state.toggle(second)
        XCTAssertNil(state.expandedPlaceID)
    }

    func testManualPlaceOrderSurvivesPersistedStateRoundTrip() throws {
        let first = Place(name: "Først", lat: 64, lon: 11)
        let second = Place(name: "Deretter", lat: 65, lon: 12)
        let state = PersistedStoreState(places: [second, first], selectedID: second.id, log: [])
        let decoded = try JSONDecoder().decode(PersistedStoreState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.places.map(\.id), [second.id, first.id])
    }

    func testPersistedStateKeepsFirstPlaceForDuplicateIDsAndRetainsSelectionAndCache() throws {
        let duplicateID = UUID()
        let first = Place(id: duplicateID, name: "Første", lat: 64, lon: 11)
        let duplicate = Place(id: duplicateID, name: "Duplikat", lat: 65, lon: 12)
        let other = Place(name: "Annet", lat: 66, lon: 13)
        let cachedForecast = [ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 40, dew: 6)]
        let state = PersistedStoreState(
            places: [first, duplicate, other], selectedID: duplicateID, log: [],
            forecasts: [duplicateID: cachedForecast]
        )

        let decoded = try JSONDecoder().decode(PersistedStoreState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded.places.map(\.id), [duplicateID, other.id])
        XCTAssertEqual(decoded.places.map(\.name), ["Første", "Annet"])
        XCTAssertEqual(decoded.selectedID, duplicateID)
        XCTAssertEqual(decoded.forecasts[duplicateID], cachedForecast)
    }

    func testSolarCycleSuppressesSunAfterLocalSunset() {
        let evening = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 23))!
        XCTAssertTrue(SolarCycle.isAfterSunset(evening, latitude: 64, longitude: 11))
    }

    func testSunRulesRequireLocalDaylightForRowsAndAlerts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 12, day: 21, hour: 20)))
        let hour = ForecastHour(time: evening, temp: 2, precip: 0, wind: 1, cloud: 5, dew: 0)
        var rule = Rule(type: .sol)
        rule.durationHours = 1
        rule.activeFromHour = 0
        rule.activeToHour = 0

        let plan = Planner.plan(
            rule: rule, forecast: [hour], placeName: "Klinga",
            latitude: 64.46, longitude: 11.50,
            now: evening.addingTimeInterval(-3_600), calendar: calendar
        )
        let status = Planner.status(
            for: rule, forecast: [hour], latitude: 64.46, longitude: 11.50,
            now: evening
        )

        XCTAssertFalse(SolarCycle.isDaylight(evening, latitude: 64.46, longitude: 11.50))
        XCTAssertTrue(plan.hitIndices.isEmpty)
        XCTAssertTrue(plan.alerts.isEmpty)
        XCTAssertNil(status)
    }

    func testSolarCycleProvidesSunriseAndSunsetMarkersForHourlyRow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 12, day: 21, hour: 10)))
        let afternoon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 12, day: 21, hour: 14)))

        XCTAssertEqual(SolarCycle.transition(near: morning, latitude: 64.46, longitude: 11.50), .sunrise)
        XCTAssertEqual(SolarCycle.transition(near: afternoon, latitude: 64.46, longitude: 11.50), .sunset)

        let hourlyMarkers = (0..<24).compactMap { hour in
            SolarCycle.transition(
                near: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: morning)!,
                latitude: 64.46,
                longitude: 11.50
            )
        }
        XCTAssertEqual(hourlyMarkers.filter { $0 == .sunrise }.count, 1)
        XCTAssertEqual(hourlyMarkers.filter { $0 == .sunset }.count, 1)
    }

    func testSolarRowMarkersFollowTheDisplayedPlaceCoordinates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let winterDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 12, day: 21)))

        func markers(latitude: Double, longitude: Double) -> [(Int, SolarCycle.Transition)] {
            (0..<24).compactMap { hour in
                let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: winterDay)!
                return SolarCycle.transition(near: date, latitude: latitude, longitude: longitude)
                    .map { (hour, $0) }
            }
        }

        let klinga = markers(latitude: 64.46, longitude: 11.50)
        let oslo = markers(latitude: 59.91, longitude: 10.75)

        XCTAssertEqual(klinga.map(\.1), [.sunrise, .sunset])
        XCTAssertEqual(oslo.map(\.1), [.sunrise, .sunset])
        XCTAssertNotEqual(klinga.map(\.0), oslo.map(\.0))
    }

    func testSolarRowMarkersStayUniqueAcrossDaylightSavingTransitions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let transitionDays = [
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 3, day: 31))),
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 27)))
        ]

        for day in transitionDays {
            let start = calendar.startOfDay(for: day)
            let markers = (0..<26).compactMap { offset in
                let sample = calendar.date(byAdding: .hour, value: offset, to: start)!
                return SolarCycle.transition(near: sample, latitude: 64.46, longitude: 11.50)
            }

            XCTAssertEqual(markers.filter { $0 == .sunrise }.count, 1, "Expected one sunrise marker on DST day \(day)")
            XCTAssertEqual(markers.filter { $0 == .sunset }.count, 1, "Expected one sunset marker on DST day \(day)")
        }
    }

    func testSolarBoundaryCellsAreMarkersRatherThanSunPreviewOnDSTDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let transitionDays = [
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 3, day: 31))),
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 27))),
        ]

        for day in transitionDays {
            let start = calendar.startOfDay(for: day)
            var appearances: [(Date, SolarCycle.RowAppearance)] = []
            for offset in 0..<26 {
                let sample = try XCTUnwrap(calendar.date(byAdding: .hour, value: offset, to: start))
                let appearance = SolarCycle.rowAppearance(
                    near: sample, cloud: 0, sunThreshold: 100,
                    latitude: 64.46, longitude: 11.50, calendar: calendar
                )
                appearances.append((sample, appearance))
            }

            let sunriseCells = appearances.filter { $0.1 == .sunrise }
            let sunsetCells = appearances.filter { $0.1 == .sunset }
            XCTAssertEqual(sunriseCells.count, 1)
            XCTAssertEqual(sunsetCells.count, 1)
            guard let sunrise = sunriseCells.first, let sunset = sunsetCells.first else {
                XCTFail("Each DST day must have one sunrise and one sunset marker")
                continue
            }
            XCTAssertTrue((5...9).contains(calendar.component(.hour, from: sunrise.0)))
            XCTAssertTrue((16...21).contains(calendar.component(.hour, from: sunset.0)))
        }
    }

    func testPartialSunUsesSecondCloudThresholdButSolarBoundariesStillWin() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 15)))
        let noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day))
        XCTAssertEqual(SolarCycle.rowAppearance(
            near: noon, cloud: 10, sunThreshold: 20, sunThreshold2: 60,
            latitude: 63.43, longitude: 10.39, calendar: calendar
        ), .sunlit)
        XCTAssertEqual(SolarCycle.rowAppearance(
            near: noon, cloud: 40, sunThreshold: 20, sunThreshold2: 60,
            latitude: 63.43, longitude: 10.39, calendar: calendar
        ), .partlySunlit)
        XCTAssertEqual(SolarCycle.rowAppearance(
            near: noon, cloud: 70, sunThreshold: 20, sunThreshold2: 60,
            latitude: 63.43, longitude: 10.39, calendar: calendar
        ), .neutral)

        let start = calendar.startOfDay(for: day)
        let appearances = (0..<24).compactMap { offset -> SolarCycle.RowAppearance? in
            guard let sample = calendar.date(byAdding: .hour, value: offset, to: start) else { return nil }
            return SolarCycle.rowAppearance(
                near: sample, cloud: 40, sunThreshold: 20, sunThreshold2: 60,
                latitude: 63.43, longitude: 10.39, calendar: calendar
            )
        }
        XCTAssertTrue(appearances.contains(.sunrise))
        XCTAssertTrue(appearances.contains(.sunset))
    }

    func testPolarSolarStatesHaveNoFalseTransitionOrNightSunAlert() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let polarNight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 12, day: 21, hour: 12)))
        let polarDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 21, hour: 12)))
        let longyearbyenLatitude = 78.22
        let longyearbyenLongitude = 15.65

        XCTAssertFalse(SolarCycle.isDaylight(polarNight, latitude: longyearbyenLatitude, longitude: longyearbyenLongitude))
        XCTAssertNil(SolarCycle.transition(near: polarNight, latitude: longyearbyenLatitude, longitude: longyearbyenLongitude))
        XCTAssertTrue(SolarCycle.isDaylight(polarDay, latitude: longyearbyenLatitude, longitude: longyearbyenLongitude))
        XCTAssertNil(SolarCycle.transition(near: polarDay, latitude: longyearbyenLatitude, longitude: longyearbyenLongitude))

        var sunRule = Rule(type: .sol)
        sunRule.durationHours = 1
        sunRule.activeFromHour = 0
        sunRule.activeToHour = 0
        let nightForecast = [ForecastHour(time: polarNight, temp: -8, precip: 0, wind: 1, cloud: 0, dew: -9)]
        let plan = Planner.plan(
            rule: sunRule, forecast: nightForecast, placeName: "Longyearbyen",
            latitude: longyearbyenLatitude, longitude: longyearbyenLongitude,
            now: polarNight.addingTimeInterval(-3_600), calendar: calendar
        )
        XCTAssertTrue(plan.hitIndices.isEmpty)
        XCTAssertTrue(plan.alerts.isEmpty)
    }

    func testPersistedStoreStateRoundTripsForecastCacheAndTimestamp() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 20, dew: 5)
        let state = PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: [hour]], forecastUpdatedAt: [place.id: base], lastUpdate: base
        )
        let decoded = try JSONDecoder().decode(PersistedStoreState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.forecasts[place.id], [hour])
        XCTAssertEqual(decoded.forecastUpdatedAt[place.id], base)
        XCTAssertEqual(decoded.lastUpdate, base)
    }

    func testPersistedForecastCacheIsAvailableForOfflineLaunch() throws {
        let place = Place(name: "Hornburu", lat: 64.2, lon: 11.4)
        let hour = ForecastHour(time: base, temp: 9, precip: 0, wind: 1, cloud: 40, dew: 5)
        let encoded = try JSONEncoder().encode(PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: [hour]], forecastUpdatedAt: [place.id: base], lastUpdate: base
        ))

        let restored = try JSONDecoder().decode(PersistedStoreState.self, from: encoded)
        XCTAssertEqual(restored.places.first?.displayName, "Hornburu")
        XCTAssertEqual(restored.forecasts[place.id]?.first, hour)
        XCTAssertEqual(restored.forecastUpdatedAt[place.id], base)
    }

    func testPersistedForecastCacheRestoresSeveralPlacesTogether() throws {
        let first = Place(name: "Klinga", lat: 64, lon: 11)
        let second = Place(name: "Hornburu", lat: 64.2, lon: 11.4)
        let state = PersistedStoreState(
            places: [first, second], selectedID: first.id, log: [],
            forecasts: [
                first.id: forecast(values: [(8, 0, 1, 20, 4)]),
                second.id: forecast(values: [(9, 0, 2, 40, 5)])
            ],
            forecastUpdatedAt: [first.id: base, second.id: base]
        )
        let restored = try JSONDecoder().decode(
            PersistedStoreState.self,
            from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(Set(restored.forecasts.keys), Set([first.id, second.id]))
        XCTAssertEqual(restored.forecasts[first.id]?.first?.temp, 8)
        XCTAssertEqual(restored.forecasts[second.id]?.first?.temp, 9)
    }

    func testOfflineRestartKeepsLastForecastAndFetchTimeUnchanged() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 7, precip: 0, wind: 1, cloud: 80, dew: 5)
        let state = PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: [hour]], forecastUpdatedAt: [place.id: base], lastUpdate: base
        )
        let restored = try JSONDecoder().decode(
            PersistedStoreState.self,
            from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(restored.forecasts[place.id], [hour])
        XCTAssertEqual(restored.forecastUpdatedAt[place.id], base)
        XCTAssertEqual(restored.lastUpdate, base)
    }

    func testCachedTimestampIsPreservedAcrossWidgetAndWatchTransfer() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let snapshot = WidgetWeatherSnapshot(
            place: place, forecast: forecast(values: [(8, 0, 1, 20, 4)]), updatedAt: base
        )
        let transfer = WatchWeatherTransfer(snapshot: snapshot, sentAt: base.addingTimeInterval(1))
        let restored = try JSONDecoder().decode(
            WatchWeatherTransfer.self,
            from: JSONEncoder().encode(transfer)
        )
        XCTAssertEqual(restored.snapshot?.updatedAt, snapshot.updatedAt)
        XCTAssertEqual(restored.snapshot?.place.id, snapshot.place.id)
    }

    func testWatchTransferDecoderAcceptsLegacySnapshotPayload() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let snapshot = WidgetWeatherSnapshot(
            place: place, forecast: forecast(values: [(8, 0, 1, 20, 4)]), updatedAt: base
        )
        let legacyPayload = try JSONEncoder().encode(snapshot)

        let decoded = try XCTUnwrap(
            WatchTransferPolicy.decodeTransferPayload(legacyPayload, referenceDate: base)
        )

        XCTAssertEqual(decoded.snapshot?.place.id, place.id)
        XCTAssertEqual(decoded.snapshot?.forecast, snapshot.forecast)
        XCTAssertEqual(decoded.sentAt, snapshot.updatedAt)
    }

    func testWatchContextRetrySendsNewestSnapshotAfterTransientFailure() throws {
        let client = FakeWatchApplicationContextClient()
        client.failuresRemaining = 2
        let manager = WatchSyncManager(client: client)
        let oldPlace = Place(name: "Klinga", lat: 64, lon: 11)
        let newPlace = Place(name: "Hornburu", lat: 64.1, lon: 11.1)

        manager.send(place: oldPlace, forecast: [], updatedAt: base)
        manager.send(place: newPlace, forecast: [], updatedAt: base.addingTimeInterval(1))
        XCTAssertEqual(client.attempts.count, 2)
        XCTAssertEqual(try transferredPlaceName(from: client.attempts[0]), "Klinga")
        XCTAssertEqual(try transferredPlaceName(from: client.attempts[1]), "Hornburu")

        manager.retryPendingTransfer()

        XCTAssertEqual(client.attempts.count, 3)
        XCTAssertEqual(try transferredPlaceName(from: client.attempts[2]), "Hornburu")
        manager.retryPendingTransfer()
        XCTAssertEqual(client.attempts.count, 3, "A successful retry should clear the pending transfer")
    }

    @MainActor
    func testWatchClearSupersedesFailedPendingSnapshot() throws {
        let client = FakeWatchApplicationContextClient()
        client.failuresRemaining = 2
        let manager = WatchSyncManager(client: client)
        let place = Place(name: "Klinga", lat: 64, lon: 11)

        manager.send(place: place, forecast: [], updatedAt: base)
        manager.clear()

        XCTAssertEqual(client.attempts.count, 2)
        XCTAssertEqual(try transferredPlaceName(from: client.attempts[0]), "Klinga")
        let failedClearData = try XCTUnwrap(client.attempts[1]["weatherSnapshot"])
        XCTAssertNil(try JSONDecoder().decode(WatchWeatherTransfer.self, from: failedClearData).snapshot)

        manager.retryPendingTransfer()

        XCTAssertEqual(client.attempts.count, 3)
        let retriedClearData = try XCTUnwrap(client.attempts[2]["weatherSnapshot"])
        XCTAssertNil(try JSONDecoder().decode(WatchWeatherTransfer.self, from: retriedClearData).snapshot)
        manager.retryPendingTransfer()
        XCTAssertEqual(client.attempts.count, 3, "A successful clear retry must not resend the stale snapshot")
    }

    @MainActor
    func testWatchActivationSendsOnlyLatestTransferQueuedWhileInactive() async throws {
        let client = FakeWatchApplicationContextClient()
        client.isActivated = false
        let manager = WatchSyncManager(client: client)
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        manager.send(place: place, forecast: [], updatedAt: base)
        manager.clear()
        XCTAssertTrue(client.attempts.isEmpty)

        let delivered = expectation(description: "Activation flushes the queued clear")
        client.onUpdate = { delivered.fulfill() }
        client.isActivated = true
        manager.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        await fulfillment(of: [delivered], timeout: 1)

        XCTAssertEqual(client.attempts.count, 1)
        let data = try XCTUnwrap(client.attempts[0]["weatherSnapshot"])
        XCTAssertNil(try JSONDecoder().decode(WatchWeatherTransfer.self, from: data).snapshot)
        manager.retryPendingTransfer()
        XCTAssertEqual(client.attempts.count, 1, "Activation must clear the pending transfer after delivery")
    }

    private func transferredPlaceName(from context: [String: Data]) throws -> String? {
        let data = try XCTUnwrap(context["weatherSnapshot"])
        return try JSONDecoder().decode(WatchWeatherTransfer.self, from: data).snapshot?.place.name
    }

    @MainActor
    func testChangingWidgetLanguageKeepsCachedForecastTimestamp() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4)
        let cached = WidgetWeatherSnapshot(
            place: place, forecast: [hour], updatedAt: base,
            languageStyle: .bokmal, textSeparator: .space
        )
        let fallback = try XCTUnwrap(Store.widgetSnapshot(
            place: place, forecast: [], updatedAt: nil, cached: cached
        ))

        let sent = WidgetWeatherSnapshot(
            place: fallback.place, forecast: fallback.forecast, updatedAt: fallback.updatedAt,
            languageStyle: .inntrondersk, textSeparator: .dash
        )
        let transferred = try JSONDecoder().decode(
            WatchWeatherTransfer.self,
            from: JSONEncoder().encode(WatchWeatherTransfer(snapshot: sent, sentAt: base.addingTimeInterval(1)))
        )
        XCTAssertEqual(transferred.snapshot?.updatedAt, base)
        XCTAssertEqual(transferred.snapshot?.forecast, [hour])
        XCTAssertEqual(transferred.snapshot?.languageStyle, .inntrondersk)
        XCTAssertEqual(transferred.snapshot?.textSeparator, .dash)
    }

    func testFailedRefreshKeepsOriginalCacheTimestamp() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4)
        let cached = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base)
        let fallback = try XCTUnwrap(Store.widgetSnapshot(
            place: place, forecast: [], updatedAt: nil, cached: cached,
            now: base.addingTimeInterval(90 * 60)
        ))
        XCTAssertEqual(fallback.updatedAt, base)
        XCTAssertEqual(fallback.forecast, [hour])
    }

    func testPersistedStoreStateMigratesLegacyDataWithoutForecastCache() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let legacy = PersistedStoreState(places: [place], selectedID: place.id, log: [])
        let data = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "forecasts")
        object.removeValue(forKey: "forecastUpdatedAt")
        object.removeValue(forKey: "lastUpdate")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PersistedStoreState.self, from: legacyData)
        XCTAssertEqual(decoded.places.map(\.id), [place.id])
        XCTAssertEqual(decoded.selectedID, place.id)
        XCTAssertTrue(decoded.forecasts.isEmpty)
        XCTAssertTrue(decoded.forecastUpdatedAt.isEmpty)
        XCTAssertNil(decoded.lastUpdate)
    }

    func testPersistedStoreStateKeepsHealthyCacheWhenOneForecastEntryIsCorrupt() throws {
        let first = Place(name: "Klinga", lat: 64, lon: 11)
        let second = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let state = PersistedStoreState(
            places: [first, second], selectedID: first.id, log: [],
            forecasts: [first.id: forecast(values: [(8, 0, 1, 20, 4)])],
            forecastUpdatedAt: [first.id: base]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var forecasts = try XCTUnwrap(object["forecasts"] as? [String: Any])
        forecasts[second.id.uuidString] = ["not": "a forecast"]
        object["forecasts"] = forecasts
        let data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PersistedStoreState.self, from: data)
        XCTAssertEqual(decoded.forecasts[first.id]?.count, 1)
        XCTAssertNil(decoded.forecasts[second.id])
    }

    func testPersistedStoreStateMarksMalformedForecastContainersForRepair() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let state = PersistedStoreState(places: [place], selectedID: place.id, log: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object["forecasts"] = "not a dictionary"
        object["forecastUpdatedAt"] = "not a dictionary"

        let decoded = try JSONDecoder().decode(
            PersistedStoreState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.places.map(\.id), [place.id])
        XCTAssertTrue(decoded.forecasts.isEmpty)
        XCTAssertTrue(decoded.forecastUpdatedAt.isEmpty)
        XCTAssertTrue(decoded.needsPersistedStateRepair)
    }

    @MainActor
    func testStorePersistsMalformedForecastContainerRepairAtLaunch() throws {
        let persistenceKey = "varsel.test.malformed-forecast-container.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4)
        let state = PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: [hour]], forecastUpdatedAt: [place.id: base]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object["forecasts"] = "not a dictionary"
        object["forecastUpdatedAt"] = "not a dictionary"
        UserDefaults.standard.set(
            try JSONSerialization.data(withJSONObject: object), forKey: persistenceKey
        )

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.places.map(\.id), [place.id])
        XCTAssertTrue(restored.forecasts.isEmpty)

        let repairedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repairedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: repairedData) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(repairedObject["forecasts"] as? [String: Any]).isEmpty)
        XCTAssertTrue(try XCTUnwrap(repairedObject["forecastUpdatedAt"] as? [String: Any]).isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(PersistedStoreState.self, from: repairedData).places.map(\.id), [place.id])
    }

    func testPersistedStoreStateFiltersImplausibleForecastHoursAndRequestsRepair() throws {
        let first = Place(name: "Klinga", lat: 64, lon: 11)
        let second = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let healthy = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4)
        var corrupt = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4
        )
        corrupt.temp = 999
        let healthyLater = ForecastHour(
            time: base.addingTimeInterval(7_200), temp: 7, precip: 0, wind: 2, cloud: 40, dew: 3
        )
        let state = PersistedStoreState(
            places: [first, second], selectedID: first.id, log: [],
            forecasts: [first.id: [healthy, corrupt, healthyLater], second.id: [healthy]],
            forecastUpdatedAt: [first.id: base, second.id: base]
        )

        let decoded = try JSONDecoder().decode(
            PersistedStoreState.self, from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(decoded.forecasts[first.id], [healthy, healthyLater])
        XCTAssertEqual(decoded.forecasts[second.id], [healthy])
        XCTAssertTrue(decoded.needsPersistedStateRepair)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(encoded["needsPersistedStateRepair"], "Repair bookkeeping is not part of the stored format")

        let snapshot = try JSONDecoder().decode(
            WidgetWeatherSnapshot.self,
            from: JSONEncoder().encode(WidgetWeatherSnapshot(
                place: first, forecast: [healthy, corrupt], updatedAt: base
            ))
        )
        XCTAssertEqual(snapshot.forecast, [healthy], "Shared widget and Watch snapshots use the same physical bounds")
    }

    func testPersistedForecastCacheSortsDeduplicatesAndBoundsHourTimes() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let weakerDuplicate = PrecipitationSample(time: base.addingTimeInterval(15 * 60), rate: 0.5)
        let inHourSample = PrecipitationSample(time: base.addingTimeInterval(15 * 60), rate: 2)
        let nextHourSample = PrecipitationSample(time: base.addingTimeInterval(3_600), rate: 3)
        let first = ForecastHour(
            time: base, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4,
            radarSamples: [weakerDuplicate, inHourSample, nextHourSample]
        )
        var expectedFirst = first
        expectedFirst.radarSamples = [inHourSample]
        let second = ForecastHour(time: base.addingTimeInterval(3_600), temp: 7, precip: 0, wind: 2, cloud: 40, dew: 3)
        var duplicate = second
        duplicate.temp = 20
        let farFuture = ForecastHour(
            time: base.addingTimeInterval(11 * 24 * 3_600), temp: 6, precip: 0, wind: 2, cloud: 40, dew: 3
        )
        let state = PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: [second, first, duplicate, farFuture]],
            forecastUpdatedAt: [place.id: base]
        )

        let decoded = try JSONDecoder().decode(
            PersistedStoreState.self, from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(decoded.forecasts[place.id], [expectedFirst, second])
        XCTAssertTrue(decoded.needsPersistedStateRepair)

        let snapshot = try JSONDecoder().decode(
            WidgetWeatherSnapshot.self,
            from: JSONEncoder().encode(WidgetWeatherSnapshot(
                place: place, forecast: [second, first, duplicate, farFuture], updatedAt: base
            ))
        )
        XCTAssertEqual(snapshot.forecast, [expectedFirst, second])
    }

    func testPersistedForecastCacheCapsUniqueHoursAndKeepsNewestDeterministically() {
        let limit = YrService.maximumLocationForecastTimeSteps
        let hours = (0...limit).map { minute in
            ForecastHour(
                time: base.addingTimeInterval(TimeInterval(minute * 60)),
                temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4
            )
        }

        let forward = ForecastHour.sanitizedCacheSequence(hours, fetchedAt: base)
        let reversed = ForecastHour.sanitizedCacheSequence(Array(hours.reversed()), fetchedAt: base)

        XCTAssertEqual(forward.count, limit)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.first?.time, hours[1].time, "Drop the oldest usable hour")
        XCTAssertEqual(forward.last, hours.last)
    }

    func testWidgetSnapshotRejectsOnlyImplausiblyFutureUpdateTimes() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4)
        let tolerance = Store.forecastFutureTimestampTolerance

        func encodedSnapshot(updatedAt: Date) throws -> Data {
            try JSONEncoder().encode(WidgetWeatherSnapshot(
                place: place, forecast: [hour], updatedAt: updatedAt
            ))
        }

        let decoder = WidgetWeatherSnapshot.decoder(referenceDate: base)
        XCTAssertNoThrow(try decoder.decode(
            WidgetWeatherSnapshot.self,
            from: encodedSnapshot(updatedAt: base.addingTimeInterval(tolerance))
        ))
        XCTAssertThrowsError(try decoder.decode(
            WidgetWeatherSnapshot.self,
            from: encodedSnapshot(updatedAt: base.addingTimeInterval(tolerance + 1))
        ))

        let staleTime = base.addingTimeInterval(-WeatherGlance.staleAfter - 1)
        let stale = try decoder.decode(
            WidgetWeatherSnapshot.self,
            from: encodedSnapshot(updatedAt: staleTime)
        )
        XCTAssertEqual(
            WeatherGlance.freshness(updatedAt: stale.updatedAt, now: base)?.isStale,
            true,
            "A stale snapshot remains available so the normal stale warning can be shown"
        )
    }

    @MainActor
    func testStoreRestoresHealthyForecastsAroundCorruptAndUnknownEntries() throws {
        let persistenceKey = "varsel.test.store-corrupt-forecast-entry.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let first = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let second = Place(name: "Hytte", lat: 64.2, lon: 11.4)
        let unknownID = UUID()
        let healthyHour = ForecastHour(time: base, temp: 7, precip: 0, wind: 1, cloud: 30, dew: 4)
        let state = PersistedStoreState(
            places: [first, second], selectedID: first.id, log: [],
            forecasts: [
                first.id: [healthyHour],
                second.id: [healthyHour],
                unknownID: [healthyHour],
            ],
            forecastUpdatedAt: [first.id: base, second.id: base, unknownID: base]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var forecasts = try XCTUnwrap(object["forecasts"] as? [String: Any])
        forecasts[second.id.uuidString] = ["broken": "forecast"]
        object["forecasts"] = forecasts
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: object), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.places.map(\.id), [first.id, second.id])
        XCTAssertEqual(restored.selectedID, first.id)
        XCTAssertEqual(restored.forecasts[first.id], [healthyHour])
        XCTAssertNil(restored.forecasts[second.id])
        XCTAssertNil(restored.forecasts[unknownID])
        XCTAssertEqual(restored.forecastUpdatedAt(for: first.id), base)
        XCTAssertNil(restored.forecastUpdatedAt(for: second.id))
        XCTAssertNil(restored.forecastUpdatedAt(for: unknownID))

        let repairedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repairedState = try JSONDecoder().decode(PersistedStoreState.self, from: repairedData)
        XCTAssertEqual(Set(repairedState.forecasts.keys), Set([first.id]))
        XCTAssertEqual(Set(repairedState.forecastUpdatedAt.keys), Set([first.id]))

        let relaunched = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(relaunched.places.map(\.id), [first.id, second.id])
        XCTAssertEqual(relaunched.selectedID, first.id)
        XCTAssertEqual(relaunched.forecasts[first.id], [healthyHour])
        XCTAssertNil(relaunched.forecasts[second.id])
        XCTAssertNil(relaunched.forecasts[unknownID])
        XCTAssertEqual(relaunched.forecastUpdatedAt(for: first.id), base)
        XCTAssertNil(relaunched.forecastUpdatedAt(for: second.id))
        XCTAssertNil(relaunched.forecastUpdatedAt(for: unknownID))
    }

    @MainActor
    func testStoreRepairsInvalidForecastTimestampAndKeepsForecastCache() throws {
        let persistenceKey = "varsel.test.invalid-forecast-timestamp.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let now = Date()
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let forecast = (0..<3).map { offset in
            ForecastHour(
                time: now.addingTimeInterval(Double(offset) * 3_600),
                temp: 7, precip: 0, wind: 1, cloud: 30, dew: 4
            )
        }
        let state = PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: forecast], forecastUpdatedAt: [place.id: now]
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object["forecastUpdatedAt"] = [place.id.uuidString: "not-a-date"]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: object), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.forecasts[place.id], forecast)
        XCTAssertNil(restored.forecastUpdatedAt(for: place.id))

        let repairedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repairedState = try JSONDecoder().decode(PersistedStoreState.self, from: repairedData)
        XCTAssertEqual(repairedState.forecasts[place.id], forecast)
        XCTAssertTrue(repairedState.forecastUpdatedAt.isEmpty)

        let relaunched = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(relaunched.forecasts[place.id], forecast)
        XCTAssertNil(relaunched.forecastUpdatedAt(for: place.id))
    }

    func testPersistedCacheCanBeFilteredToKnownPlaces() throws {
        let known = Place(name: "Klinga", lat: 64, lon: 11)
        let deletedID = UUID()
        let state = PersistedStoreState(
            places: [known], selectedID: known.id, log: [],
            forecasts: [known.id: forecast(values: [(8, 0, 1, 20, 4)]), deletedID: forecast(values: [(3, 0, 1, 100, 1)])],
            forecastUpdatedAt: [known.id: base, deletedID: base]
        )
        let decoded = try JSONDecoder().decode(PersistedStoreState.self, from: JSONEncoder().encode(state))
        let knownIDs = Set(decoded.places.map(\.id))
        XCTAssertEqual(decoded.forecasts.filter { knownIDs.contains($0.key) }.count, 1)
        XCTAssertFalse(knownIDs.contains(deletedID))
    }

    func testForecastCacheReplacesSamePlaceInsteadOfAccumulatingVersions() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let first = forecast(values: [(8, 0, 1, 20, 4)])
        let second = forecast(values: [(9, 0, 1, 30, 5)])
        var cache: [UUID: [ForecastHour]] = [place.id: first]
        cache[place.id] = second
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache[place.id]?.first?.temp, 9)
    }

    func testPersistedCacheKeepsTimestampOnlyWhenForecastExists() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let state = PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [:], forecastUpdatedAt: [place.id: base], lastUpdate: base
        )
        let decoded = try JSONDecoder().decode(PersistedStoreState.self, from: JSONEncoder().encode(state))
        let consistent = decoded.forecastUpdatedAt.filter { decoded.forecasts[$0.key] != nil }
        XCTAssertTrue(consistent.isEmpty)
    }

    func testHomeSwipeOrderUsesPositionThenStarsAndDeduplicates() {
        let position = UUID()
        let star1 = UUID()
        let star2 = UUID()

        XCTAssertEqual(
            HomeSwipeSelection.orderedHomeIDs(positionID: position, favorite1ID: star1, favorite2ID: star2),
            [position, star1, star2]
        )
        XCTAssertEqual(
            HomeSwipeSelection.orderedHomeIDs(positionID: position, favorite1ID: position, favorite2ID: star2),
            [position, star2]
        )
    }

    func testFavoriteSlotAccessibilityNamesFollowSelectedLanguage() {
        XCTAssertEqual(FavoriteSlotAccessibilityCopy.label(for: 1, languageStyle: .bokmal), "Stjerne 1")
        XCTAssertEqual(FavoriteSlotAccessibilityCopy.label(for: 2, languageStyle: .bokmal), "Stjerne 2")
        XCTAssertEqual(FavoriteSlotAccessibilityCopy.label(for: 1, languageStyle: .inntrondersk), "Stjerne 1")
        XCTAssertEqual(FavoriteSlotAccessibilityCopy.label(for: 2, languageStyle: .inntrondersk), "Stjerne 2")
        XCTAssertEqual(FavoriteSlotAccessibilityCopy.label(for: 1, languageStyle: .english), "Star 1")
        XCTAssertEqual(FavoriteSlotAccessibilityCopy.label(for: 2, languageStyle: .english), "Star 2")
    }

    func testWatchFixedPlaceFallsBackWhenSavedUUIDIsMissing() {
        let selected = UUID()
        let deleted = UUID()
        let available: Set<UUID> = [selected]

        XCTAssertEqual(
            WatchPlaceSettings.resolvedPlaceID(
                source: .fixed,
                fixedPlaceID: deleted,
                selectedID: selected,
                currentLocationID: nil,
                availableIDs: available
            ),
            selected
        )
    }

    private let base = Date(timeIntervalSince1970: 2_000_000_000)

    private func makeForecast(
        through finalOffset: Int,
        startingAt start: Date? = nil,
        precipitationOffsets: Set<Int>
    ) -> [ForecastHour] {
        let firstHour = start ?? base
        return (0...finalOffset).map { offset in
            let time = firstHour.addingTimeInterval(TimeInterval(offset) * 3_600)
            let precipitation: Double = precipitationOffsets.contains(offset) ? 1 : 0
            return ForecastHour(
                time: time, temp: 8, precip: precipitation,
                wind: 1, cloud: 60, dew: 7
            )
        }
    }

    func testSharedPlaceSelectionResolvesOnlyExistingUniquePlacesAndCapsAtThree() {
        let a = Place(name: "A", lat: 1, lon: 1), b = Place(name: "B", lat: 2, lon: 2), c = Place(name: "C", lat: 3, lon: 3)
        XCTAssertEqual(SharedPlaceSelection(ids: [a.id, a.id, b.id, c.id, UUID()]).resolved(available: [a,b,c]), [a.id,b.id,c.id])
    }

    func testHomeSwipeIgnoresVerticalDragsAndDeduplicatesFavorites() {
        let current = UUID(), right = UUID(), left = UUID()
        XCTAssertNil(HomeSwipeSelection.nextIndex(
            currentID: current,
            placeIDs: [left, current, current, right],
            horizontalTranslation: 20,
            verticalTranslation: 90
        ))
        XCTAssertEqual(HomeSwipeSelection.nextIndex(
            currentID: current,
            placeIDs: [left, current, current, right],
            horizontalTranslation: -100,
            verticalTranslation: 4
        ), 2)
        XCTAssertEqual(HomeSwipeSelection.nextIndex(
            currentID: current,
            placeIDs: [left, current, current, right],
            horizontalTranslation: 100,
            verticalTranslation: 4
        ), 0)
    }

    func testHomeSwipeCanReverseBetweenManualAndPositionPlaces() {
        let manual = UUID(), position = UUID(), favorite = UUID()
        let pages = [manual, position, favorite]

        let toFavorite = HomeSwipeSelection.nextIndex(
            currentID: position,
            placeIDs: pages,
            horizontalTranslation: -120,
            verticalTranslation: 0
        )
        XCTAssertEqual(toFavorite, 2)
        XCTAssertEqual(HomeSwipeSelection.nextIndex(
            currentID: pages[toFavorite!],
            placeIDs: pages,
            horizontalTranslation: 120,
            verticalTranslation: 0
        ), 1)
    }

    func testHomeSwipeDoesNotWrapPastFirstOrLastPlace() {
        let first = UUID(), middle = UUID(), last = UUID()
        let pages = [first, middle, last]

        XCTAssertNil(HomeSwipeSelection.nextIndex(
            currentID: first,
            placeIDs: pages,
            horizontalTranslation: 120,
            verticalTranslation: 0
        ))
        XCTAssertNil(HomeSwipeSelection.nextIndex(
            currentID: last,
            placeIDs: pages,
            horizontalTranslation: -120,
            verticalTranslation: 0
        ))
    }

    func testLateCurrentLocationDoesNotReplaceManualSelection() {
        let initial = UUID()
        XCTAssertTrue(Store.shouldApplyCurrentLocation(selectionAtRequestStart: initial, currentSelection: initial))
        XCTAssertFalse(Store.shouldApplyCurrentLocation(selectionAtRequestStart: initial, currentSelection: UUID()))
        XCTAssertFalse(Store.shouldApplyCurrentLocation(selectionAtRequestStart: nil, currentSelection: initial))
    }

    func testCurrentLocationSelectionRequiresFreshAndPreciseFix() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let selection = UUID()
        func fix(age: TimeInterval, accuracy: CLLocationAccuracy = 50) -> CLLocation {
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 64.4, longitude: 11.5),
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: 5,
                course: -1,
                speed: -1,
                timestamp: now.addingTimeInterval(-age)
            )
        }

        XCTAssertTrue(Store.shouldApplyCurrentLocationFix(
            selectionAtRequestStart: selection, currentSelection: selection,
            location: fix(age: 30), now: now
        ))
        XCTAssertTrue(LocationFixPolicy.accepts(fix(age: 120, accuracy: 100), now: now))
        XCTAssertFalse(LocationFixPolicy.accepts(fix(age: 120.01), now: now))
        XCTAssertTrue(LocationFixPolicy.accepts(fix(age: -60), now: now))
        XCTAssertFalse(LocationFixPolicy.accepts(fix(age: -60.01), now: now))
        XCTAssertFalse(LocationFixPolicy.accepts(fix(age: 0, accuracy: 100.01), now: now))
        XCTAssertFalse(LocationFixPolicy.accepts(fix(age: 0, accuracy: -1), now: now))

        let manuallySelectedPlace = UUID()
        XCTAssertFalse(Store.shouldApplyCurrentLocationFix(
            selectionAtRequestStart: selection, currentSelection: manuallySelectedPlace,
            location: fix(age: 30), now: now
        ))
        XCTAssertFalse(Store.shouldApplyCurrentLocationFix(
            selectionAtRequestStart: selection, currentSelection: selection,
            location: fix(age: 121), now: now
        ))
    }

    func testLocationBatchSelectsNewestAcceptedFixInsteadOfRejectingBatchTail() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let acceptable = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 64.4, longitude: 11.5),
            altitude: 0, horizontalAccuracy: 50, verticalAccuracy: 5,
            course: -1, speed: -1, timestamp: now.addingTimeInterval(-30)
        )
        let tooInaccurate = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 64.5, longitude: 11.6),
            altitude: 0, horizontalAccuracy: 150, verticalAccuracy: 5,
            course: -1, speed: -1, timestamp: now.addingTimeInterval(-10)
        )

        XCTAssertEqual(
            LocationFixPolicy.newestAccepted(in: [acceptable, tooInaccurate], now: now)?.timestamp,
            acceptable.timestamp
        )
        XCTAssertNil(LocationFixPolicy.newestAccepted(in: [tooInaccurate], now: now))
    }

    func testStartupForecastRefreshRunsWhileGPSNameResolutionIsDelayed() async {
        let persistenceKey = "varsel.test.startup-delayed-gps.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let savedPlace = Place(name: "Hjem", lat: 64.4, lon: 11.5)
        let gpsPlace = Place(name: "Min posisjon", lat: 63.4, lon: 10.4)
        let forecast = makeForecast(through: 5)
        let store = Store(
            forecastFetcher: { _, _ in forecast }, persistenceKey: persistenceKey,
            notificationRescheduler: { _, _, _, _, _ in
                NotificationScheduleResult(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil)
            }
        )
        store.places = [savedPlace]
        store.select(savedPlace)
        var locationSelectionFinished = false
        let initialRefreshFinished = expectation(description: "Initial saved-place forecast finishes before geocoding")
        var backgroundRefreshWasScheduled = false
        var selectedRefreshFinished = false
        var notificationPermissionRequested = false

        let startup = Task { @MainActor in
            await StartupWeatherBootstrap.run(
                selectCurrentLocation: {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    store.places.append(gpsPlace)
                    store.select(gpsPlace, fromCurrentLocation: true)
                    locationSelectionFinished = true
                },
                refreshInitialForecast: {
                    _ = await store.refreshAll()
                    initialRefreshFinished.fulfill()
                },
                scheduleBackgroundRefresh: { backgroundRefreshWasScheduled = true },
                requestNotificationsPermission: {
                    XCTAssertTrue(locationSelectionFinished)
                    notificationPermissionRequested = true
                },
                refreshSelectedForecastIfNeeded: {
                    _ = await store.refreshSelectedForecastIfNeeded()
                    selectedRefreshFinished = true
                }
            )
        }

        await fulfillment(of: [initialRefreshFinished], timeout: 2)
        XCTAssertTrue(backgroundRefreshWasScheduled)
        XCTAssertFalse(locationSelectionFinished)
        XCTAssertFalse(notificationPermissionRequested)
        XCTAssertFalse(selectedRefreshFinished)
        await startup.value

        XCTAssertTrue(selectedRefreshFinished)
        XCTAssertTrue(notificationPermissionRequested)
        XCTAssertNotNil(store.forecasts[gpsPlace.id])
    }

    func testStartupForecastFallsBackToSavedPlaceWhenGPSLookupFails() async {
        let persistenceKey = "varsel.test.startup-failed-gps.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let savedPlace = Place(name: "Hjem", lat: 64.4, lon: 11.5)
        let forecast = makeForecast(through: 5)
        let store = Store(
            forecastFetcher: { _, _ in forecast }, persistenceKey: persistenceKey,
            notificationRescheduler: { _, _, _, _, _ in
                NotificationScheduleResult(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil)
            }
        )
        store.places = [savedPlace]
        store.select(savedPlace)
        var initialRefreshFinished = false
        var selectedRefreshFinished = false
        var notificationPermissionRequested = false

        await StartupWeatherBootstrap.run(
            selectCurrentLocation: { /* Models denied GPS access or a failed geocoder. */ },
            refreshInitialForecast: {
                _ = await store.refreshAll()
                initialRefreshFinished = true
            },
            scheduleBackgroundRefresh: {},
            requestNotificationsPermission: {
                XCTAssertTrue(initialRefreshFinished)
                notificationPermissionRequested = true
            },
            refreshSelectedForecastIfNeeded: {
                _ = await store.refreshSelectedForecastIfNeeded()
                selectedRefreshFinished = true
            }
        )

        XCTAssertTrue(initialRefreshFinished)
        XCTAssertTrue(notificationPermissionRequested)
        XCTAssertTrue(selectedRefreshFinished)
        XCTAssertNotNil(store.forecasts[savedPlace.id])
    }

    @MainActor
    func testNewLocationCourseDoesNotChangeSelectedPlaceOrForecast() {
        let persistenceKey = "varsel.test.location-course.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let position = Place(name: "Klinga", lat: 64.4094, lon: 11.4779)
        let favorite = Place(name: "Hornburu", lat: 64.1991, lon: 11.4036)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 40, dew: 4)
        let store = Store(persistenceKey: persistenceKey)
        store.places = [position, favorite]
        store.forecasts = [position.id: [hour]]
        store.select(position, fromCurrentLocation: true)

        let fix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 95, speed: 2, timestamp: Date()
        )
        store.updateCurrentLocationCourse(from: fix)

        XCTAssertEqual(store.currentLocationCourse, 95)
        XCTAssertEqual(store.selectedID, position.id)
        XCTAssertEqual(store.selectedForecast, [hour])
        store.select(favorite)
        store.select(position, fromCurrentLocation: true)
        XCTAssertEqual(store.currentLocationCourse, 95)
        XCTAssertEqual(store.selectedForecast, [hour])
    }

    func testCurrentLocationReusesNearbySavedPlaceInsteadOfCreatingDuplicate() {
        let klinga = Place(name: "Klinga", lat: 64.4094, lon: 11.4779)
        let far = Place(name: "Oslo", lat: 59.9139, lon: 10.7522)
        let location = CLLocation(latitude: 64.4095, longitude: 11.4780)
        XCTAssertEqual(Store.nearestSavedPlace(in: [klinga, far], to: location)?.id, klinga.id)
        XCTAssertNil(Store.nearestSavedPlace(in: [klinga], to: CLLocation(latitude: 60, longitude: 10)))
    }

    func testRotatingStatusSummaryKeepsOneEntryPerWeatherType() {
        let rainA = WeatherStatus(ruleID: UUID(), type: .regn, text: "Regn", eventAt: base, isNow: false)
        let rainB = WeatherStatus(ruleID: UUID(), type: .regn, text: "Regn senere", eventAt: base.addingTimeInterval(3_600), isNow: false)
        let wind = WeatherStatus(ruleID: UUID(), type: .vind, text: "Vind", eventAt: base, isNow: false)
        XCTAssertEqual(WeatherStatus.uniqueByType([rainA, rainB, wind]), [rainA, wind])
    }

    func testExpandedPushAlertsStayScopedToTheirPlace() {
        let klinga = UUID(), cabin = UUID()
        var expansion = PlaceExpansionState()

        expansion.toggle(klinga)
        XCTAssertEqual(expansion.expandedPlaceID, klinga)
        XCTAssertNotEqual(expansion.expandedPlaceID, cabin)

        expansion.toggle(cabin)
        XCTAssertNotEqual(expansion.expandedPlaceID, klinga)
        XCTAssertEqual(expansion.expandedPlaceID, cabin)

        expansion.toggle(cabin)
        XCTAssertNil(expansion.expandedPlaceID)
    }

    func testHomeSwipeOrderKeepsCurrentPlaceBetweenDistinctFavorites() {
        let left = UUID(), current = UUID(), right = UUID()
        XCTAssertEqual(
            HomeSwipeSelection.orderedIDs(leftID: left, currentID: current, rightID: right),
            [left, current, right]
        )
        XCTAssertEqual(
            HomeSwipeSelection.orderedIDs(leftID: left, currentID: left, rightID: right),
            [left, right]
        )
    }

    func testWeatherGlanceDropsStaleNowStatusAndKeepsOnePerType() {
        let stale = WeatherStatus(ruleID: UUID(), type: .regn, text: "Regn nå.", eventAt: base.addingTimeInterval(-2 * 3_600), isNow: true)
        let current = WeatherStatus(ruleID: UUID(), type: .regn, text: "Regn nå.", eventAt: base.addingTimeInterval(-10 * 60), isNow: true)
        let snow = WeatherStatus(ruleID: UUID(), type: .sno, text: "Snø om en time.", eventAt: base.addingTimeInterval(3_600), isNow: false)
        let tooFar = WeatherStatus(ruleID: UUID(), type: .dugg, text: "Dugg i morgen.", eventAt: base.addingTimeInterval(13 * 3_600), isNow: false)

        let glance = WeatherGlance.upcoming([stale, snow, current, tooFar], now: base)

        XCTAssertEqual(glance.map(\.type), [.regn, .sno])
        XCTAssertEqual(glance.first?.eventAt, current.eventAt)
    }

    func testWatchTransferCarriesLanguageAndSeparator() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 20, dew: 3)
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base, languageStyle: .inntrondersk, textSeparator: .dash)
        let transfer = WatchWeatherTransfer(snapshot: snapshot, sentAt: base)
        let decoded = try JSONDecoder().decode(WatchWeatherTransfer.self, from: JSONEncoder().encode(transfer))
        XCTAssertEqual(decoded.snapshot?.languageStyle, .inntrondersk)
        XCTAssertEqual(decoded.snapshot?.textSeparator, .dash)
        XCTAssertEqual(
            decoded.snapshot?.localized("Duggfall natt til onsdag kl. 05"),
            "Doggfall natt te onsda'n — kl. 05"
        )
    }

    func testWidgetSnapshotUnknownLanguageKeepsWeatherDataAndUsesSafeFallback() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let snapshot = WidgetWeatherSnapshot(
            place: place,
            forecast: [ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 20, dew: 3)],
            updatedAt: base,
            languageStyle: .english,
            textSeparator: .dash
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object["languageStyle"] = "esperanto"
        object["textSeparator"] = "unknown-separator"
        let data = try JSONSerialization.data(withJSONObject: object)

        let restored = try JSONDecoder().decode(WidgetWeatherSnapshot.self, from: data)

        XCTAssertEqual(restored.place.displayName, "Klinga")
        XCTAssertEqual(restored.forecast.first?.temp, 8)
        XCTAssertEqual(restored.languageStyle, .bokmal)
        XCTAssertNil(restored.textSeparator)
        XCTAssertEqual(restored.localized("Regn i morgen"), "Regn i morgen")
    }

    func testWidgetPlaceSummaryKeepsPrepositionForSharedPlaces() {
        let summary = WidgetPlaceSummary(id: UUID(), name: "Namsos", preposition: .nerri)
        XCTAssertEqual(summary.label, "nerri Namsos")
    }

    func testCurrentLocationNameComparisonIsDiacriticAndCaseInsensitive() {
        XCTAssertEqual("Ålesund".compare("åLESUND", options: [.caseInsensitive, .diacriticInsensitive]), .orderedSame)
    }

    func testCurrentLocationBadgeIsNotPersistedAcrossRestart() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.5)
        let state = PersistedStoreState(places: [place], selectedID: place.id, log: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])

        XCTAssertNil(object["selectionIsCurrentLocation"])
    }

    @MainActor
    func testManualNotificationSelectionClearsCurrentLocationBadge() {
        let store = Store.shared
        guard let first = store.places.first else { return }
        let second = store.places.dropFirst().first ?? first
        let original = store.selectedID
        defer { store.selectedID = original }

        store.select(first, fromCurrentLocation: true)
        XCTAssertTrue(store.selectionIsCurrentLocation)
        store.select(second)
        XCTAssertFalse(store.selectionIsCurrentLocation)
    }

    func testPlacePersistsSecondSunDisplayThreshold() throws {
        var place = Place(name: "Selbu", lat: 63, lon: 11)
        place.displaySunThreshold = 10
        place.displaySunThreshold2 = 20
        let decoded = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(place))
        XCTAssertEqual(decoded.displaySunThreshold2, 20)
        XCTAssertEqual(decoded.resolvedDisplaySunThreshold2, 20)
        place.displaySunThreshold2 = 99
        XCTAssertEqual(place.resolvedDisplaySunThreshold2, 90)
        XCTAssertEqual(AlertType.sol.range.upperBound, 90)
        place.displaySunThreshold = 45
        place.displaySunThreshold2 = 30
        XCTAssertEqual(place.resolvedDisplaySunThreshold2, 45)
        place.displaySunThreshold2 = nil
        XCTAssertEqual(place.resolvedDisplaySunThreshold2, 55)
    }

    func testDecodedRuleThresholdsAreClampedToTypeRangeAndNonFiniteValuesUseDefaults() throws {
        for type in AlertType.allCases {
            XCTAssertEqual(type.normalizedThreshold(type.range.lowerBound - 1), type.range.lowerBound)
            XCTAssertEqual(type.normalizedThreshold(type.range.upperBound + 1), type.range.upperBound)
            XCTAssertEqual(type.normalizedThreshold(.nan), type.defaultThreshold)
            XCTAssertEqual(type.normalizedThreshold(.infinity), type.defaultThreshold)
            XCTAssertEqual(type.normalizedThreshold(-.infinity), type.defaultThreshold)
        }

        let tooHigh = try JSONDecoder().decode(Rule.self, from: Data(#"{"type":"regn","threshold":100}"#.utf8))
        let tooLow = try JSONDecoder().decode(Rule.self, from: Data(#"{"type":"vind","threshold":-100}"#.utf8))
        let legacyWind = try JSONDecoder().decode(Rule.self, from: Data(#"{"type":"vind"}"#.utf8))
        XCTAssertEqual(tooHigh.threshold, AlertType.regn.range.upperBound)
        XCTAssertEqual(tooLow.threshold, AlertType.vind.range.lowerBound)
        XCTAssertEqual(legacyWind.threshold, 10, "Historical wind default remains unchanged")
    }

    func testDecodedRuleScheduleFieldsStayWithinEditorDomains() throws {
        let corrupt = Data(#"{"type":"frost","previousDayNotificationHour":24,"previousDayNotificationMinute":-10,"notificationWeekday":7,"notificationDayOffset":99,"days":[-1,0,6,7],"quietFrom":0,"quietTo":24,"activeFromHour":-1,"activeToHour":24}"#.utf8)
        let rule = try JSONDecoder().decode(Rule.self, from: corrupt)

        XCTAssertNil(rule.previousDayNotificationHour)
        XCTAssertEqual(rule.previousDayNotificationMinute, 0)
        XCTAssertNil(rule.notificationWeekday)
        XCTAssertNil(rule.notificationDayOffset)
        XCTAssertEqual(rule.days, [0, 6])
        XCTAssertEqual(rule.quietFrom, 18)
        XCTAssertEqual(rule.quietTo, 10)
        XCTAssertEqual(rule.activeFromHour, 0)
        XCTAssertEqual(rule.activeToHour, 23)

        let valid = Data(#"{"type":"frost","previousDayNotificationHour":23,"previousDayNotificationMinute":59,"notificationWeekday":6,"days":[0,6],"quietFrom":23,"quietTo":10,"activeFromHour":23,"activeToHour":0}"#.utf8)
        let boundary = try JSONDecoder().decode(Rule.self, from: valid)
        XCTAssertEqual(boundary.previousDayNotificationHour, 23)
        XCTAssertEqual(boundary.previousDayNotificationMinute, 59)
        XCTAssertEqual(boundary.notificationWeekday, 6)
        XCTAssertEqual(boundary.days, [0, 6])
        XCTAssertEqual(boundary.quietFrom, 23)
        XCTAssertEqual(boundary.quietTo, 10)
        XCTAssertEqual(boundary.activeFromHour, 23)
        XCTAssertEqual(boundary.activeToHour, 0)
    }

    func testMalformedPlaceSnapshotUsesSafeDefaults() throws {
        let data = Data(#"{"name":" ","lat":64,"lon":11,"rules":[{"type":"vind","threshold":"bad"}]}"#.utf8)
        let place = try JSONDecoder().decode(Place.self, from: data)
        XCTAssertEqual(place.name, "Ukjent sted")
        XCTAssertEqual(place.lat, 64)
        XCTAssertEqual(place.lon, 11)
        XCTAssertTrue(place.rules.isEmpty)
    }

    func testPlaceDecodingRejectsOutOfRangeCoordinates() {
        let invalidLatitude = Data(#"{"name":"Ugyldig","lat":91,"lon":11}"#.utf8)
        let invalidLongitude = Data(#"{"name":"Ugyldig","lat":64,"lon":181}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(Place.self, from: invalidLatitude))
        XCTAssertThrowsError(try JSONDecoder().decode(Place.self, from: invalidLongitude))
        XCTAssertTrue(Place.coordinatesAreValid(latitude: -90, longitude: -180))
        XCTAssertTrue(Place.coordinatesAreValid(latitude: 90, longitude: 180))
        XCTAssertFalse(Place.coordinatesAreValid(latitude: .nan, longitude: 11))
        XCTAssertFalse(Place.coordinatesAreValid(latitude: 64, longitude: .infinity))
    }

    func testPersistedStateSkipsOnlyPlacesWithInvalidCoordinates() throws {
        let valid = Place(name: "Klinga", lat: 64, lon: 11)
        let invalid = Place(name: "Ugyldig", lat: 91, lon: 11)
        let state = PersistedStoreState(places: [valid, invalid], selectedID: invalid.id, log: [])

        let restored = try JSONDecoder().decode(PersistedStoreState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(restored.places.map(\.id), [valid.id])
        XCTAssertEqual(restored.selectedID, valid.id)
    }

    func testConfigurationImportSkipsPlaceWithInvalidCoordinates() throws {
        let invalid = Place(name: "Ugyldig", lat: 91, lon: 11)
        let valid = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let source = WeatherConfigurationExport(
            places: [invalid, valid], selectedPlaceID: invalid.id, alertLanguageStyle: .bokmal
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(source)

        let imported = try WeatherConfigurationDocument(data: data).configuration

        XCTAssertEqual(imported.places.map(\.id), [valid.id])
        XCTAssertEqual(imported.selectedPlaceID, valid.id)
    }

    @MainActor
    func testForecastLocationsIgnorePlacesWithInvalidCoordinates() {
        let invalid = Place(name: "Ugyldig", lat: 91, lon: 11)
        let valid = Place(name: "Klinga", lat: 64, lon: 11)

        XCTAssertEqual(Store.forecastLocations(in: [invalid, valid]), [ForecastLocation(place: valid)])
    }

    @MainActor
    func testStoreRejectsInvalidPlacesBeforeSavingOrFetching() async {
        let persistenceKey = "test.invalidPlace.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        let invalid = Place(name: "Ugyldig", lat: 91, lon: 11)
        let originalIDs = Set(store.places.map(\.id))

        await store.add(invalid)
        store.update(invalid)

        XCTAssertEqual(Set(store.places.map(\.id)), originalIDs)
    }

    func testPersistedStateWithoutSelectionRemainsUsable() throws {
        let state = try JSONDecoder().decode(PersistedStoreState.self, from: Data(#"{"places":[{"name":"Klinga","lat":64,"lon":11}],"log":[]}"#.utf8))
        XCTAssertEqual(state.places.count, 1)
        XCTAssertNil(state.selectedID)
        XCTAssertTrue(state.log.isEmpty)
    }

    func testTemperatureRuleSupportsBothDirectionsAndLegacyDefaultsBelow() throws {
        var high = Rule(type: .temperatur)
        high.threshold = 20
        high.temperatureDirection = .above
        var warm = ForecastHour(time: base, temp: 21, precip: 0, wind: 1, cloud: 0, dew: 10)
        XCTAssertTrue(high.matches(warm))
        warm.temp = 20
        XCTAssertFalse(high.matches(warm))
        let legacy = try JSONDecoder().decode(Rule.self, from: Data(#"{"type":"temperatur","threshold":10}"#.utf8))
        XCTAssertEqual(legacy.temperatureDirection, .below)
    }

    func testRuleDecodingPreservesHistoricalDefaultsAndClampsSchedulingValues() throws {
        let legacy = try JSONDecoder().decode(
            Rule.self,
            from: Data(#"{"type":"regn","threshold":0.5}"#.utf8)
        )
        XCTAssertEqual(legacy.durationHours, 4)
        XCTAssertEqual(legacy.leadMinutes, 120)
        XCTAssertEqual(legacy.count, 2)
        XCTAssertEqual(legacy.intervalMinutes, 30)

        let supported = try JSONDecoder().decode(
            Rule.self,
            from: Data(#"{"type":"regn","threshold":0.5,"durationHours":12,"leadMinutes":1440,"count":10,"intervalMinutes":120,"repeatsEnabled":true}"#.utf8)
        )
        XCTAssertEqual(supported.durationHours, 12)
        XCTAssertEqual(supported.leadMinutes, 1440)
        XCTAssertEqual(supported.alertCount, 10)
        XCTAssertEqual(supported.intervalMinutes, 120)

        let oversized = try JSONDecoder().decode(
            Rule.self,
            from: Data(#"{"type":"regn","threshold":0.5,"durationHours":999,"leadMinutes":999999,"count":1000000,"intervalMinutes":999999,"repeatsEnabled":true}"#.utf8)
        )
        XCTAssertEqual(oversized.durationHours, 12)
        XCTAssertEqual(oversized.leadMinutes, 1440)
        XCTAssertEqual(oversized.alertCount, 10)
        XCTAssertEqual(oversized.intervalMinutes, 120)

        var directlyCreated = Rule(type: .regn)
        directlyCreated.repeatsEnabled = true
        directlyCreated.count = Int.max
        XCTAssertEqual(directlyCreated.alertCount, 10)

        let undersized = try JSONDecoder().decode(
            Rule.self,
            from: Data(#"{"type":"regn","threshold":0.5,"durationHours":-99,"leadMinutes":-999999,"count":-100,"intervalMinutes":-100,"repeatsEnabled":true}"#.utf8)
        )
        XCTAssertEqual(undersized.durationHours, 1)
        XCTAssertEqual(undersized.leadMinutes, 15)
        XCTAssertEqual(undersized.alertCount, 2)
        XCTAssertEqual(undersized.intervalMinutes, 10)
    }

    func testTemperatureRuleDoesNotMatchExactThresholdInEitherDirection() {
        let sample = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 0, dew: 5)

        for direction in Rule.TemperatureDirection.allCases {
            var rule = Rule(type: .temperatur)
            rule.threshold = 10
            rule.temperatureDirection = direction

            XCTAssertFalse(rule.matches(sample), "\(direction.label) must be strict at its threshold.")
        }
    }

    func testTemperatureRuleRejectsNonFiniteMeasurementsInEitherDirection() {
        for temperature in [Double.nan, .infinity, -.infinity] {
            let sample = ForecastHour(
                time: base, temp: temperature, precip: 0, wind: 1, cloud: 0, dew: 5
            )
            for direction in Rule.TemperatureDirection.allCases {
                var rule = Rule(type: .temperatur)
                rule.threshold = 10
                rule.temperatureDirection = direction
                XCTAssertFalse(rule.matches(sample), "\(direction.label) must reject \(temperature).")
            }
        }
    }

    func testTemperatureRuleRejectsNonFiniteThresholdsWithValidMeasurement() {
        let sample = ForecastHour(time: base, temp: 20, precip: 0, wind: 1, cloud: 0, dew: 5)

        for threshold in [Double.nan, .infinity, -.infinity] {
            for direction in Rule.TemperatureDirection.allCases {
                var rule = Rule(type: .temperatur)
                rule.threshold = threshold
                rule.temperatureDirection = direction

                XCTAssertFalse(
                    rule.matches(sample),
                    "\(direction.label) must reject the non-finite threshold \(threshold)."
                )
            }
        }
    }

    func testDisplayThresholdsAndDialectSeparator() throws {
        XCTAssertEqual(WeatherLanguage.text("om 2 timer", style: .inntrondersk), "om 2 tima")
        XCTAssertEqual(WeatherLanguage.text("om tre timer", style: .inntrondersk), "om tre tima")
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.displayDewThreshold = 2
        place.displaySunThreshold = 35
        place.displayGustThreshold = 11
        let copy = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(place))
        XCTAssertTrue(copy.rules.isEmpty)
        XCTAssertEqual(copy.rulesForDisplay.first { $0.type == .vind }?.threshold, 11)
        XCTAssertEqual(copy.rulesForDisplay.first { $0.type == .dugg }?.threshold, 2)
        XCTAssertEqual(copy.rulesForDisplay.first { $0.type == .sol }?.threshold, 35)
        XCTAssertEqual(WeatherLanguage.text("Under 10° nå", style: .inntrondersk, separator: .dash), "D e Under 10°!")
        XCTAssertEqual(WeatherLanguage.text("Duggfall natt til onsdag kl. 05", style: .inntrondersk, separator: .dash), "Doggfall natt te onsda'n — kl. 05")
        XCTAssertEqual(WeatherTextSeparator.comma.format("onsdag kl. 05"), "onsdag, kl. 05")
        XCTAssertEqual(WeatherTextSeparator.bullet.format("onsdag kl. 05"), "onsdag • kl. 05")
    }

    func testLanguageCatalogIsBundledAndDoesNotTranslateInsertedPlaceholders() {
        XCTAssertFalse(LanguageCatalog.entries.isEmpty)
        XCTAssertEqual(LanguageCatalog.value("weekday.monday", language: "tr", fallback: "MISSING"), "manda'n")
        XCTAssertEqual(LanguageCatalog.value("app.name", language: "en", fallback: "MISSING"), "It’s Weather")
        XCTAssertEqual(LanguageCatalog.value("push.title", language: "nb", fallback: "MISSING", arguments: ["sted": "på {vaertype}", "vaertype": "Regn"]), "D bli Regn! på {vaertype}")
    }
    func testWeatherBandDisplayThresholdsOverridePushRulesWithoutMutatingThem() throws {
        var pushWind = Rule(type: .vind)
        pushWind.threshold = 18
        var pushDew = Rule(type: .dugg)
        pushDew.threshold = 2.5
        let forecast = ForecastHour(
            time: base, temp: 8, precip: 0, wind: 5, cloud: 50, dew: 4,
            gust: 9
        )

        let displayRules = WeatherBandDisplayRuleOverrides.applying(
            to: [pushWind, pushDew], dewThreshold: 1, gustThreshold: 8
        )

        let displayWind = try XCTUnwrap(displayRules.first { $0.type == .vind })
        let displayDew = try XCTUnwrap(displayRules.first { $0.type == .dugg })
        XCTAssertEqual(displayWind.threshold, 8)
        XCTAssertTrue(displayWind.matches(forecast))
        XCTAssertEqual(displayDew.threshold, 1)
        XCTAssertFalse(displayDew.matches(forecast))
        XCTAssertEqual(pushWind.threshold, 18)
        XCTAssertEqual(pushDew.threshold, 2.5)
    }

    func testLanguageCatalogIsBundledAndDoesNotTranslateInsertedPlaceholders() {
        XCTAssertFalse(LanguageCatalog.entries.isEmpty)
        XCTAssertEqual(LanguageCatalog.value("weekday.monday", language: "tr", fallback: "MISSING"), "manda'n")
        XCTAssertEqual(LanguageCatalog.value("app.name", language: "en", fallback: "MISSING"), "It’s Weather")
        XCTAssertEqual(LanguageCatalog.value("push.title", language: "nb", fallback: "MISSING", arguments: ["sted": "på {vaertype}", "vaertype": "Regn"]), "D bli Regn! på {vaertype}")
    }

    func testNotificationCopyCatalogHasAllLanguagesForEveryUsedKey() {
        for key in NotificationCopy.catalogKeys {
            for language in ["nb", "tr", "en"] {
                XCTAssertFalse(
                    LanguageCatalog.entries[key]?[language]?.isEmpty ?? true,
                    "Mangler \(language)-tekst for \(key)"
                )
            }
        }
    }

    func testEnglishLanguageStyleUsesCatalogForPushAndTimeText() {
        let rain = Rule(type: .regn)
        XCTAssertEqual(AlertLanguageStyle.persisted("en"), .english)
        XCTAssertEqual(AppCopy.name(languageStyle: .english), "It’s Weather")
        XCTAssertEqual(
            NotificationCopy.title(for: rain, placeName: "in Oslo", languageStyle: .english),
            "It’s Raining! in Oslo"
        )
        XCTAssertEqual(
            WeatherLanguage.text("Regn i morgen kl. 07", style: .english),
            "Rain tomorrow at 07"
        )
        XCTAssertEqual(
            WeatherLanguage.text("Opptil 0,9 mm på Klinga — Klipp gresset!", style: .english),
            "Up to 0,9 mm på Klinga — Klipp gresset!"
        )
        var temperature = Rule(type: .temperatur)
        temperature.threshold = 10
        XCTAssertEqual(
            NotificationCopy.title(for: temperature, placeName: "in Oslo", languageStyle: .english),
            "It’s Below 10°! in Oslo"
        )
        temperature.temperatureDirection = .above
        temperature.threshold = 20
        XCTAssertEqual(
            NotificationCopy.title(for: temperature, placeName: "in Oslo", languageStyle: .english),
            "It’s Above 20°! in Oslo"
        )
    }

    func testSharedSnapshotPreservesDialectDuringWatchRefresh() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 0, dew: 0)
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base, languageStyle: .inntrondersk)
        let restored = try JSONDecoder().decode(WidgetWeatherSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.localized("Regn denne timen"), "Regn herre tima")
        let revision = UUID()
        let refreshed = try XCTUnwrap(restored.refreshed(with: [hour], at: base, requestRevision: revision, currentRevision: revision))
        XCTAssertEqual(refreshed.localized("mandag"), "manda'n")
        let legacy = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base)
        let old = try JSONDecoder().decode(WidgetWeatherSnapshot.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(old.localized("mandag"), "mandag")
    }

    func testSharedSnapshotUnknownLanguageFallsBackToBokmal() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 0, dew: 0)
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object["languageStyle"] = "trondelag-humor"
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WidgetWeatherSnapshot.self, from: data)
        XCTAssertEqual(decoded.languageStyle, .bokmal)
        XCTAssertEqual(decoded.localized("Regn nå."), "Regn nå.")
        XCTAssertEqual(decoded.forecast.first?.temp, 10)
    }

    func testSharedSnapshotRefreshKeepsLanguageAndSeparator() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 0, dew: 0)
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base,
                                              languageStyle: .inntrondersk, textSeparator: .dash)
        let revision = UUID()
        let refreshed = try XCTUnwrap(snapshot.refreshed(with: [hour], at: base.addingTimeInterval(60), requestRevision: revision, currentRevision: revision))
        XCTAssertEqual(refreshed.languageStyle, .inntrondersk)
        XCTAssertEqual(refreshed.textSeparator, .dash)
        XCTAssertEqual(refreshed.localized("Duggfall i morgen kl. 07."), "Doggfall i mårrå — kl. 07.")
    }

    func testSharedSnapshotRejectsEmptyRefreshAndKeepsCachedForecast() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 7, precip: 0, wind: 2, cloud: 40, dew: 3)
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base)
        let revision = UUID()
        XCTAssertNil(snapshot.refreshed(with: [], at: base.addingTimeInterval(60), requestRevision: revision, currentRevision: revision))
        XCTAssertEqual(snapshot.forecast, [hour])
        XCTAssertEqual(snapshot.updatedAt, base)
    }

    func testGustThresholdNeverFallsBackToMeanWind() {
        var hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 20, cloud: 0, dew: 0)
        XCTAssertFalse(AlertType.vind.matches(hour, threshold: 9))
        hour.gust = 8.9
        XCTAssertFalse(AlertType.vind.matches(hour, threshold: 9))
        hour.gust = 9
        XCTAssertTrue(AlertType.vind.matches(hour, threshold: 9))
        hour.gust = nil
        XCTAssertFalse(AlertType.vind.matches(hour, threshold: 9))
        hour.gust = .nan
        XCTAssertFalse(AlertType.vind.matches(hour, threshold: 9))
        hour.gust = .infinity
        XCTAssertFalse(AlertType.vind.matches(hour, threshold: 9))
    }

    func testRainSnowIconUsesSameOneDegreeBoundaryAsRules() {
        let snow = ForecastHour(time: base, temp: 1, precip: 0.5, wind: 1, cloud: 100, dew: 0)
        let rain = ForecastHour(time: base.addingTimeInterval(3_600), temp: 1.1, precip: 0.5, wind: 1, cloud: 100, dew: 0)
        XCTAssertEqual(forecastSymbol(snow), "cloud.snow.fill")
        XCTAssertEqual(forecastSymbol(rain), "cloud.rain.fill")
        XCTAssertTrue(AlertType.sno.matches(snow, threshold: 0.1))
        XCTAssertTrue(AlertType.regn.matches(rain, threshold: 0.1))
        let fog = ForecastHour(time: base.addingTimeInterval(7_200), temp: 8, precip: 0, wind: 1, cloud: 95, dew: 7, fog: 80)
        XCTAssertEqual(forecastSymbol(fog), "cloud.fog.fill")
        XCTAssertEqual(AlertType.frost.systemImage, "snowflake")
    }

    func testForecastSymbolMatchesConditionClassificationAtEveryWeatherBoundary() {
        let cases: [(ForecastHour, String)] = [
            (ForecastHour(time: base, temp: 8, precip: 0.099, wind: 1, cloud: 80, dew: 5), "cloud.fill"),
            (ForecastHour(time: base, temp: 8, precip: 0.1, wind: 1, cloud: 80, dew: 5), "cloud.rain.fill"),
            (ForecastHour(time: base, temp: 1, precip: 0.1, wind: 1, cloud: 80, dew: 0), "cloud.snow.fill"),
            (ForecastHour(time: base, temp: 1.01, precip: 0.1, wind: 1, cloud: 80, dew: 0), "cloud.rain.fill"),
            (ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 80, dew: 5, fog: 49.9), "cloud.fill"),
            (ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 80, dew: 5, fog: 50), "cloud.fog.fill"),
            (ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 20, dew: 5), "sun.max.fill"),
            (ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 20.1, dew: 5), "cloud.sun.fill"),
            (ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 65, dew: 5), "cloud.sun.fill"),
            (ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 65.1, dew: 5), "cloud.fill")
        ]

        for (hour, expectedSymbol) in cases {
            let condition = CurrentWeatherCondition.resolve(
                hour,
                precipitationIsFalling: hour.precipitationRate >= 0.1
            )
            XCTAssertEqual(forecastSymbol(hour), expectedSymbol)
            XCTAssertEqual(condition.systemImage, expectedSymbol)
        }
    }

    func testCurrentWeatherCloudCoverThresholdsOnBothSides() {
        let cases: [(Double, CurrentWeatherCondition)] = [
            (19.9, .clear),
            (20, .clear),
            (20.1, .partlyCloudy),
            (64.9, .partlyCloudy),
            (65, .partlyCloudy),
            (65.1, .cloudy)
        ]

        for (cloud, expected) in cases {
            let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: cloud, dew: 5)
            XCTAssertEqual(CurrentWeatherCondition.resolve(hour), expected, "Unexpected condition at cloud cover \(cloud)%")
        }
    }

    func testForecastSymbolChangesFromSunToNightAtKlingaSunset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 12, day: 21, hour: 12)))
        var dayStart = date
        var nightEnd = try XCTUnwrap(calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date))
        XCTAssertTrue(SolarCycle.isDaylight(dayStart, latitude: 64.46, longitude: 11.50, calendar: calendar))
        XCTAssertFalse(SolarCycle.isDaylight(nightEnd, latitude: 64.46, longitude: 11.50, calendar: calendar))

        for _ in 0..<40 {
            let middle = dayStart.addingTimeInterval(nightEnd.timeIntervalSince(dayStart) / 2)
            if SolarCycle.isDaylight(middle, latitude: 64.46, longitude: 11.50, calendar: calendar) {
                dayStart = middle
            } else {
                nightEnd = middle
            }
        }

        let clearBeforeSunset = ForecastHour(time: dayStart, temp: 4, precip: 0, wind: 1, cloud: 10, dew: 2)
        let clearAfterSunset = ForecastHour(time: nightEnd, temp: 3, precip: 0, wind: 1, cloud: 10, dew: 2)
        let partlyCloudyAtNight = ForecastHour(time: nightEnd, temp: 3, precip: 0, wind: 1, cloud: 40, dew: 2)
        let rainAtNight = ForecastHour(time: nightEnd, temp: 3, precip: 0.2, wind: 1, cloud: 80, dew: 2)

        XCTAssertEqual(forecastSymbol(clearBeforeSunset, isDaylight: true), "sun.max.fill")
        XCTAssertEqual(forecastSymbol(clearAfterSunset, isDaylight: false), "moon.stars.fill")
        XCTAssertEqual(forecastSymbol(partlyCloudyAtNight, isDaylight: false), "cloud.moon.fill")
        XCTAssertEqual(forecastSymbol(rainAtNight, isDaylight: false), "cloud.rain.fill")
        XCTAssertEqual(
            CurrentWeatherCondition.clear.accessibilityLabel(languageStyle: .bokmal, isDaylight: false),
            "Klart"
        )
    }

    func testFogMarkerInSolarBandUsesSunHazeOnlyWhenSolarCellShowsSun() {
        let foggy = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 95, dew: 7, fog: 50)
        let clearVisibility = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 95, dew: 7, fog: 49.9)
        let unavailable = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 95, dew: 7)

        XCTAssertEqual(solarBandFogLevel(foggy), 50)
        XCTAssertNil(solarBandFogLevel(clearVisibility))
        XCTAssertNil(solarBandFogLevel(unavailable))
        XCTAssertEqual(solarBandFogSymbol(for: .neutral), "cloud.fog.fill")
        XCTAssertEqual(solarBandFogSymbol(for: .sunlit), "sun.haze.fill")
        XCTAssertEqual(solarBandFogSymbol(for: .partlySunlit), "sun.haze.fill")
    }

    func testDialectWeekdaysKeepBokmalUnchanged() {
        XCTAssertEqual(WeatherLanguage.text("Regn denne timen", style: .inntrondersk), "Regn herre tima")
        XCTAssertEqual(WeatherLanguage.text("Regn denne timen", style: .bokmal), "Regn denne timen")
        let source = fullDayNames.joined(separator: ", ")
        XCTAssertEqual(WeatherLanguage.text(source, style: .inntrondersk), "manda'n, tirsda'n, onsda'n, torsda'n, freda'n, lørda'n, sønda'n")
        XCTAssertEqual(WeatherLanguage.text(source, style: .bokmal), source)
        XCTAssertEqual(WeatherLanguage.text("Mandag kl. 09", style: .inntrondersk), "Manda'n kl. 09")
    }

    func testTemperatureDisplayThresholdDoesNotCreateOrChangePushRules() throws {
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        XCTAssertEqual(place.resolvedDisplayTemperatureThreshold, 10)
        place.displayTemperatureThreshold = 7.5
        let restored = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(place))
        XCTAssertEqual(restored.resolvedDisplayTemperatureThreshold, 7.5)
        XCTAssertTrue(restored.rules.isEmpty)
        let display = try XCTUnwrap(restored.rulesForDisplay.first { $0.type == .temperatur })
        XCTAssertTrue(display.isDisplayOnly)
        XCTAssertEqual(display.threshold, 7.5)
        var rule = Rule(type: .temperatur)
        rule.threshold = 3
        place.rules = [rule]
        XCTAssertEqual(place.rulesForDisplay.first { $0.type == .temperatur }?.threshold, 3)
        place.rules[0].enabled = false
        XCTAssertEqual(place.rulesForDisplay.first { $0.type == .temperatur }?.threshold, 7.5)
        XCTAssertEqual(place.rules[0].threshold, 3)
        place.rulesOnlyDisplay = true
        XCTAssertFalse(place.rulesForDisplay.contains { $0.type == .temperatur })
        let old = try JSONDecoder().decode(Place.self, from: Data(#"{"name":"Klinga","lat":64,"lon":11}"#.utf8))
        XCTAssertEqual(old.resolvedDisplayTemperatureThreshold, 10)
        XCTAssertEqual(old.resolvedDisplayTemperatureHighThreshold, 20)
        XCTAssertNil(old.displayTemperatureHighThreshold)
    }

    func testLocalTemperatureAdjustmentIsTheValueUsedForDisplayThresholds() {
        let yrHour = ForecastHour(time: base, temp: 19, precip: 0, wind: 1, cloud: 20, dew: 8)
        let localHour = yrHour.locallyAdjusted(by: 2)
        XCTAssertLessThan(yrHour.temp, 20)
        XCTAssertGreaterThanOrEqual(localHour.temp, 20)
    }

    @MainActor
    func testLocalTemperatureOffsetIsAppliedOnlyToItsPlaceDisplay() throws {
        let persistenceKey = "varsel.test.place-temperature-offset.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        var home = Place(name: "Klinga", lat: 64, lon: 11)
        home.temperatureOffset = 2
        var cabin = Place(name: "Hytte", lat: 64.2, lon: 11.2)
        cabin.temperatureOffset = -1
        let homeYr = ForecastHour(time: base, temp: 4, precip: 0, wind: 1, cloud: 20, dew: 2)
        let cabinYr = ForecastHour(time: base, temp: 12, precip: 0, wind: 1, cloud: 20, dew: 8)
        let store = Store(persistenceKey: persistenceKey)
        store.places = [home, cabin]
        store.selectedID = home.id
        store.forecasts = [home.id: [homeYr], cabin.id: [cabinYr]]

        let displayedHome = try XCTUnwrap(store.selectedForecast.first)
        let displayedCabin = try XCTUnwrap(store.forecasts[cabin.id]?.first)

        XCTAssertEqual(displayedHome.temp, 6)
        XCTAssertEqual(displayedHome.yrTemperature, 4)
        XCTAssertEqual(displayedCabin.temp, 11)
        XCTAssertEqual(displayedCabin.yrTemperature, 12)
        XCTAssertEqual(homeYr.temp, 4)
        XCTAssertEqual(cabinYr.temp, 12)
    }

    func testCompactTemperatureTextUsesSharedWholeDegreeFormat() {
        XCTAssertEqual(compactTemperatureText(12.6), "13°")
        XCTAssertEqual(compactTemperatureText(-0.4), "0°")
        XCTAssertEqual(compactTemperatureText(.nan), "–°")
        XCTAssertEqual(compactTemperatureText(.infinity), "–°")
    }

    func testDisplayOnlyRuleNeverCreatesPushAlert() {
        var rule = Rule(type: .regn)
        rule.isDisplayOnly = true
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let hours = forecast(values: [(6, 1, 1, 100, 4), (6, 1, 1, 100, 4)])
        XCTAssertTrue(Planner.planAll(places: [place], forecasts: [place.id: hours]).isEmpty)
    }

    func testDisplayOnlyRowCannotStartOrContinueLiveActivity() {
        var rule = Rule(type: .regn)
        rule.isDisplayOnly = true
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])

        XCTAssertTrue(place.rulesForDisplay.contains { $0.id == rule.id })
        XCTAssertFalse(LiveWeatherActivityPolicy.canUseRule(
            rule, for: place, nearbyPlaceIDs: [place.id]
        ))
    }

    func testNearbyMonitoringFailureClearsAfterRetryStartsAndReconcileDropsRemovedPlaces() {
        let placeID = UUID()
        var failedIDs = NearbyMonitoringFailureState.markedFailed(placeID, in: [])
        XCTAssertEqual(failedIDs, [placeID])

        failedIDs = NearbyMonitoringFailureState.reconciled(
            failedIDs, wantedPlaceIDs: [placeID]
        )
        XCTAssertEqual(failedIDs, [placeID], "Reconfiguration must keep the issue visible until monitoring succeeds")

        failedIDs = NearbyMonitoringFailureState.markedStarted(placeID, in: failedIDs)
        XCTAssertTrue(failedIDs.isEmpty, "A successful retry should clear the monitoring issue")

        failedIDs = NearbyMonitoringFailureState.markedFailed(placeID, in: failedIDs)
        failedIDs = NearbyMonitoringFailureState.reconciled(failedIDs, wantedPlaceIDs: [])
        XCTAssertTrue(failedIDs.isEmpty, "Removing the nearby-only rule should clear its stale issue")
    }

    func testNearbyMonitoringOverflowMatchesTwentyRegionLimitAndFreesSlots() {
        let ids = (0..<22).map { _ in UUID() }

        XCTAssertTrue(NearbyMonitoringRegionPolicy.overflowIDs(for: Array(ids.prefix(20))).isEmpty)
        XCTAssertEqual(NearbyMonitoringRegionPolicy.overflowIDs(for: ids), [ids[20], ids[21]])

        let afterRemovingFirstPlace = Array(ids.dropFirst())
        XCTAssertEqual(NearbyMonitoringRegionPolicy.overflowIDs(for: afterRemovingFirstPlace), [ids[21]])
    }

    func testNearbyMonitoringOverflowSummaryNamesAffectedPlacesAndCountsRemainingInBothLanguages() {
        let names = ["Klinga", "Hytta", "Hjem", "Naust", "Sæter"]
        XCTAssertEqual(
            NearbyMonitoringOverflowSummary.text(placeNames: names, languageStyle: .bokmal),
            "Overvåkes ikke: Klinga, Hytta, Hjem +2. iOS støtter nærhetsvarsler for opptil 20 steder; slå av «Bare når jeg er i nærheten» for et sted som ikke trenger det, for å frigjøre en plass."
        )
        XCTAssertEqual(
            NearbyMonitoringOverflowSummary.text(placeNames: names, languageStyle: .english),
            "Not monitored: Klinga, Hytta, Hjem +2. iOS supports nearby alerts for up to 20 places; turn off nearby-only for a place that does not need it to free a slot."
        )
        XCTAssertEqual(
            NearbyMonitoringOverflowSummary.text(placeNames: ["Klinga"], languageStyle: .bokmal),
            "Overvåkes ikke: Klinga. iOS støtter nærhetsvarsler for opptil 20 steder; slå av «Bare når jeg er i nærheten» for et sted som ikke trenger det, for å frigjøre en plass."
        )
        XCTAssertEqual(NearbyMonitoringOverflowSummary.text(placeNames: [], languageStyle: .bokmal), "")
    }

    func testNearbyAuthorizationPolicyRequiresAlwaysAccessAndRejectsDeniedRestrictedOrUnknown() {
        XCTAssertFalse(NearbyAuthorizationPolicy.isUnavailable(CLAuthorizationStatus.authorizedAlways.rawValue))
        for status in [CLAuthorizationStatus.notDetermined, .authorizedWhenInUse, .denied, .restricted] {
            XCTAssertTrue(NearbyAuthorizationPolicy.isUnavailable(status.rawValue))
        }
        XCTAssertTrue(NearbyAuthorizationPolicy.isUnavailable(Int32.max))
    }

    func testDisabledRuleNeverCreatesPushAlert() {
        var rule = Rule(type: .regn)
        rule.enabled = false
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let hours = forecast(values: [(6, 1, 1, 100, 4), (6, 1, 1, 100, 4)])
        XCTAssertTrue(Planner.planAll(places: [place], forecasts: [place.id: hours]).isEmpty)
    }

    func testHiddenDisplayTypeCannotReappearInRotatingHomeAfterCacheRestore() throws {
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.hiddenAlertTypes = [.regn]
        let hour = ForecastHour(time: base, temp: 6, precip: 1, wind: 1, cloud: 100, dew: 4)
        let state = PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: [hour]], forecastUpdatedAt: [place.id: base], lastUpdate: base
        )
        let restored = try JSONDecoder().decode(
            PersistedStoreState.self, from: JSONEncoder().encode(state)
        )
        let restoredPlace = try XCTUnwrap(restored.places.first)

        XCTAssertFalse(restoredPlace.rulesForDisplay.contains { $0.type == .regn })
        XCTAssertFalse(Planner.statuses(for: restoredPlace, forecast: restored.forecasts[restoredPlace.id] ?? [], now: base)
            .contains { $0.type == .regn })
    }

    func testHomeFavoritesPreserveIdentityAndRejectDuplicatesOrDeletedPlaces() throws {
        let a = UUID(), b = UUID()
        let favorites = HomeFavorites(left: a, right: b)
        let restored = try JSONDecoder().decode(HomeFavorites.self, from: JSONEncoder().encode(favorites))
        XCTAssertEqual(restored, favorites)
        XCTAssertEqual(restored.resolved(availableIDs: [b, a]), favorites)
        XCTAssertEqual(restored.resolved(availableIDs: [b]), HomeFavorites(left: nil, right: b))
        XCTAssertEqual(restored.resolved(availableIDs: []), HomeFavorites())
        XCTAssertEqual(HomeFavorites(left: a, right: a).resolved(availableIDs: [a]), HomeFavorites(left: a))
        XCTAssertEqual(try JSONDecoder().decode(HomeFavorites.self, from: Data("{}".utf8)), HomeFavorites())
    }

    @MainActor
    func testCancelledLocationRequestDoesNotStartLocationLookup() async {
        let location = LocationManager()
        let task = Task { @MainActor in try await location.current() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled request should not return a position")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancelledLocationRequestCanRetryAndIgnoresLateOldClientCallback() async throws {
        var clients: [FakeOneShotLocationClient] = []
        let locationManager = LocationManager {
            let client = FakeOneShotLocationClient()
            clients.append(client)
            return client
        }

        let firstRequest = Task { @MainActor in try await locationManager.current() }
        for _ in 0..<20 where clients.first?.locationRequestCount != 1 { await Task.yield() }
        XCTAssertEqual(clients.first?.locationRequestCount, 1)
        firstRequest.cancel()
        do {
            _ = try await firstRequest.value
            XCTFail("Cancelled request should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        var secondRequestCompleted = false
        let secondRequest = Task { @MainActor in
            defer { secondRequestCompleted = true }
            return try await locationManager.current()
        }
        for _ in 0..<20 where clients.count < 2 || clients[1].locationRequestCount != 1 { await Task.yield() }
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[1].locationRequestCount, 1)

        clients[0].deliver(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 10, longitude: 20),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
        ))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(secondRequestCompleted, "A stale callback must not finish the newer request")

        let expectedLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 30, longitude: 40),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
        )
        clients[1].deliver(expectedLocation)
        let result = try await secondRequest.value
        XCTAssertEqual(result.coordinate.latitude, expectedLocation.coordinate.latitude)
        XCTAssertEqual(result.coordinate.longitude, expectedLocation.coordinate.longitude)
    }

    func testLocationAuthorizationDecisionFailsImmediatelyForDeniedRestrictedAndUnknownStatus() {
        for status in [CLAuthorizationStatus.denied, .restricted] {
            XCTAssertEqual(
                LocationAuthorizationDecision.forRawStatus(status.rawValue),
                .fail(.denied)
            )
        }
        XCTAssertEqual(
            LocationAuthorizationDecision.forRawStatus(Int32.max),
            .fail(.denied),
            "An unrecognized future authorization status must not wait for the timeout."
        )
    }

    func testLocationAuthorizationDecisionPreservesUndeterminedAndAuthorizedBehavior() {
        XCTAssertEqual(
            LocationAuthorizationDecision.forRawStatus(CLAuthorizationStatus.notDetermined.rawValue),
            .requestWhenInUseAuthorization
        )
        XCTAssertEqual(
            LocationAuthorizationDecision.forRawStatus(CLAuthorizationStatus.authorizedAlways.rawValue),
            .requestLocation
        )
        XCTAssertEqual(
            LocationAuthorizationDecision.forRawStatus(CLAuthorizationStatus.authorizedWhenInUse.rawValue),
            .requestLocation
        )
    }

    @MainActor
    func testOneShotLocationRequestFinishesWhenAuthorizationIsDenied() async {
        let client = FakeOneShotLocationClient()
        client.authorizationStatusRawValue = CLAuthorizationStatus.notDetermined.rawValue
        let locationManager = LocationManager { client }
        let request = Task { @MainActor in try await locationManager.current() }

        for _ in 0..<20 where client.authorizationRequestCount == 0 { await Task.yield() }
        XCTAssertEqual(client.authorizationRequestCount, 1)
        XCTAssertEqual(client.locationRequestCount, 0)
        client.onAuthorizationChange?(CLAuthorizationStatus.denied.rawValue)

        do {
            _ = try await request.value
            XCTFail("Denied location authorization should fail without waiting for a fix")
        } catch let error as CLError {
            XCTAssertEqual(error.code, .denied)
        } catch {
            XCTFail("Expected a location authorization error, got \(error)")
        }
        XCTAssertEqual(client.locationRequestCount, 0)
    }

    func testWindDefaultsPreserveExistingRules() throws {
        XCTAssertEqual(Rule(type: .vind).threshold, 9)
        let legacy = try JSONDecoder().decode(Rule.self, from: Data("{\"type\":\"vind\"}".utf8))
        XCTAssertEqual(legacy.threshold, 10)
        for threshold in [4.0, 9, 10, 12, 20, 40] {
            var rule = Rule(type: .vind)
            rule.threshold = threshold
            let restored = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
            XCTAssertEqual(restored.threshold, threshold)
        }
        let ids = Set(["vind-natt", "vind-morgen", "dag-vind", "snart-vind"])
        let presets = RulePreset.all.filter { ids.contains($0.id) }
        XCTAssertEqual(presets.count, 4)
        for preset in presets {
            XCTAssertEqual(preset.rule.threshold, 9)
            XCTAssertTrue(preset.detail.contains("9 m/s i kastene"))
        }
        XCTAssertEqual(WindGustLevel.looseObjects.threshold, 12)
    }

    func testEveryContextHelpTopicHasReadableContentAndAtLeastOneStep() {
        let topics: [ContextHelpTopic] = [.home, .places, .alerts, .settings, .wizard]

        XCTAssertEqual(topics.count, 5)
        for topic in topics {
            XCTAssertFalse(topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(topic.introduction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(topic.steps.isEmpty)
            XCTAssertTrue(topic.steps.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        }
    }

    func testContextHelpAccessibilityLabelsFollowSelectedLanguageStyle() {
        let topics: [ContextHelpTopic] = [.home, .places, .alerts, .settings, .wizard]
        let englishTitles = [
            "How to read Home",
            "Places and cabin",
            "Understanding the alert list",
            "Settings",
            "Getting started help"
        ]

        for (topic, englishTitle) in zip(topics, englishTitles) {
            XCTAssertEqual(topic.accessibilityLabel(languageStyle: .english), "Help: \(englishTitle)")
            XCTAssertEqual(topic.accessibilityLabel(languageStyle: .bokmal), "Hjelp: \(topic.title)")
            XCTAssertEqual(topic.accessibilityLabel(languageStyle: .inntrondersk), "Hjelp: \(WeatherLanguage.text(topic.title, style: .inntrondersk))")
        }
    }

    func testContextHelpSheetCopyFollowsSelectedLanguageStyle() {
        let topics: [ContextHelpTopic] = [.home, .places, .alerts, .settings, .wizard]

        for topic in topics {
            XCTAssertFalse(topic.title(languageStyle: .english).isEmpty)
            XCTAssertFalse(topic.introduction(languageStyle: .english).isEmpty)
            XCTAssertTrue(topic.steps(languageStyle: .english).allSatisfy { !$0.isEmpty })
            XCTAssertNotEqual(topic.title(languageStyle: .english), topic.title)
            XCTAssertNotEqual(topic.introduction(languageStyle: .english), topic.introduction)
            XCTAssertNotEqual(topic.steps(languageStyle: .english), topic.steps)
            XCTAssertEqual(topic.title(languageStyle: .bokmal), topic.title)
            XCTAssertEqual(topic.introduction(languageStyle: .bokmal), topic.introduction)
            XCTAssertEqual(topic.steps(languageStyle: .bokmal), topic.steps)
            XCTAssertEqual(
                topic.steps(languageStyle: .inntrondersk),
                topic.steps.map { WeatherLanguage.text($0, style: .inntrondersk) }
            )
        }

        XCTAssertEqual(ContextHelpTopic.home.title(languageStyle: .english), "How to read Home")
        XCTAssertEqual(ContextHelpTopic.places.title(languageStyle: .english), "Places and cabin")
        XCTAssertEqual(ContextHelpTopic.alerts.title(languageStyle: .english), "What does the alert list mean?")
        XCTAssertEqual(ContextHelpTopic.settings.title(languageStyle: .english), "Settings")
        XCTAssertEqual(ContextHelpTopic.wizard.title(languageStyle: .english), "Getting started help")
        XCTAssertEqual(ContextHelpChromeCopy.quickExplanation(languageStyle: .english), "Quick explanation")
        XCTAssertEqual(ContextHelpChromeCopy.navigationTitle(languageStyle: .english), "Help")
        XCTAssertEqual(ContextHelpChromeCopy.doneButton(languageStyle: .english), "Done")
        XCTAssertEqual(ContextHelpChromeCopy.quickExplanation(languageStyle: .bokmal), "Kort forklart")
        XCTAssertEqual(ContextHelpChromeCopy.navigationTitle(languageStyle: .bokmal), "Hjelp")
        XCTAssertEqual(ContextHelpChromeCopy.doneButton(languageStyle: .bokmal), "Ferdig")
    }

    func testWizardCategoriesCoverEveryAlertTypeExactlyOnce() {
        let expected: [WizardAlertCategory: Set<AlertType>] = [
            .rain: [.regn],
            .wind: [.vind],
            .winter: [.sno, .frost],
            .sun: [.sol],
            .moisture: [.temperatur, .dugg]
        ]
        let categories = WizardAlertCategory.allCases
        let categorizedTypes = categories.flatMap { Array($0.types) }

        XCTAssertEqual(categories.count, expected.count)
        XCTAssertEqual(categorizedTypes.count, AlertType.allCases.count)
        XCTAssertEqual(Set(categorizedTypes), Set(AlertType.allCases))
        for category in categories {
            XCTAssertEqual(category.types, expected[category] ?? [])
        }
    }

    func testEveryWizardCategoryHasReadableCopyAndASymbolName() {
        XCTAssertFalse(WizardAlertCategory.allCases.isEmpty)

        for category in WizardAlertCategory.allCases {
            XCTAssertFalse(category.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(category.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(category.image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testEveryWizardAlertCategoryHasMatchingPresetChoices() {
        for category in WizardAlertCategory.allCases {
            let presets = category.presets
            XCTAssertFalse(presets.isEmpty, "\(category.title) must offer at least one preset")
            XCTAssertTrue(presets.allSatisfy { category.types.contains($0.rule.type) })
            XCTAssertEqual(Set(presets.map(\.id)).count, presets.count, "\(category.title) should not repeat a preset")
        }
    }

    func testWizardDefaultPresetsExistAndOnlyCabinCanUseNearbyRules() {
        let availableIDs = Set(RulePreset.all.map(\.id))
        let defaults = [
            WizardPresetConfiguration.homePresetIDs,
            WizardPresetConfiguration.cabinPresetIDs
        ]

        for ids in defaults {
            XCTAssertEqual(ids.count, Set(ids).count, "Wizard defaults must not repeat preset IDs")
            XCTAssertTrue(Set(ids).isSubset(of: availableIDs), "Every wizard default must match a preset")
        }

        let homeRules = WizardPresetConfiguration.rules(
            selectedIDs: Set(WizardPresetConfiguration.homePresetIDs),
            for: .home,
            cabinOnlyWhenNearby: true
        )
        let nearbyCabinRules = WizardPresetConfiguration.rules(
            selectedIDs: Set(WizardPresetConfiguration.cabinPresetIDs),
            for: .cabin,
            cabinOnlyWhenNearby: true
        )
        let alwaysActiveCabinRules = WizardPresetConfiguration.rules(
            selectedIDs: Set(WizardPresetConfiguration.cabinPresetIDs),
            for: .cabin,
            cabinOnlyWhenNearby: false
        )

        XCTAssertEqual(homeRules.count, WizardPresetConfiguration.homePresetIDs.count)
        XCTAssertTrue(homeRules.allSatisfy { !$0.onlyWhenNearby })
        XCTAssertEqual(nearbyCabinRules.count, WizardPresetConfiguration.cabinPresetIDs.count)
        XCTAssertTrue(nearbyCabinRules.allSatisfy(\.onlyWhenNearby))
        XCTAssertTrue(alwaysActiveCabinRules.allSatisfy { !$0.onlyWhenNearby })
    }

    func testWizardPresetRulesIgnoreUnknownIDsAndFollowCatalogOrder() {
        let rules = WizardPresetConfiguration.rules(
            selectedIDs: ["vind-kraftig", "ukjent-forslag", "regn-neste"],
            for: .home,
            cabinOnlyWhenNearby: false
        )

        XCTAssertEqual(rules.map(\.templateTitle), ["Regn neste dag", "Kraftige vindkast"])
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.allSatisfy { !$0.onlyWhenNearby })
    }

    func testWizardPresetSelectionsAreIndependentForHomeAndCabin() {
        var selections = WizardPresetSelections()
        let sharedPresetID = "frost-natt"

        XCTAssertTrue(selections.ids(for: .home).contains(sharedPresetID))
        XCTAssertTrue(selections.ids(for: .cabin).contains(sharedPresetID))

        selections.set(sharedPresetID, selected: false, for: .home)
        XCTAssertFalse(selections.ids(for: .home).contains(sharedPresetID))
        XCTAssertTrue(selections.ids(for: .cabin).contains(sharedPresetID))

        selections.set(sharedPresetID, selected: false, for: .cabin)
        XCTAssertFalse(selections.ids(for: .home).contains(sharedPresetID))
        XCTAssertFalse(selections.ids(for: .cabin).contains(sharedPresetID))

        selections.set(sharedPresetID, selected: true, for: .home)
        XCTAssertTrue(selections.ids(for: .home).contains(sharedPresetID))
        XCTAssertFalse(selections.ids(for: .cabin).contains(sharedPresetID))

        selections.set(sharedPresetID, selected: true, for: .cabin)
        XCTAssertTrue(selections.ids(for: .home).contains(sharedPresetID))
        XCTAssertTrue(selections.ids(for: .cabin).contains(sharedPresetID))
    }

    func testWizardCabinNearbyRulesPersistWithoutChangingHomeRules() throws {
        let persistenceKeys = [
            "varsel.test.wizard-cabin-nearby-enabled.\(UUID().uuidString)",
            "varsel.test.wizard-cabin-nearby-disabled.\(UUID().uuidString)"
        ]
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            persistenceKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        for (index, cabinOnlyWhenNearby) in [true, false].enumerated() {
            let homeRules = WizardPresetConfiguration.rules(
                selectedIDs: ["regn-neste", "frost-natt"],
                for: .home,
                cabinOnlyWhenNearby: cabinOnlyWhenNearby
            )
            let cabinRules = WizardPresetConfiguration.rules(
                selectedIDs: ["frost-natt", "vind-kraftig"],
                for: .cabin,
                cabinOnlyWhenNearby: cabinOnlyWhenNearby
            )
            let home = Place(name: "Klinga", lat: 64.4, lon: 11.4, rules: homeRules)
            let cabin = Place(name: "Hytte", lat: 64.2, lon: 11.4, preposition: .pa, rules: cabinRules)
            let state = PersistedStoreState(places: [home, cabin], selectedID: home.id, log: [])
            let persistenceKey = persistenceKeys[index]
            UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: persistenceKey)

            let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

            let restoredHome = try XCTUnwrap(restored.places.first { $0.id == home.id })
            let restoredCabin = try XCTUnwrap(restored.places.first { $0.id == cabin.id })
            XCTAssertEqual(restored.selectedID, home.id)
            XCTAssertEqual(restoredHome.rules.map(\.templateTitle), homeRules.map(\.templateTitle))
            XCTAssertTrue(restoredHome.rules.allSatisfy { !$0.onlyWhenNearby })
            XCTAssertEqual(restoredCabin.rules.map(\.templateTitle), cabinRules.map(\.templateTitle))
            XCTAssertEqual(
                restoredCabin.rules.map(\.onlyWhenNearby),
                Array(repeating: cabinOnlyWhenNearby, count: cabinRules.count)
            )
        }
    }

    func testStoreRepairsAndPersistsMissingSelectedPlaceID() throws {
        let persistenceKey = "varsel.test.missing-selected-place.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let first = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let second = Place(name: "Hytta", lat: 64.2, lon: 11.4, preposition: .pa)
        let cachedHour = ForecastHour(time: base, temp: 7, precip: 0, wind: 1, cloud: 30, dew: 4)
        let missingID = UUID()
        let state = PersistedStoreState(
            places: [first, second], selectedID: missingID, log: [],
            forecasts: [first.id: [cachedHour]], forecastUpdatedAt: [first.id: base], lastUpdate: base
        )
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

        XCTAssertEqual(restored.selectedID, first.id)
        let repairedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repairedState = try JSONDecoder().decode(PersistedStoreState.self, from: repairedData)
        let repairedSelectedID = try XCTUnwrap(repairedState.selectedID)
        XCTAssertEqual(repairedSelectedID, first.id)
        XCTAssertTrue(repairedState.places.contains { $0.id == repairedSelectedID })
        XCTAssertEqual(repairedState.forecasts[first.id], [cachedHour])
        XCTAssertEqual(repairedState.forecastUpdatedAt[first.id], base)

        let relaunched = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(relaunched.places.map(\.id), [first.id, second.id])
        XCTAssertEqual(relaunched.selectedID, first.id)
        XCTAssertEqual(relaunched.selected?.id, first.id)
        XCTAssertEqual(relaunched.forecasts[first.id], [cachedHour])
        XCTAssertEqual(relaunched.forecastUpdatedAt(for: first.id), base)
    }

    func testLaunchPlaceMigrationPersistsFallbackSelectionAndReusesItOnRestart() throws {
        let persistenceKey = "varsel.test.migration-persists-fallback-selection.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(8, forKey: launchVersionKey)

        let firstStoredPlace = Place(name: "Hytte", lat: 64.2, lon: 11.4, preposition: .pa)
        let secondStoredPlace = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let thirdStoredPlace = Place(name: "Naust", lat: 64.1, lon: 11.6)
        let missingSelection = UUID()
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [firstStoredPlace, secondStoredPlace, thirdStoredPlace],
            selectedID: missingSelection,
            log: []
        )), forKey: persistenceKey)

        let migrated = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

        XCTAssertEqual(migrated.selectedID, firstStoredPlace.id)
        XCTAssertNotEqual(migrated.places.first?.id, firstStoredPlace.id)
        let persistedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: persistedData)
        XCTAssertEqual(persisted.selectedID, firstStoredPlace.id)
        XCTAssertTrue(persisted.places.contains { $0.id == firstStoredPlace.id })

        let restarted = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restarted.selectedID, firstStoredPlace.id)
        XCTAssertEqual(restarted.selected?.id, firstStoredPlace.id)
        XCTAssertTrue(restarted.places.contains { $0.id == secondStoredPlace.id })
        XCTAssertTrue(restarted.places.contains { $0.id == thirdStoredPlace.id })
    }

    func testStoreFallsBackToLaunchPlacesWhenPersistedListIsEmpty() throws {
        let persistenceKey = "varsel.test.empty-persisted-places.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)
        let emptyState = PersistedStoreState(places: [], selectedID: nil, log: [])
        UserDefaults.standard.set(try JSONEncoder().encode(emptyState), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

        XCTAssertEqual(restored.places.map(\.name), Store.launchPlaces.map(\.name))
        let selectedID = try XCTUnwrap(restored.selectedID)
        XCTAssertTrue(restored.places.contains { $0.id == selectedID })
        XCTAssertEqual(restored.selected?.id, selectedID)

        let savedFallbackData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let savedFallback = try JSONDecoder().decode(PersistedStoreState.self, from: savedFallbackData)
        XCTAssertEqual(savedFallback.places.map(\.id), restored.places.map(\.id))
        XCTAssertEqual(savedFallback.selectedID, selectedID)

        let relaunched = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(relaunched.places.map(\.id), restored.places.map(\.id))
        XCTAssertEqual(relaunched.selectedID, selectedID)
    }

    func testCurrentLaunchPlaceVersionDoesNotRestoreRemovedDefaultPlace() throws {
        let persistenceKey = "varsel.test.current-version-removed-default-place.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let hytte = Place(name: "Hytte", lat: 64.2, lon: 11.4, preposition: .pa)
        let naust = Place(name: "Naust", lat: 64.1, lon: 11.6, preposition: .inni)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [hytte, naust], selectedID: naust.id, log: []
        )), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

        XCTAssertEqual(restored.places.map(\.id), [hytte.id, naust.id])
        XCTAssertFalse(restored.places.contains { $0.name == "Klinga" })
        XCTAssertEqual(restored.selectedID, naust.id)

        let relaunched = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(relaunched.places.map(\.id), [hytte.id, naust.id])
        XCTAssertFalse(relaunched.places.contains { $0.name == "Klinga" })
        XCTAssertEqual(relaunched.selectedID, naust.id)
    }

    func testCurrentLaunchPlaceVersionKeepsRemainingForecastCachesAfterDefaultRemoval() throws {
        let persistenceKey = "varsel.test.current-version-cache-after-default-removal.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let hytte = Place(name: "Hytte", lat: 64.2, lon: 11.4, preposition: .pa)
        let naust = Place(name: "Naust", lat: 64.1, lon: 11.6, preposition: .inni)
        let removedKlinga = Store.launchPlaces[0]
        let hytteHour = ForecastHour(time: base, temp: 5, precip: 1, wind: 2, cloud: 40, dew: 3)
        let naustHour = ForecastHour(time: base.addingTimeInterval(3_600), temp: 8, precip: 0, wind: 1, cloud: 20, dew: 4)
        let removedHour = ForecastHour(time: base.addingTimeInterval(7_200), temp: 2, precip: 0, wind: 4, cloud: 70, dew: 1)
        let hytteFetchedAt = base.addingTimeInterval(-600)
        let naustFetchedAt = base.addingTimeInterval(-1_200)
        let removedFetchedAt = base.addingTimeInterval(-1_800)
        let savedState = PersistedStoreState(
            places: [hytte, naust], selectedID: naust.id, log: [],
            forecasts: [
                hytte.id: [hytteHour],
                naust.id: [naustHour],
                removedKlinga.id: [removedHour],
            ],
            forecastUpdatedAt: [
                hytte.id: hytteFetchedAt,
                naust.id: naustFetchedAt,
                removedKlinga.id: removedFetchedAt,
            ],
            lastUpdate: naustFetchedAt
        )
        UserDefaults.standard.set(try JSONEncoder().encode(savedState), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

        XCTAssertEqual(restored.places.map(\.id), [hytte.id, naust.id])
        XCTAssertEqual(restored.selectedID, naust.id)
        XCTAssertEqual(restored.forecasts[hytte.id], [hytteHour])
        XCTAssertEqual(restored.forecastUpdatedAt(for: hytte.id), hytteFetchedAt)
        XCTAssertEqual(restored.forecasts[naust.id], [naustHour])
        XCTAssertEqual(restored.forecastUpdatedAt(for: naust.id), naustFetchedAt)
        XCTAssertNil(restored.forecasts[removedKlinga.id])
        XCTAssertNil(restored.forecastUpdatedAt(for: removedKlinga.id))

        let persistedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: persistedData)
        XCTAssertEqual(Set(persisted.forecasts.keys), Set([hytte.id, naust.id]))
        XCTAssertEqual(Set(persisted.forecastUpdatedAt.keys), Set([hytte.id, naust.id]))

        let relaunched = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(relaunched.places.map(\.id), [hytte.id, naust.id])
        XCTAssertEqual(relaunched.selectedID, naust.id)
        XCTAssertEqual(relaunched.forecasts[hytte.id], [hytteHour])
        XCTAssertEqual(relaunched.forecastUpdatedAt(for: hytte.id), hytteFetchedAt)
        XCTAssertEqual(relaunched.forecasts[naust.id], [naustHour])
        XCTAssertEqual(relaunched.forecastUpdatedAt(for: naust.id), naustFetchedAt)
    }

    func testCurrentLaunchPlaceVersionPreservesCustomizedDefaultPlaceSettings() throws {
        let persistenceKey = "varsel.test.current-version-preserves-place-edits.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        var editedRule = Rule(type: .regn)
        editedRule.templateTitle = "Min egen regnregel"
        editedRule.threshold = 4.5
        var editedKlinga = Place(name: "Klinga", lat: 64.4, lon: 11.4, preposition: .oppa, rules: [editedRule])
        editedKlinga.customName = "Hjemme"
        editedKlinga.temperatureOffset = -1.5
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [editedKlinga], selectedID: editedKlinga.id, log: []
        )), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        let restoredKlinga = try XCTUnwrap(restored.places.first)

        XCTAssertEqual(restored.places.map(\.id), [editedKlinga.id])
        XCTAssertEqual(restoredKlinga.preposition, .oppa)
        XCTAssertEqual(restoredKlinga.customName, "Hjemme")
        XCTAssertEqual(restoredKlinga.temperatureOffset, -1.5)
        XCTAssertEqual(restoredKlinga.rules.map(\.id), [editedRule.id])
        XCTAssertEqual(restoredKlinga.rules.first?.templateTitle, "Min egen regnregel")
        XCTAssertEqual(restoredKlinga.rules.first?.threshold, 4.5)

        let relaunched = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(relaunched.places.map(\.id), [editedKlinga.id])
        XCTAssertEqual(relaunched.selectedID, editedKlinga.id)
        XCTAssertEqual(relaunched.selected?.preposition, .oppa)
        XCTAssertEqual(relaunched.selected?.rules.first?.templateTitle, "Min egen regnregel")
    }

    func testRemovingUnselectedCabinPreservesHomeAcrossStoreRestore() throws {
        let persistenceKey = "varsel.test.remove-unselected-cabin.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        var homeRule = Rule(type: .regn)
        homeRule.templateTitle = "Regn hjemme"
        var cabinRule = Rule(type: .frost)
        cabinRule.templateTitle = "Frost på hytta"
        let home = Place(name: "Klinga", lat: 64.4, lon: 11.4, rules: [homeRule])
        let cabin = Place(name: "Hytte", lat: 64.2, lon: 11.4, preposition: .pa, rules: [cabinRule])
        let homeHour = ForecastHour(time: base, temp: 8, precip: 1, wind: 2, cloud: 40, dew: 4)
        let cabinHour = ForecastHour(time: base.addingTimeInterval(3_600), temp: -2, precip: 0, wind: 1, cloud: 80, dew: -3)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [home, cabin], selectedID: home.id, log: [],
            forecasts: [home.id: [homeHour], cabin.id: [cabinHour]],
            forecastUpdatedAt: [home.id: base, cabin.id: base.addingTimeInterval(3_600)],
            lastUpdate: base
        )), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        store.removePlaces(ids: [cabin.id])

        XCTAssertEqual(store.places.map(\.id), [home.id])
        XCTAssertEqual(store.selectedID, home.id)
        XCTAssertEqual(store.places.first?.rules.map(\.templateTitle), ["Regn hjemme"])
        XCTAssertEqual(store.forecasts[home.id], [homeHour])
        XCTAssertNil(store.forecasts[cabin.id])

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.places.map(\.id), [home.id])
        XCTAssertEqual(restored.selectedID, home.id)
        XCTAssertEqual(restored.places.first?.rules.map(\.templateTitle), ["Regn hjemme"])
        XCTAssertEqual(restored.forecasts[home.id], [homeHour])
        XCTAssertNil(restored.forecasts[cabin.id])
    }

    func testRemovingSelectedCabinFallsBackToHomeAcrossStoreRestore() throws {
        let persistenceKey = "varsel.test.remove-selected-cabin.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        var homeRule = Rule(type: .regn)
        homeRule.templateTitle = "Regn hjemme"
        var cabinRule = Rule(type: .frost)
        cabinRule.templateTitle = "Frost på hytta"
        let home = Place(name: "Klinga", lat: 64.4, lon: 11.4, rules: [homeRule])
        let cabin = Place(name: "Hytte", lat: 64.2, lon: 11.4, preposition: .pa, rules: [cabinRule])
        let homeHour = ForecastHour(time: base, temp: 8, precip: 1, wind: 2, cloud: 40, dew: 4)
        let cabinHour = ForecastHour(time: base.addingTimeInterval(3_600), temp: -2, precip: 0, wind: 1, cloud: 80, dew: -3)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [home, cabin], selectedID: cabin.id, log: [],
            forecasts: [home.id: [homeHour], cabin.id: [cabinHour]],
            forecastUpdatedAt: [home.id: base, cabin.id: base.addingTimeInterval(3_600)],
            lastUpdate: base
        )), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        store.removePlaces(ids: [cabin.id])

        XCTAssertEqual(store.places.map(\.id), [home.id])
        XCTAssertEqual(store.selectedID, home.id)
        XCTAssertEqual(store.places.first?.rules.map(\.templateTitle), ["Regn hjemme"])
        XCTAssertEqual(store.forecasts[home.id], [homeHour])
        XCTAssertNil(store.forecasts[cabin.id])

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.places.map(\.id), [home.id])
        XCTAssertEqual(restored.selectedID, home.id)
        XCTAssertEqual(restored.places.first?.rules.map(\.templateTitle), ["Regn hjemme"])
        XCTAssertEqual(restored.forecasts[home.id], [homeHour])
        XCTAssertNil(restored.forecasts[cabin.id])
    }

    func testRemovingSeveralPlacesIncludingSelectionPreservesRemainingState() throws {
        let persistenceKey = "varsel.test.remove-several-places.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        var homeRule = Rule(type: .regn)
        homeRule.templateTitle = "Regn hjemme"
        var cabinRule = Rule(type: .frost)
        cabinRule.templateTitle = "Frost på hytta"
        let home = Place(name: "Klinga", lat: 64.4, lon: 11.4, rules: [homeRule])
        let selectedCabin = Place(name: "Valgt hytte", lat: 64.2, lon: 11.4, rules: [cabinRule])
        let remainingCabin = Place(name: "Hytte nummer to", lat: 64.1, lon: 11.5)
        let deletedCabin = Place(name: "Slett også meg", lat: 64.0, lon: 11.6)
        let homeHour = ForecastHour(time: base, temp: 8, precip: 1, wind: 2, cloud: 40, dew: 4)
        let remainingHour = ForecastHour(time: base.addingTimeInterval(3_600), temp: 6, precip: 0, wind: 1, cloud: 30, dew: 3)
        let selectedHour = ForecastHour(time: base.addingTimeInterval(7_200), temp: -2, precip: 0, wind: 1, cloud: 80, dew: -3)
        let deletedHour = ForecastHour(time: base.addingTimeInterval(10_800), temp: 4, precip: 0, wind: 2, cloud: 60, dew: 2)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [home, selectedCabin, remainingCabin, deletedCabin],
            selectedID: selectedCabin.id, log: [],
            forecasts: [
                home.id: [homeHour],
                selectedCabin.id: [selectedHour],
                remainingCabin.id: [remainingHour],
                deletedCabin.id: [deletedHour],
            ],
            forecastUpdatedAt: [
                home.id: base,
                selectedCabin.id: base.addingTimeInterval(7_200),
                remainingCabin.id: base.addingTimeInterval(3_600),
                deletedCabin.id: base.addingTimeInterval(10_800),
            ],
            lastUpdate: base
        )), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        store.removePlaces(ids: [selectedCabin.id, deletedCabin.id])

        XCTAssertEqual(store.places.map(\.id), [home.id, remainingCabin.id])
        XCTAssertEqual(store.selectedID, home.id)
        XCTAssertEqual(store.forecasts[home.id], [homeHour])
        XCTAssertEqual(store.forecasts[remainingCabin.id], [remainingHour])
        XCTAssertNil(store.forecasts[selectedCabin.id])
        XCTAssertNil(store.forecasts[deletedCabin.id])

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.places.map(\.id), [home.id, remainingCabin.id])
        XCTAssertEqual(restored.selectedID, home.id)
        XCTAssertEqual(restored.forecasts[home.id], [homeHour])
        XCTAssertEqual(restored.forecasts[remainingCabin.id], [remainingHour])
        XCTAssertNil(restored.forecasts[selectedCabin.id])
        XCTAssertNil(restored.forecasts[deletedCabin.id])
    }

    @MainActor
    func testBulkRemovalPrunesHomeFavoritesAndPersistsResolvedSwipePlaces() throws {
        let persistenceKey = "varsel.test.remove-prunes-home-favorites.\(UUID().uuidString)"
        let favoritesKey = "varsel.homeFavorites"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousFavorites = UserDefaults.standard.data(forKey: favoritesKey)
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousFavorites {
                UserDefaults.standard.set(previousFavorites, forKey: favoritesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: favoritesKey)
            }
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let home = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let deletedFavorite = Place(name: "Gammel hytte", lat: 64.2, lon: 11.4)
        let retainedFavorite = Place(name: "Ny hytte", lat: 64.1, lon: 11.5)
        let alsoDeleted = Place(name: "Ekstra", lat: 64.0, lon: 11.6)
        let favorites = HomeFavorites(left: deletedFavorite.id, right: retainedFavorite.id)
        UserDefaults.standard.set(try JSONEncoder().encode(favorites), forKey: favoritesKey)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [home, deletedFavorite, retainedFavorite, alsoDeleted],
            selectedID: home.id, log: []
        )), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        store.removePlaces(ids: [deletedFavorite.id, alsoDeleted.id])

        let expected = HomeFavorites(left: nil, right: retainedFavorite.id)
        XCTAssertEqual(store.homeFavorites, expected)
        XCTAssertEqual(store.resolvedHomeFavorites, expected)
        XCTAssertTrue(Set(store.homeSwipePlaceIDs).isSubset(of: Set(store.places.map(\.id))))
        XCTAssertFalse(store.homeSwipePlaceIDs.contains(deletedFavorite.id))
        XCTAssertFalse(store.homeSwipePlaceIDs.contains(alsoDeleted.id))

        let persistedFavoritesData = try XCTUnwrap(UserDefaults.standard.data(forKey: favoritesKey))
        XCTAssertEqual(try JSONDecoder().decode(HomeFavorites.self, from: persistedFavoritesData), expected)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.homeFavorites, expected)
        XCTAssertEqual(restored.resolvedHomeFavorites, expected)
        XCTAssertTrue(Set(restored.homeSwipePlaceIDs).isSubset(of: Set(restored.places.map(\.id))))
        XCTAssertFalse(restored.homeSwipePlaceIDs.contains(deletedFavorite.id))
        XCTAssertFalse(restored.homeSwipePlaceIDs.contains(alsoDeleted.id))
    }

    @MainActor
    func testStoreRestorePrunesAndPersistsDeletedHomeFavorites() throws {
        let persistenceKey = "varsel.test.restore-prunes-home-favorites.\(UUID().uuidString)"
        let favoritesKey = "varsel.homeFavorites"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousFavorites = UserDefaults.standard.data(forKey: favoritesKey)
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousFavorites {
                UserDefaults.standard.set(previousFavorites, forKey: favoritesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: favoritesKey)
            }
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let home = Place(name: "Hjem", lat: 64.4, lon: 11.4)
        let retainedFavorite = Place(name: "Hytte", lat: 64.2, lon: 11.4)
        let deletedFavoriteID = UUID()
        let expectedFavorites = HomeFavorites(left: nil, right: retainedFavorite.id)
        UserDefaults.standard.set(
            try JSONEncoder().encode(HomeFavorites(left: deletedFavoriteID, right: retainedFavorite.id)),
            forKey: favoritesKey
        )
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [home, retainedFavorite], selectedID: home.id, log: []
        )), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

        XCTAssertEqual(restored.homeFavorites, expectedFavorites)
        let persistedFavorites = try XCTUnwrap(UserDefaults.standard.data(forKey: favoritesKey))
        XCTAssertEqual(try JSONDecoder().decode(HomeFavorites.self, from: persistedFavorites), expectedFavorites)

        let restarted = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restarted.homeFavorites, expectedFavorites)
        XCTAssertEqual(restarted.resolvedHomeFavorites, expectedFavorites)
        XCTAssertTrue(Set(restarted.homeSwipePlaceIDs).isSubset(of: Set(restarted.places.map(\.id))))
    }

    @MainActor
    func testReplacingPlaceListPrunesDeletedFavoritesButReorderingKeepsRemainingFavorites() throws {
        let persistenceKey = "varsel.test.replace-prunes-home-favorites.\(UUID().uuidString)"
        let favoritesKey = "varsel.homeFavorites"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousFavorites = UserDefaults.standard.data(forKey: favoritesKey)
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousFavorites {
                UserDefaults.standard.set(previousFavorites, forKey: favoritesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: favoritesKey)
            }
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let home = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let deletedFavorite = Place(name: "Hytte som forsvinner", lat: 64.2, lon: 11.4)
        let remainingFavorite = Place(name: "Hytte som består", lat: 64.1, lon: 11.5)
        let expected = HomeFavorites(left: nil, right: remainingFavorite.id)
        UserDefaults.standard.set(
            try JSONEncoder().encode(HomeFavorites(left: deletedFavorite.id, right: remainingFavorite.id)),
            forKey: favoritesKey
        )
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [home, deletedFavorite, remainingFavorite], selectedID: home.id, log: []
        )), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        store.places = [home, remainingFavorite]

        XCTAssertEqual(store.homeFavorites, expected)
        XCTAssertEqual(store.resolvedHomeFavorites, expected)
        XCTAssertFalse(store.homeSwipePlaceIDs.contains(deletedFavorite.id))
        XCTAssertTrue(Set(store.homeSwipePlaceIDs).isSubset(of: Set(store.places.map(\.id))))

        store.places = [remainingFavorite, home]
        XCTAssertEqual(store.homeFavorites, expected)
        XCTAssertEqual(store.resolvedHomeFavorites, expected)

        let persistedFavoritesData = try XCTUnwrap(UserDefaults.standard.data(forKey: favoritesKey))
        XCTAssertEqual(try JSONDecoder().decode(HomeFavorites.self, from: persistedFavoritesData), expected)
        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.homeFavorites, expected)
        XCTAssertEqual(restored.resolvedHomeFavorites, expected)
        XCTAssertFalse(restored.homeSwipePlaceIDs.contains(deletedFavorite.id))
        XCTAssertTrue(Set(restored.homeSwipePlaceIDs).isSubset(of: Set(restored.places.map(\.id))))
    }

    func testRemovingLastPlaceByIndexRestoresFallbackSelectionAndDropsItsAlerts() throws {
        let persistenceKey = "varsel.test.remove-last-place.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        var rule = Rule(type: .regn)
        rule.templateTitle = "Regn på siste sted"
        rule.threshold = 0.5
        rule.leadMinutes = 60
        let lastPlace = Place(name: "Siste sted", lat: 64.4, lon: 11.4, rules: [rule])
        let hour = ForecastHour(time: base.addingTimeInterval(3 * 3_600), temp: 8, precip: 1, wind: 2, cloud: 40, dew: 4)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [lastPlace], selectedID: lastPlace.id, log: [],
            forecasts: [lastPlace.id: [hour]],
            forecastUpdatedAt: [lastPlace.id: base],
            lastUpdate: base
        )), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(
            Planner.planAll(places: store.places, forecasts: store.forecasts, now: base)
                .filter { $0.placeID == lastPlace.id }.count,
            1,
            "Fixture must start with a notification for the place being removed"
        )
        store.removePlaces(at: IndexSet(integer: 0))

        XCTAssertEqual(store.places.map(\.name), Store.launchPlaces.map(\.name))
        let selectedID = try XCTUnwrap(store.selectedID)
        XCTAssertTrue(store.places.contains { $0.id == selectedID })
        let selectedIndex = try XCTUnwrap(store.places.firstIndex { $0.id == selectedID })
        XCTAssertEqual(store.places[selectedIndex].id, store.selected?.id)
        XCTAssertNil(store.forecasts[lastPlace.id])
        XCTAssertFalse(store.places.flatMap(\.rules).contains { $0.id == rule.id })
        XCTAssertFalse(Planner.planAll(places: store.places, forecasts: store.forecasts, now: base)
            .contains { $0.placeID == lastPlace.id })

        let persistedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: persistedData)
        XCTAssertEqual(persisted.places.map(\.id), store.places.map(\.id))
        XCTAssertEqual(persisted.selectedID, selectedID)
        XCTAssertTrue(persisted.forecasts.isEmpty)
        XCTAssertTrue(persisted.forecastUpdatedAt.isEmpty)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.places.map(\.id), store.places.map(\.id))
        XCTAssertEqual(restored.selectedID, selectedID)
        let restoredSelectedIndex = try XCTUnwrap(restored.places.firstIndex { $0.id == restored.selectedID })
        XCTAssertEqual(restored.places[restoredSelectedIndex].id, restored.selected?.id)
        XCTAssertNil(restored.forecasts[lastPlace.id])
        XCTAssertFalse(restored.places.flatMap(\.rules).contains { $0.id == rule.id })
        XCTAssertFalse(Planner.planAll(places: restored.places, forecasts: restored.forecasts, now: base)
            .contains { $0.placeID == lastPlace.id })
    }

    func testWizardRuleUpdatePreservesExistingCabinSettingsAndForecasts() throws {
        let persistenceKey = "varsel.test.wizard-update-existing-cabin.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        var existingRule = Rule(type: .vind)
        existingRule.templateTitle = "Min egen regel"
        existingRule.enabled = false
        existingRule.threshold = 13
        var home = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        home.temperatureOffset = -1.5
        var cabin = Place(
            name: "Hytte", customName: "Fjellet", lat: 64.2, lon: 11.4,
            preposition: .pa, rules: [existingRule], notificationsEnabled: false
        )
        cabin.temperatureOffset = 2.5
        cabin.rulesOnlyDisplay = true
        cabin.hiddenAlertTypes = [.regn, .vind]
        cabin.frostMargin = 1.25
        cabin.displayTemperatureThreshold = 3
        cabin.displayTemperatureHighThreshold = 24
        let homeHour = ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 40, dew: 4)
        let cabinHour = ForecastHour(time: base.addingTimeInterval(3_600), temp: 3, precip: 0, wind: 1, cloud: 75, dew: 1)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [home, cabin], selectedID: home.id, log: [],
            forecasts: [home.id: [homeHour], cabin.id: [cabinHour]],
            forecastUpdatedAt: [home.id: base, cabin.id: base.addingTimeInterval(3_600)],
            lastUpdate: base
        )), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        var updatedCabin = try XCTUnwrap(store.places.first { $0.id == cabin.id })
        let proposedRules = WizardPresetConfiguration.rules(
            selectedIDs: ["frost-natt"], for: .cabin, cabinOnlyWhenNearby: true
        )
        updatedCabin.rules = WizardPresetConfiguration.addingMissingRules(proposedRules, to: updatedCabin.rules)
        store.update(updatedCabin)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        let restoredHome = try XCTUnwrap(restored.places.first { $0.id == home.id })
        let restoredCabin = try XCTUnwrap(restored.places.first { $0.id == cabin.id })
        let preservedRule = try XCTUnwrap(restoredCabin.rules.first { $0.id == existingRule.id })
        XCTAssertEqual(restored.selectedID, home.id)
        XCTAssertEqual(restoredHome.localTemperatureOffset, -1.5)
        XCTAssertEqual(restored.forecasts[home.id], [homeHour])
        XCTAssertEqual(restored.forecasts[cabin.id], [cabinHour])
        XCTAssertEqual(restoredCabin.name, cabin.name)
        XCTAssertEqual(restoredCabin.customName, cabin.customName)
        XCTAssertFalse(restoredCabin.areNotificationsEnabled)
        XCTAssertEqual(restoredCabin.localTemperatureOffset, 2.5)
        XCTAssertTrue(restoredCabin.showsOnlyRuleAlerts)
        XCTAssertEqual(restoredCabin.hiddenAlertTypes, [.regn, .vind])
        XCTAssertEqual(restoredCabin.localFrostMargin, 1.25)
        XCTAssertEqual(restoredCabin.displayTemperatureThreshold, 3)
        XCTAssertEqual(restoredCabin.displayTemperatureHighThreshold, 24)
        XCTAssertFalse(preservedRule.enabled)
        XCTAssertEqual(preservedRule.threshold, 13)
        XCTAssertTrue(restoredCabin.rules.contains { $0.type == .frost && $0.onlyWhenNearby })
    }

    func testWizardRuleUpdatePreservesExistingHomeRulesAndIdentity() throws {
        let persistenceKey = "varsel.test.wizard-update-existing-home.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        var customRule = Rule(type: .vind)
        customRule.templateTitle = "Min vindgrense"
        customRule.threshold = 17
        customRule.enabled = false
        let home = Place(
            name: "Klinga", customName: "Hjemme", lat: 64.4, lon: 11.4,
            rules: [customRule], notificationsEnabled: false
        )
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [home], selectedID: home.id, log: []
        )), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        var updatedHome = try XCTUnwrap(store.places.first { $0.id == home.id })
        let proposedRules = WizardPresetConfiguration.rules(
            selectedIDs: ["regn-neste", "frost-natt"], for: .home, cabinOnlyWhenNearby: true
        )
        updatedHome.rules = WizardPresetConfiguration.addingMissingRules(proposedRules, to: updatedHome.rules)
        store.update(updatedHome)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        let restoredHome = try XCTUnwrap(restored.places.first { $0.id == home.id })
        let restoredCustomRule = try XCTUnwrap(restoredHome.rules.first { $0.id == customRule.id })
        XCTAssertEqual(restored.selectedID, home.id)
        XCTAssertEqual(restoredHome.name, home.name)
        XCTAssertEqual(restoredHome.customName, home.customName)
        XCTAssertFalse(restoredHome.areNotificationsEnabled)
        XCTAssertFalse(restoredCustomRule.enabled)
        XCTAssertEqual(restoredCustomRule.threshold, 17)
        XCTAssertFalse(restoredHome.rules.contains { $0.type == .frost && $0.onlyWhenNearby })
        XCTAssertEqual(restoredHome.rules.filter { $0.templateTitle == "Regn neste dag" }.count, 1)
    }

    func testWizardPresetRulesPreserveExistingMatchingAndOtherRules() {
        var existingPresetRule = Rule(type: .regn)
        existingPresetRule.templateTitle = "Regn neste dag"
        existingPresetRule.threshold = 7.5
        var otherRule = Rule(type: .vind)
        otherRule.templateTitle = "Min egen vindregel"
        let existingRules = [existingPresetRule, otherRule]
        let proposedRules = WizardPresetConfiguration.rules(
            selectedIDs: ["regn-neste", "frost-natt"],
            for: .home,
            cabinOnlyWhenNearby: false
        )

        let result = WizardPresetConfiguration.addingMissingRules(proposedRules, to: existingRules)

        XCTAssertEqual(result.map(\.id), [existingPresetRule.id, otherRule.id, proposedRules[1].id])
        XCTAssertEqual(result.first?.templateTitle, existingPresetRule.templateTitle)
        XCTAssertEqual(result.first?.threshold, 7.5)
        XCTAssertEqual(result.filter { $0.templateTitle == "Regn neste dag" }.count, 1)
        XCTAssertTrue(result.contains { $0.id == otherRule.id })
    }

    func testEveryRulePresetHasCompleteAndConsistentDisplayCopy() {
        let presets = RulePreset.all
        XCTAssertFalse(presets.isEmpty)
        XCTAssertEqual(presets.map(\.id).count, Set(presets.map(\.id)).count)

        for preset in presets {
            XCTAssertFalse(preset.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(preset.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(preset.suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(preset.rule.templateTitle, preset.title)
            XCTAssertEqual(preset.rule.memoSuggestion, preset.suggestion)
        }
    }

    func testCompactWindDoesNotInventMissingGust() {
        var hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 20, dew: 4)
        XCTAssertEqual(hour.compactWindAndGust, "– m/s")
        hour.gust = 9
        XCTAssertEqual(hour.compactWindAndGust, "9 m/s")
        hour.gust = 0
        XCTAssertEqual(hour.compactWindAndGust, "0 m/s")
    }

    func testWindPushDetailNamesBothValuesAndMissingGusts() throws {
        let rule = Rule(type: .vind)
        var hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 20, dew: 4)
        hour.gust = 9
        XCTAssertEqual(Planner.notificationEventDetail(rule: rule, hours: [hour], possible: false), "Frisk bris — vindkast opptil 9 m/s {tid} — i en time.")
        hour.gust = nil
        XCTAssertEqual(Planner.notificationEventDetail(rule: rule, hours: [hour], possible: false), "Vindkast ikke oppgitt {tid} — i en time.")
        var strong = hour
        strong.gust = 20
        let text = try XCTUnwrap(Planner.notificationEventDetail(rule: rule, hours: [hour, strong], possible: false))
        XCTAssertEqual(text, "Sterk kuling — vindkast opptil 20 m/s {tid} — i 2 timer.")
    }

    func testWindPushDetailIgnoresNonFiniteGusts() throws {
        let rule = Rule(type: .vind)
        var valid = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 20, dew: 4)
        valid.gust = 12
        let expected = try XCTUnwrap(Planner.notificationEventDetail(rule: rule, hours: [valid], possible: false))

        for invalidGust in [Double.nan, .infinity, -.infinity] {
            var invalid = valid
            invalid.gust = invalidGust
            let withInvalidSample = try XCTUnwrap(Planner.notificationEventDetail(rule: rule, hours: [invalid, valid], possible: false))
            XCTAssertTrue(withInvalidSample.hasPrefix("Liten kuling — vindkast opptil 12 m/s"))
            XCTAssertTrue(withInvalidSample.hasSuffix("{tid} — i 2 timer."))

            let onlyInvalid = try XCTUnwrap(Planner.notificationEventDetail(rule: rule, hours: [invalid], possible: false))
            XCTAssertEqual(onlyInvalid, "Vindkast ikke oppgitt {tid} — i en time.")
        }

        XCTAssertEqual(expected, "Liten kuling — vindkast opptil 12 m/s {tid} — i en time.")
    }

    func testWindStatusSeparatesWindAndGust() throws {
        var rule = Rule(type: .vind)
        rule.threshold = 9
        let place = Place(name: "Test", lat: 64, lon: 11)
        let status = WeatherStatus(ruleID: rule.id, type: .vind, text: "", eventAt: base, isNow: false)
        var hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 20, dew: 4)
        hour.gust = 9
        XCTAssertEqual(Planner.statusDetail(for: status, place: place, forecast: [hour]), "Frisk bris — vindkast opptil 9 m/s.")
        hour.gust = nil
        XCTAssertEqual(Planner.statusDetail(for: status, place: place, forecast: [hour]), "Vindkast ikke oppgitt.")
        XCTAssertTrue(weatherAlertText(for: rule, eventAt: base.addingTimeInterval(3600), referenceAt: base).hasPrefix("Vindkast "))
    }

    func testWindStatusDetailsIgnoreNonFiniteGusts() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let status = WeatherStatus(ruleID: UUID(), type: .vind, text: "", eventAt: base, isNow: true)
        let valid = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: 10, precip: 0,
            wind: 3, cloud: 20, dew: 4, gust: 12
        )

        for invalidGust in [Double.nan, .infinity, -.infinity] {
            let invalid = ForecastHour(
                time: base, temp: 10, precip: 0, wind: 3,
                cloud: 20, dew: 4, gust: invalidGust
            )
            XCTAssertEqual(
                Planner.statusDetail(for: status, place: place, forecast: [invalid, valid]),
                "Liten kuling — vindkast opptil 12 m/s."
            )
            XCTAssertEqual(
                Planner.rotatingStatusDetail(
                    for: status, place: place, forecast: [invalid, valid],
                    headlineDescribesTime: true
                ),
                "Liten kuling."
            )
            XCTAssertEqual(
                Planner.statusDetail(for: status, place: place, forecast: [invalid]),
                "Vindkast ikke oppgitt."
            )
            XCTAssertEqual(
                Planner.rotatingStatusDetail(
                    for: status, place: place, forecast: [invalid],
                    headlineDescribesTime: true
                ),
                "Vindkast ikke oppgitt."
            )
        }
    }

    func testRotatingWindDetailUsesStrengthAndActualDuration() {
        var rule = Rule(type: .vind)
        rule.threshold = 9
        var place = Place(name: "Test", lat: 64, lon: 11)
        place.rules = [rule]
        var first = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 20, dew: 4)
        first.gust = 9
        var second = ForecastHour(time: base.addingTimeInterval(3600), temp: 10, precip: 0, wind: 3, cloud: 20, dew: 4)
        second.gust = 10
        let status = WeatherStatus(ruleID: rule.id, type: .vind, text: "", eventAt: base, isNow: true)

        XCTAssertEqual(Planner.statusDetail(for: status, place: place, forecast: [first, second]), "Frisk bris i 2 timer.")
    }

    func testCustomNineMeterGustThresholdSurvivesSaving() throws {
        var rule = Rule(type: .vind)
        rule.threshold = 9
        let restored = try JSONDecoder().decode(Rule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(restored.threshold, 9)
        var hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 20, dew: 4)
        hour.gust = 8.9
        XCTAssertFalse(restored.matches(hour))
        hour.gust = 9
        XCTAssertTrue(restored.matches(hour))
    }

    func testWatchRefreshRejectsInvalidatedRequestAndPreservesLocalAdjustment() throws {
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.temperatureOffset = -2
        let hour = ForecastHour(time: base, temp: 4, precip: 0, wind: 1, cloud: 0, dew: 1)
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base)
        let revision = UUID()
        XCTAssertNil(snapshot.refreshed(with: [hour], at: base, requestRevision: revision, currentRevision: UUID()))
        XCTAssertNil(snapshot.refreshed(with: [], at: base, requestRevision: revision, currentRevision: revision))
        let refreshed = try XCTUnwrap(snapshot.refreshed(with: [hour], at: base.addingTimeInterval(60), requestRevision: revision, currentRevision: revision))
        XCTAssertEqual(refreshed.forecast.first?.temp, 2)
        XCTAssertEqual(refreshed.forecast.first?.yrTemperature, 4)
        XCTAssertEqual(refreshed.forecast.first?.wind, hour.wind)
        XCTAssertEqual(refreshed.forecast.first?.precip, hour.precip)
        XCTAssertEqual(refreshed.forecast.first?.dew, hour.dew)
        XCTAssertEqual(refreshed.place.id, place.id)
        XCTAssertEqual(refreshed.updatedAt, base.addingTimeInterval(60))
        let twice = refreshed.refreshed(with: refreshed.forecast, at: base, requestRevision: revision, currentRevision: revision)
        XCTAssertEqual(twice?.forecast.first?.temp, 2)
    }

    func testSharedWeatherLanguageForHomeAndPush() {
        let source = "Mulig regn i morgen kl. 07."
        XCTAssertEqual(WeatherLanguage.text(source, style: .bokmal), source)
        XCTAssertEqual(WeatherLanguage.text(source, style: .inntrondersk), "Mulig regn i mårrå kl. 07.")
        XCTAssertEqual(WeatherLanguage.text("I overmorgen kl. 09.", style: .inntrondersk), "I overmårrå kl. 09.")
        XCTAssertEqual(WeatherLanguage.text("Fra 2 til 4 mm", style: .inntrondersk), "Fra 2 te 4 mm")
        XCTAssertEqual(WeatherLanguage.text("Duggfall i natt kl. 02.", style: .inntrondersk), "Doggfall i natt kl. 02.")
    }

    func testDialectUsesNoEOnlyForCurrentDewStatus() {
        XCTAssertEqual(WeatherLanguage.text("Fare for dugg nå.", style: .inntrondersk), "D Dogge!")
        XCTAssertEqual(WeatherLanguage.text("Fare for dugg i natt kl. 01.", style: .inntrondersk), "Mulig doggfall i natt kl. 01.")
        XCTAssertEqual(WeatherLanguage.text("Duggfall i morgen kl. 07.", style: .inntrondersk), "Doggfall i mårrå kl. 07.")
    }

    func testDialectCurrentWeatherUsesShortSpokenMessages() {
        XCTAssertEqual(WeatherLanguage.text("Regn nå.", style: .inntrondersk), "D e Regn!")
        XCTAssertEqual(WeatherLanguage.text("Det regner!", style: .inntrondersk), "D e Regn!")
        XCTAssertEqual(WeatherLanguage.text("Mulig regn nå.", style: .inntrondersk), "D kan bli regn no.")
        XCTAssertEqual(WeatherLanguage.text("Litt regn nå.", style: .inntrondersk), "Småregn no.")
        XCTAssertEqual(WeatherLanguage.text("Snø nå.", style: .inntrondersk), "Det Snør!")
        XCTAssertEqual(WeatherLanguage.text("Vindkast nå.", style: .inntrondersk), "D Blæs!")
        XCTAssertEqual(WeatherLanguage.text("Frost nå.", style: .inntrondersk), "D Rime!")
        XCTAssertEqual(WeatherLanguage.text("Sol i 4 timer nå.", style: .inntrondersk), "D e Sol!")
    }

    func testApprovedNowHeadlinesUseSelectedLanguageForms() {
        XCTAssertEqual(LanguageCatalog.value("now.rain", language: "nb", fallback: ""), "Det Regner!")
        XCTAssertEqual(LanguageCatalog.value("now.rain", language: "tr", fallback: ""), "D e Regn!")
        XCTAssertEqual(LanguageCatalog.value("now.snow", language: "tr", fallback: ""), "Det Snør!")
        XCTAssertEqual(LanguageCatalog.value("now.frost", language: "tr", fallback: ""), "D Rime!")

        let rule = Rule(type: .regn)
        let rain = WeatherStatus(ruleID: rule.id, type: .regn, text: "", eventAt: base, isNow: true)
        XCTAssertEqual(RotatingAlertCopy.headline(for: rain, rule: rule, languageStyle: .bokmal, now: base), "Det Regner!")
        XCTAssertEqual(RotatingAlertCopy.headline(for: rain, rule: rule, languageStyle: .inntrondersk, now: base), "D e Regn!")

        let snowRule = Rule(type: .sno)
        let snow = WeatherStatus(ruleID: snowRule.id, type: .sno, text: "", eventAt: base, isNow: true)
        XCTAssertEqual(RotatingAlertCopy.headline(for: snow, rule: snowRule, languageStyle: .inntrondersk, now: base), "Det Snør!")

        let frostRule = Rule(type: .frost)
        let frost = WeatherStatus(ruleID: frostRule.id, type: .frost, text: "", eventAt: base, isNow: true)
        XCTAssertEqual(RotatingAlertCopy.headline(for: frost, rule: frostRule, languageStyle: .inntrondersk, now: base), "D Rime!")
    }

    func testWeatherGlanceUsesTwelveHoursAndOneEventPerType() {
        func event(_ type: AlertType, _ hours: Double, isNow: Bool = false) -> WeatherStatus {
            WeatherStatus(ruleID: UUID(), type: type, text: "Test", eventAt: base.addingTimeInterval(hours * 3600), isNow: isNow)
        }
        let rain = event(.regn, 1)
        let dew = event(.dugg, 12)
        let frost = event(.frost, -0.5, isNow: true)
        let input = [event(.regn, 3), dew, event(.sol, 12.01), event(.sno, -1), rain, frost]
        XCTAssertEqual(WeatherGlance.upcoming(input, now: base), [frost, rain, dew])
        XCTAssertEqual(WeatherGlance.upcoming(Array(input.reversed()), now: base), [frost, rain, dew])
        XCTAssertTrue(WeatherGlance.upcoming([], now: base).isEmpty)
    }

    func testWeatherGlanceUsesSameSeverityOrderAsPushPlanning() {
        let snow = WeatherStatus(ruleID: UUID(), type: .sno, text: "", eventAt: base.addingTimeInterval(3_600), isNow: false)
        let rain = WeatherStatus(ruleID: UUID(), type: .regn, text: "", eventAt: snow.eventAt, isNow: false)
        let result = WeatherGlance.upcoming([rain, snow], now: base)
        XCTAssertEqual(result.map(\.type), [.sno, .regn])
    }

    func testWeatherGlanceNextEventsExcludesCurrentStatus() {
        let now = base
        let current = WeatherStatus(ruleID: UUID(), type: .regn, text: "Regn nå.", eventAt: now, isNow: true)
        let next = WeatherStatus(ruleID: UUID(), type: .sno, text: "Snø om en time.", eventAt: now.addingTimeInterval(3_600), isNow: false)
        XCTAssertEqual(WeatherGlance.nextEvents([current, next], now: now).map(\.type), [.sno])
    }

    func testWidgetEmptyStatesAndRelativeTimesFollowSnapshotLanguage() {
        XCTAssertEqual(
            WeatherGlance.widgetEmptyStateText(.openPhone, languageStyle: .bokmal),
            "Åpne appen på iPhone for å hente vær."
        )
        XCTAssertEqual(
            WeatherGlance.widgetEmptyStateText(.noUpcomingAlerts, languageStyle: .bokmal),
            "Ingen kommende varsler."
        )
        XCTAssertEqual(
            WeatherGlance.widgetEmptyStateText(.noCurrentAlerts, languageStyle: .bokmal),
            "Ingen aktuelle varsler."
        )
        XCTAssertEqual(
            WeatherGlance.widgetEmptyStateText(.openPhone, languageStyle: .english),
            "Open the app on your iPhone to get weather."
        )
        XCTAssertEqual(
            WeatherGlance.widgetEmptyStateText(.noUpcomingAlerts, languageStyle: .english),
            "No upcoming alerts."
        )
        XCTAssertEqual(
            WeatherGlance.widgetEmptyStateText(.noCurrentAlerts, languageStyle: .english),
            "No current alerts."
        )

        XCTAssertEqual(
            WeatherGlance.compactRelativeTime(
                to: base.addingTimeInterval(15 * 60), from: base,
                languageStyle: .bokmal, compact: true
            ),
            "om 15m"
        )
        XCTAssertEqual(
            WeatherGlance.compactRelativeTime(
                to: base.addingTimeInterval(2 * 3_600), from: base,
                languageStyle: .bokmal, compact: true
            ),
            "om 2t"
        )
        XCTAssertEqual(
            WeatherGlance.compactRelativeTime(
                to: base.addingTimeInterval(15 * 60), from: base,
                languageStyle: .english, compact: true
            ),
            "in 15m"
        )
        XCTAssertEqual(
            WeatherGlance.compactRelativeTime(
                to: base.addingTimeInterval(2 * 3_600), from: base,
                languageStyle: .english, compact: true
            ),
            "in 2h"
        )
        XCTAssertEqual(
            WeatherGlance.compactRelativeTime(
                to: base.addingTimeInterval(15 * 60), from: base,
                languageStyle: .english, compact: false
            ),
            "in 15 min"
        )
        XCTAssertEqual(
            WeatherGlance.compactRelativeTime(
                to: base.addingTimeInterval(2 * 3_600), from: base,
                languageStyle: .english, compact: false
            ),
            "in 2h"
        )
    }

    func testWatchSectionAndEmptyStateCopyFollowsLanguageStyle() {
        XCTAssertEqual(WatchWeatherCopy.sectionTitle(.next12Hours, languageStyle: .bokmal), "Neste 12 timer")
        XCTAssertEqual(WatchWeatherCopy.sectionTitle(.currentConditions, languageStyle: .bokmal), "Nå")
        XCTAssertEqual(WatchWeatherCopy.emptyState(.noEvents, languageStyle: .bokmal), "Ingen aktuelle hendelser")
        XCTAssertEqual(WatchWeatherCopy.emptyState(.waitingTitle, languageStyle: .bokmal), "Venter på iPhone")
        XCTAssertEqual(
            WatchWeatherCopy.emptyState(.waitingDescription, languageStyle: .bokmal),
            "Åpne D bli Vær! på iPhone første gang."
        )

        XCTAssertEqual(WatchWeatherCopy.sectionTitle(.next12Hours, languageStyle: .inntrondersk), "Neste 12 tima")
        XCTAssertEqual(WatchWeatherCopy.sectionTitle(.currentConditions, languageStyle: .inntrondersk), "No")
        XCTAssertEqual(WatchWeatherCopy.emptyState(.noEvents, languageStyle: .inntrondersk), "Ingen værhendelsa no.")
        XCTAssertEqual(WatchWeatherCopy.emptyState(.waitingTitle, languageStyle: .inntrondersk), "Venter på iPhone")
        XCTAssertEqual(
            WatchWeatherCopy.emptyState(.waitingDescription, languageStyle: .inntrondersk),
            "Åpne D bli Vær! på iPhone første gang."
        )

        XCTAssertEqual(WatchWeatherCopy.sectionTitle(.next12Hours, languageStyle: .english), "Next 12 hours")
        XCTAssertEqual(WatchWeatherCopy.sectionTitle(.currentConditions, languageStyle: .english), "Now")
        XCTAssertEqual(WatchWeatherCopy.emptyState(.noEvents, languageStyle: .english), "No current weather events.")
        XCTAssertEqual(WatchWeatherCopy.emptyState(.waitingTitle, languageStyle: .english), "Waiting for iPhone")
        XCTAssertEqual(
            WatchWeatherCopy.emptyState(.waitingDescription, languageStyle: .english),
            "Open D bli Vær! on your iPhone to get started."
        )
    }

    func testWatchRefreshFailureCopyFollowsLanguageStyleWithoutErrorDetails() {
        XCTAssertEqual(
            WatchWeatherCopy.refreshFailure(languageStyle: .bokmal),
            "Kunne ikke oppdatere. Viser sist hentede vær."
        )
        XCTAssertEqual(
            WatchWeatherCopy.refreshFailure(languageStyle: .english),
            "Could not update. Showing the last fetched weather."
        )
    }

    func testWatchAndCarPlayNextEventsIgnoreExpiredNowStatus() {
        let expiredNow = WeatherStatus(
            ruleID: UUID(), type: .regn, text: "Regn nå.",
            eventAt: base.addingTimeInterval(-91 * 60), isNow: true
        )
        let next = WeatherStatus(
            ruleID: UUID(), type: .vind, text: "Vind om en time.",
            eventAt: base.addingTimeInterval(3_600), isNow: false
        )

        XCTAssertEqual(WeatherGlance.nextEvents([expiredNow, next], now: base).map(\.type), [.vind])
    }

    func testWatchAndCarPlaySharePlaceAndTwoUpcomingEventTypes() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let forecast = [ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 40, dew: 4)]
        let statuses = [
            WeatherStatus(ruleID: UUID(), type: .regn, text: "Regn", eventAt: base.addingTimeInterval(30 * 60), isNow: false),
            WeatherStatus(ruleID: UUID(), type: .vind, text: "Vind", eventAt: base.addingTimeInterval(60 * 60), isNow: false),
            WeatherStatus(ruleID: UUID(), type: .dugg, text: "Duggfall", eventAt: base.addingTimeInterval(2 * 60 * 60), isNow: false),
            WeatherStatus(ruleID: UUID(), type: .sol, text: "Sol", eventAt: base.addingTimeInterval(3 * 60 * 60), isNow: false),
        ]
        XCTAssertEqual(WeatherGlance.widgetEvents(statuses, now: base).map(\.type), [.regn, .vind])

        SharedWidgetData.clear()
        defer { SharedWidgetData.clear() }
        XCTAssertTrue(SharedWidgetData.save(place: place, forecast: forecast, updatedAt: base))
        XCTAssertTrue(SharedWidgetData.saveSharedPlaces([place]))
        let transferred = try JSONDecoder().decode(
            WatchWeatherTransfer.self,
            from: JSONEncoder().encode(WatchWeatherTransfer(snapshot: SharedWidgetData.load(), sentAt: base))
        )
        XCTAssertEqual(SharedWidgetData.loadSharedPlaces().map(\.id), [place.id])
        XCTAssertEqual(transferred.snapshot?.place.id, place.id)
    }

    func testCompactEventLabelUsesConfiguredTemperatureDirection() {
        let under = WeatherStatus(ruleID: UUID(), type: .temperatur, text: "Under 10° i morgen.", eventAt: base, isNow: false)
        let over = WeatherStatus(ruleID: UUID(), type: .temperatur, text: "Over 20° i morgen.", eventAt: base, isNow: false)
        XCTAssertEqual(WeatherGlance.compactEventLabel(for: under), "<10°")
        XCTAssertEqual(WeatherGlance.compactEventLabel(for: over), ">20°")
        let dew = WeatherStatus(ruleID: UUID(), type: .dugg, text: "Duggfall", eventAt: base, isNow: false)
        XCTAssertEqual(WeatherGlance.compactEventLabel(for: dew, languageStyle: .bokmal), "Dugg!")
        XCTAssertEqual(WeatherGlance.compactEventLabel(for: dew, languageStyle: .inntrondersk), "Dogg!")
    }

    func testGlanceFreshnessDistinguishesFreshAndStaleSnapshots() throws {
        let fresh = try XCTUnwrap(WeatherGlance.freshness(
            updatedAt: base,
            now: base.addingTimeInterval(30 * 60),
            languageStyle: .bokmal
        ))
        XCTAssertFalse(fresh.isStale)
        XCTAssertTrue(fresh.label.hasPrefix("Oppdatert "))

        let atBoundary = try XCTUnwrap(WeatherGlance.freshness(
            updatedAt: base,
            now: base.addingTimeInterval(2 * 3_600),
            languageStyle: .bokmal
        ))
        XCTAssertFalse(atBoundary.isStale)

        let stale = try XCTUnwrap(WeatherGlance.freshness(
            updatedAt: base,
            now: base.addingTimeInterval(2 * 3_600 + 1),
            languageStyle: .bokmal
        ))
        XCTAssertTrue(stale.isStale)
        XCTAssertTrue(stale.label.contains("utdatert"))
        XCTAssertTrue(stale.label.contains("3 t siden"))

        let threeHours = try XCTUnwrap(WeatherGlance.freshness(
            updatedAt: base,
            now: base.addingTimeInterval(3 * 3_600),
            languageStyle: .bokmal
        ))
        XCTAssertTrue(threeHours.isStale)
        XCTAssertTrue(threeHours.label.contains("3 t siden"))

        let justOverThreeHours = try XCTUnwrap(WeatherGlance.freshness(
            updatedAt: base,
            now: base.addingTimeInterval(3 * 3_600 + 1),
            languageStyle: .bokmal
        ))
        XCTAssertTrue(justOverThreeHours.label.contains("4 t siden"))

        let english = try XCTUnwrap(WeatherGlance.freshness(
            updatedAt: base,
            now: base.addingTimeInterval(2 * 3_600 + 1),
            languageStyle: .english
        ))
        XCTAssertTrue(english.isStale)
        XCTAssertTrue(english.label.contains("May be outdated"))
        XCTAssertTrue(english.label.contains("3h ago"))
    }

    func testGlanceFreshnessClockUsesSnapshotLanguageLocale() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let updatedAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2030, month: 1, day: 1, hour: 14, minute: 7
        )))
        let now = updatedAt.addingTimeInterval(30 * 60)

        XCTAssertEqual(
            WeatherGlance.freshness(updatedAt: updatedAt, now: now, languageStyle: .bokmal)?.label,
            "Oppdatert 14:07"
        )
        XCTAssertEqual(
            WeatherGlance.freshness(updatedAt: updatedAt, now: now, languageStyle: .inntrondersk)?.label,
            "Oppdatert 14:07"
        )
        XCTAssertEqual(
            WeatherGlance.freshness(updatedAt: updatedAt, now: now, languageStyle: .english)?.label,
            "Updated 14:07"
        )
    }

    func testGlanceEventNamesAreReadableAndLocalized() {
        let rain = WeatherStatus(
            ruleID: UUID(), type: .regn, text: "Regn", eventAt: base, isNow: false
        )
        XCTAssertEqual(WeatherGlance.eventName(for: rain, languageStyle: .bokmal), "Regn")
        XCTAssertEqual(WeatherGlance.eventName(for: rain, languageStyle: .english), "Rain")
        let dew = WeatherStatus(
            ruleID: UUID(), type: .dugg, text: "Dugg", eventAt: base, isNow: false
        )
        XCTAssertEqual(WeatherGlance.eventName(for: dew, languageStyle: .inntrondersk), "Dogg")
    }

    func testWatchMetricLabelsFollowSnapshotLanguageStyle() {
        XCTAssertEqual(WeatherGlance.metricLabel(for: .precipitation, languageStyle: .bokmal), "Nedbør")
        XCTAssertEqual(WeatherGlance.metricLabel(for: .windGusts, languageStyle: .bokmal), "Vindkast")
        XCTAssertEqual(WeatherGlance.metricLabel(for: .dewPoint, languageStyle: .bokmal), "Duggpunkt")
        XCTAssertEqual(WeatherGlance.metricLabel(for: .precipitation, languageStyle: .english), "Precipitation")
        XCTAssertEqual(WeatherGlance.metricLabel(for: .windGusts, languageStyle: .english), "Wind gusts")
        XCTAssertEqual(WeatherGlance.metricLabel(for: .dewPoint, languageStyle: .english), "Dew point")
    }

    func testInntronderskCompactLabelsArePresentForEveryAlertType() {
        for type in AlertType.allCases {
            let status = WeatherStatus(
                ruleID: UUID(), type: type, text: "Test", eventAt: base, isNow: false
            )
            XCTAssertFalse(
                WeatherGlance.compactEventLabel(for: status, languageStyle: .inntrondersk).isEmpty,
                "Mangler kortetikett for \(type)"
            )
        }
    }

    func testLocalAdjustmentPreservesYrAndDoesNotAccumulate() throws {
        let hour = ForecastHour(time: base, temp: 4, precip: 0, wind: 1, cloud: 0, dew: 1)
        let local = hour.locallyAdjusted(by: -2)
        XCTAssertEqual(local.temp, 2)
        XCTAssertEqual(local.yrTemperature, 4)
        XCTAssertEqual(local.locallyAdjusted(by: -2).temp, 2)
        XCTAssertEqual(local.locallyAdjusted(by: 0), hour)
        let frost = Rule(type: .frost)
        XCTAssertFalse(frost.matches(local))
        XCTAssertTrue(frost.matches(local, frostMargin: 2.5))
        var place = Place(name: "Test", lat: 64, lon: 11)
        place.temperatureOffset = -2
        let decoded = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(place))
        XCTAssertEqual(decoded.localTemperatureOffset, -2)
    }

    func testFrostMarginSnapshotRoundTripKeepsRawYrTemperature() throws {
        var place = Place(name: "Klinga", lat: 64.4, lon: 11.5)
        place.frostMargin = 2.5
        let hour = ForecastHour(time: base, temp: 1.5, precip: 0, wind: 1, cloud: 20, dew: 0.5, yrTemperature: 1.5)
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base)
        let restored = try JSONDecoder().decode(
            WidgetWeatherSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(restored.place.localFrostMargin, 2.5)
        XCTAssertEqual(restored.forecast.first?.temp, 1.5)
        XCTAssertEqual(restored.forecast.first?.yrTemperature, 1.5)
    }

    func testDewMatchingUsesRawDewPointAfterLocalTemperatureAdjustment() {
        let hour = ForecastHour(time: base, temp: 6, precip: 0, wind: 1, cloud: 20, dew: 5)
        let adjusted = hour.locallyAdjusted(by: -1)
        var rule = Rule(type: .dugg)
        rule.threshold = 1

        XCTAssertTrue(rule.matches(adjusted))
        XCTAssertEqual(adjusted.dew, hour.dew)
        XCTAssertEqual(adjusted.yrTemperature, 6)
    }

    func testCalibrationKeepsEvidenceAfterRollingHistoryExpires() throws {
        let place = Place(name: "Test", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 4, precip: 0, wind: 1, cloud: 0, dew: 1)
        let old = CalibrationForecast(place: place, fetchedAt: base.addingTimeInterval(-3600), hours: [hour])
        let future = CalibrationForecast(place: place, fetchedAt: base.addingTimeInterval(60), hours: [hour.locallyAdjusted(by: 8)])
        var history = CalibrationHistory(forecasts: [old, future])
        let observation = history.observation(place: place, at: base, temperature: 1, frost: nil, surface: "", now: base)
        XCTAssertEqual(observation.forecastFetchedAt, old.fetchedAt)
        XCTAssertEqual(observation.suggestedTemperatureOffset, -3)
        history.observations = [observation]
        history.prune(now: base.addingTimeInterval(49 * 3600))
        XCTAssertTrue(history.forecasts.isEmpty)
        let decoded = try JSONDecoder().decode(CalibrationHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded.observations.first?.evidence.first?.temp, 4)
    }

    func testRecordingEmptyForecastPersistsPrunedCalibrationHistory() throws {
        let key = "varsel.calibrationForecasts.v1"
        let defaults = UserDefaults.standard
        let previousValue = defaults.data(forKey: key)
        defer {
            if let previousValue { defaults.set(previousValue, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let place = Place(name: "Test", lat: 64, lon: 11)
        let expired = CalibrationForecast(
            place: place, fetchedAt: base.addingTimeInterval(-49 * 3_600), hours: []
        )
        var history = CalibrationHistory(forecasts: [expired])

        history.record(place: place, hours: [], fetchedAt: base)

        let saved = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertTrue(try JSONDecoder().decode([CalibrationForecast].self, from: saved).isEmpty)
        XCTAssertTrue(history.forecasts.isEmpty)
    }

    func testCalibrationObservationPageStopsAfterRequestedNumberOfPlaceMatches() {
        let reference = base
        let home = Place(name: "Home", lat: 64, lon: 11)
        let cabin = Place(name: "Cabin", lat: 65, lon: 12)
        func observation(_ place: Place, _ minute: Int) -> LocalWeatherObservation {
            LocalWeatherObservation(
                place: place,
                observedAt: reference.addingTimeInterval(TimeInterval(-minute * 60)),
                registeredAt: reference,
                measuredTemperature: nil,
                frost: minute.isMultiple(of: 2),
                surface: "Grass",
                forecastFetchedAt: nil,
                evidence: [],
                nightForecast: nil
            )
        }
        let history = CalibrationHistory(observations: [
            observation(home, 1), observation(cabin, 2), observation(home, 3), observation(home, 4)
        ])

        XCTAssertEqual(history.observations(for: home.id, limit: 2).map(\.observedAt), [
            reference.addingTimeInterval(-60), reference.addingTimeInterval(-180)
        ])
        XCTAssertTrue(history.observations(for: home.id, limit: 0).isEmpty)
        XCTAssertTrue(history.observations(for: home.id, limit: -1).isEmpty)
    }

    func testCalibrationLargeObservationHistoryMigratesOutOfUserDefaults() throws {
        let place = Place(name: "Test", lat: 64, lon: 11)
        let observations = (0..<1_200).map { index in
            LocalWeatherObservation(
                place: place,
                observedAt: base.addingTimeInterval(TimeInterval(-index * 60)),
                registeredAt: base,
                measuredTemperature: Double(index % 30),
                frost: nil,
                surface: "",
                forecastFetchedAt: nil,
                evidence: [],
                nightForecast: nil
            )
        }
        let legacyHistory = CalibrationHistory(observations: observations)
        let suiteName = "varsel.test.calibration-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-test-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = directory.appendingPathComponent("observations.json")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(try JSONEncoder().encode(legacyHistory), forKey: "varsel.calibrationHistory.v1")

        let restored = CalibrationHistory.load(now: base, defaults: defaults, observationsURL: archiveURL)

        XCTAssertEqual(restored.observations.count, observations.count)
        XCTAssertEqual(restored.observations.first?.id, observations.first?.id)
        XCTAssertEqual(restored.observations.last?.id, observations.last?.id)
        XCTAssertNil(defaults.object(forKey: "varsel.calibrationHistory.v1"))
        let storedForecasts = try XCTUnwrap(defaults.data(forKey: "varsel.calibrationForecasts.v1"))
        XCTAssertTrue(try JSONDecoder().decode([CalibrationForecast].self, from: storedForecasts).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    func testUnreadableCalibrationArchiveIsQuarantinedBeforeLaterSave() throws {
        let suiteName = "varsel.test.calibration-corrupt-archive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-corrupt-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = directory.appendingPathComponent("observations.json")
        let corruptData = Data("{not valid JSON".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: archiveURL)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        var history = CalibrationHistory.load(now: base, defaults: defaults, observationsURL: archiveURL)

        XCTAssertTrue(history.observations.isEmpty)
        let recoveryFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".unreadable-") }
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveryFiles[0]), corruptData)

        let place = Place(name: "Home", lat: 64, lon: 11)
        history.observations = [LocalWeatherObservation(
            place: place, observedAt: base, registeredAt: base,
            measuredTemperature: nil, frost: nil, surface: "",
            forecastFetchedAt: nil, evidence: [], nightForecast: nil
        )]
        XCTAssertTrue(history.saveObservations(to: archiveURL))
        XCTAssertEqual(
            try JSONDecoder().decode([LocalWeatherObservation].self, from: Data(contentsOf: archiveURL)).map(\.id),
            history.observations.map(\.id)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryFiles[0].path))
    }

    func testUnreadableCalibrationForecastBlobIsPreservedWhileObservationsLoad() throws {
        let suiteName = "varsel.test.calibration-corrupt-forecasts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-forecast-corrupt-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = directory.appendingPathComponent("observations.json")
        let corruptData = Data("truncated forecast archive".utf8)
        let place = Place(name: "Home", lat: 64, lon: 11)
        let observation = LocalWeatherObservation(
            place: place, observedAt: base, registeredAt: base,
            measuredTemperature: 3, frost: nil, surface: "",
            forecastFetchedAt: nil, evidence: [], nightForecast: nil
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([observation]).write(to: archiveURL)
        defaults.set(corruptData, forKey: "varsel.calibrationForecasts.v1")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        var history = CalibrationHistory.load(now: base, defaults: defaults, observationsURL: archiveURL)

        XCTAssertEqual(history.observations.map(\.id), [observation.id])
        XCTAssertNil(defaults.data(forKey: "varsel.calibrationForecasts.v1"))
        let recoveryKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("varsel.calibrationForecasts.v1.unreadable.") }
        XCTAssertEqual(recoveryKeys.count, 1)
        let recoveryKey = try XCTUnwrap(recoveryKeys.first)
        XCTAssertEqual(defaults.data(forKey: recoveryKey), corruptData)

        history.record(place: place, hours: [], fetchedAt: base)

        XCTAssertEqual(defaults.data(forKey: "varsel.calibrationForecasts.v1"), try JSONEncoder().encode([CalibrationForecast]()))
        XCTAssertEqual(defaults.data(forKey: recoveryKey), corruptData)
        XCTAssertEqual(
            try JSONDecoder().decode([LocalWeatherObservation].self, from: Data(contentsOf: archiveURL)).map(\.id),
            [observation.id]
        )
    }

    func testMalformedCalibrationForecastRowIsDroppedWithoutLosingValidRowsOrRawArchive() throws {
        let suiteName = "varsel.test.calibration-partial-forecast-corruption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-partial-forecast-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = directory.appendingPathComponent("observations.json")
        let place = Place(name: "Home", lat: 64, lon: 11)
        let forecast = CalibrationForecast(
            place: place,
            fetchedAt: base,
            hours: [ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4)]
        )
        let validRow = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: JSONEncoder().encode([forecast])) as? [[String: Any]])?.first
        )
        let corruptData = try JSONSerialization.data(withJSONObject: [validRow, "not a forecast row"])
        defaults.set(corruptData, forKey: "varsel.calibrationForecasts.v1")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        var history = CalibrationHistory.load(now: base, defaults: defaults, observationsURL: archiveURL)

        XCTAssertEqual(history.forecasts.map(\.id), [forecast.id])
        let normalizedData = try XCTUnwrap(defaults.data(forKey: "varsel.calibrationForecasts.v1"))
        XCTAssertEqual(try JSONDecoder().decode([CalibrationForecast].self, from: normalizedData).map(\.id), [forecast.id])
        let recoveryKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix("varsel.calibrationForecasts.v1.unreadable.") }
        XCTAssertEqual(recoveryKeys.count, 1)
        let recoveryKey = try XCTUnwrap(recoveryKeys.first)
        XCTAssertEqual(defaults.data(forKey: recoveryKey), corruptData)

        history.record(place: place, hours: [], fetchedAt: base)
        XCTAssertEqual(defaults.data(forKey: recoveryKey), corruptData)
        let relaunched = CalibrationHistory.load(now: base, defaults: defaults, observationsURL: archiveURL)
        XCTAssertEqual(relaunched.forecasts.map(\.id), [forecast.id])
        XCTAssertEqual(
            defaults.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("varsel.calibrationForecasts.v1.unreadable.")
            }.count,
            1
        )
    }

    func testUnreadableCalibrationArchiveFallsBackToLegacyAndMigratesSafely() throws {
        let suiteName = "varsel.test.calibration-corrupt-legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-legacy-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = directory.appendingPathComponent("observations.json")
        let corruptData = Data("truncated archive".utf8)
        let place = Place(name: "Home", lat: 64, lon: 11)
        let legacy = CalibrationHistory(observations: [LocalWeatherObservation(
            place: place, observedAt: base, registeredAt: base,
            measuredTemperature: 3, frost: nil, surface: "",
            forecastFetchedAt: nil, evidence: [], nightForecast: nil
        )])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: archiveURL)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "varsel.calibrationHistory.v1")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let restored = CalibrationHistory.load(now: base, defaults: defaults, observationsURL: archiveURL)

        XCTAssertEqual(restored.observations.map(\.id), legacy.observations.map(\.id))
        XCTAssertNil(defaults.object(forKey: "varsel.calibrationHistory.v1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        let recoveryFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".unreadable-") }
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveryFiles[0]), corruptData)
        XCTAssertEqual(
            try JSONDecoder().decode([LocalWeatherObservation].self, from: Data(contentsOf: archiveURL)).map(\.id),
            legacy.observations.map(\.id)
        )
    }

    func testFrostObservationUsesForecastFromBeforeNight() {
        let morning = Calendar.current.startOfDay(for: base).addingTimeInterval(7 * 3600)
        let place = Place(name: "Test", lat: 64, lon: 11)
        let hour = ForecastHour(time: morning.addingTimeInterval(-3600), temp: 3, precip: 0, wind: 1, cloud: 0, dew: 1)
        let evening = CalibrationForecast(place: place, fetchedAt: morning.addingTimeInterval(-10 * 3600), hours: [hour])
        let latest = CalibrationForecast(place: place, fetchedAt: morning.addingTimeInterval(-1800), hours: [hour])
        let history = CalibrationHistory(forecasts: [evening, latest])
        let observed = history.observation(place: place, at: morning, temperature: nil, frost: true, surface: "Gress", now: morning)
        XCTAssertEqual(observed.forecastFetchedAt, evening.fetchedAt)
        XCTAssertEqual(observed.evidence.count, 1)
        XCTAssertNil(observed.suggestedTemperatureOffset)
        XCTAssertTrue(CalibrationHistory().observation(place: place, at: morning, temperature: nil, frost: true, surface: "Gress", now: morning).evidence.isEmpty)
    }

    private func forecast(values: [(temp: Double, precip: Double, wind: Double, cloud: Double, dew: Double)]) -> [ForecastHour] {
        values.enumerated().map { index, value in
            ForecastHour(
                time: base.addingTimeInterval(TimeInterval(index * 3_600)),
                temp: value.temp,
                precip: value.precip,
                wind: value.wind,
                cloud: value.cloud,
                dew: value.dew
            )
        }
    }

    func testRainRuleFindsFirstHitAndAllMatchingTimelineHours() {
        var rule = Rule(type: .regn)
        rule.threshold = 0.5
        rule.leadMinutes = 60
        rule.count = 1
        let hours = forecast(values: [
            (5, 0, 2, 80, 2),
            (5, 1, 2, 80, 2),
            (5, 2, 2, 80, 2),
        ])

        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: base.addingTimeInterval(-60))

        XCTAssertEqual(result.eventAt, hours[1].time)
        XCTAssertEqual(result.hitIndices, Set([1, 2]))
        XCTAssertEqual(result.alerts.count, 1)
    }

    func testPastNotificationsAreRemovedFromPlan() {
        var rule = Rule(type: .vind)
        rule.threshold = 10
        rule.leadMinutes = 60
        rule.count = 3
        rule.intervalMinutes = 30
        var hours = forecast(values: [(5, 0, 12, 80, 2)])
        hours[0].gust = 12

        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: base)

        XCTAssertEqual(result.eventAt, base)
        XCTAssertTrue(result.alerts.isEmpty)
    }

    func testPastFirstEventDoesNotHideLaterSchedulableEvent() {
        var rule = Rule(type: .regn)
        rule.threshold = 0.5
        rule.leadMinutes = 60
        let hours = forecast(values: [
            (5, 1, 2, 80, 2),
            (5, 0, 2, 80, 2),
            (5, 0, 2, 80, 2),
            (5, 1, 2, 80, 2),
        ])

        let result = Planner.plan(
            rule: rule,
            forecast: hours,
            placeName: "Namsos",
            now: base.addingTimeInterval(30 * 60)
        )

        XCTAssertEqual(result.eventAt, hours[3].time)
        XCTAssertEqual(result.alerts.first?.fireAt, hours[2].time)
    }

    func testStatusKeepsNearEventAfterItsNotificationTimeHasPassed() {
        var rule = Rule(type: .regn)
        rule.threshold = 0.5
        rule.leadMinutes = 120
        let hours = forecast(values: [
            (5, 0, 2, 80, 2),
            (5, 1, 2, 80, 2),
            (5, 0, 2, 80, 2),
            (5, 1, 2, 80, 2),
        ])
        let now = base.addingTimeInterval(30 * 60)

        let status = Planner.status(for: rule, forecast: hours, now: now)
        let notificationPlan = Planner.plan(rule: rule, forecast: hours, placeName: "Namsos", now: now)

        XCTAssertEqual(status?.eventAt, hours[1].time)
        XCTAssertEqual(notificationPlan.eventAt, hours[3].time)
    }

    func testStatusRemainsAvailableWithShortPartialForecast() {
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        var rule = Rule(type: .dugg)
        rule.threshold = 9
        place.rules = [rule]
        let hours = forecast(values: [(8, 0, 1, 90, 8)])
        let status = Planner.statuses(for: place, forecast: hours, now: base)
        XCTAssertEqual(status.first?.type, .dugg)
        XCTAssertTrue(status.first?.isNow == true)
    }

    func testMissingForecastHoursAreNotTreatedAsDry() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 1, hour: 7)))
        let missingHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: start))
        let lastHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 2, to: start))
        let forecast = [
            ForecastHour(time: start, temp: 12, precip: 0, wind: 1, cloud: 40, dew: 6),
            ForecastHour(time: lastHour, temp: 12, precip: 0, wind: 1, cloud: 40, dew: 6),
        ]

        XCTAssertEqual(
            ForecastHourSelection.missingHours(in: start..<lastHour.addingTimeInterval(3_600), forecast: forecast, calendar: calendar),
            [missingHour]
        )
        XCTAssertEqual(
            ForecastHourSelection.missingHourOffsets(
                in: start..<lastHour.addingTimeInterval(3_600), startingAt: 7,
                slotCount: 3, forecast: forecast, calendar: calendar
            ),
            [1]
        )
    }

    func testForecastGapAccessibilityExplainsUnknownIsNotDry() {
        XCTAssertTrue(ForecastGapAccessibility.explanation.contains("Yr-prognose mangler"))
        XCTAssertTrue(ForecastGapAccessibility.explanation.contains("ukjent"))
        XCTAssertTrue(ForecastGapAccessibility.explanation.contains("ikke opphold"))
    }

    func testWeatherBandAccessibilityLabelsFollowSelectedLanguage() {
        let englishCombined = WeatherBandAccessibility.combinedTrackLabel(
            type: .regn, ruleCount: 2, languageStyle: .english
        )
        XCTAssertEqual(
            englishCombined,
            "Rain, combined from 2 rules. A hatched area means the Yr forecast is missing; the weather is unknown, not dry."
        )
        XCTAssertEqual(
            WeatherBandAccessibility.combinedTrackLabel(
                type: .temperatur, ruleCount: 1, languageStyle: .english
            ),
            "Temperature, combined from 1 rule. A hatched area means the Yr forecast is missing; the weather is unknown, not dry."
        )
        XCTAssertTrue(WeatherBandAccessibility.combinedTrackLabel(
            type: .regn, ruleCount: 2, languageStyle: .bokmal
        ).contains("Regn, samlet fra 2 regler"))
        XCTAssertTrue(WeatherBandAccessibility.combinedTrackLabel(
            type: .regn, ruleCount: 2, languageStyle: .inntrondersk
        ).contains("samlet fra 2 regler"))
        XCTAssertTrue(WeatherBandAccessibility.moistureTrackLabel(languageStyle: .english)
            .hasPrefix("Precipitation: rain, snow, and dew risk"))
        XCTAssertTrue(WeatherBandAccessibility.missingForecastCellLabel(languageStyle: .english)
            .contains("weather is unknown"))
    }

    func testTimelineDetailAccessibilityLabelsFollowSelectedLanguage() {
        let styles: [(AlertLanguageStyle, String, String, String)] = [
            (.bokmal, "Temperatur 7 grader", "Nå er klokken 12:34", "Skodde, styrke 50 prosent"),
            (.inntrondersk, "Temperatur 7 grader", "No e klokka 12:34", "Skodde, styrke 50 prosent"),
            (.english, "Temperature 7 degrees", "Current time, 12:34", "Fog, strength 50 percent"),
        ]
        for (style, temperature, now, fog) in styles {
            XCTAssertEqual(WeatherBandAccessibility.temperatureValueLabel(7, languageStyle: style), temperature)
            XCTAssertEqual(WeatherBandAccessibility.nowMarkerLabel(clock: "12:34", languageStyle: style), now)
            XCTAssertEqual(WeatherBandAccessibility.fogLevelLabel(50, languageStyle: style), fog)
        }
    }

    func testMissingForecastOffsetsCoverCompressedMorningAndAllWeatherBands() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 1)))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let gaps: [(startHour: Int, slotCount: Int, missingHour: Int, expectedOffset: Int)] = [
            (5, 2, 6, 1),   // Compressed 05–07 morning cell.
            (7, 8, 9, 2),   // 07–15 daytime band.
            (15, 8, 20, 5), // 15–23 evening band.
            (23, 8, 3, 4),  // 23–07 night band, missing at 03 next day.
        ]

        for gap in gaps {
            let interval = try XCTUnwrap(ForecastHourSelection.bandInterval(
                on: day, startingAt: gap.startHour, slotCount: gap.slotCount, calendar: calendar
            ))
            let missingTime = try XCTUnwrap(calendar.date(
                bySettingHour: gap.missingHour,
                minute: 0,
                second: 0,
                of: gap.startHour == 23 ? nextDay : day
            ))
            var forecast: [ForecastHour] = []
            var time = interval.lowerBound
            while time < interval.upperBound {
                if time != missingTime {
                    forecast.append(ForecastHour(
                        time: time, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7
                    ))
                }
                time = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: time))
            }

            XCTAssertEqual(
                ForecastHourSelection.missingHourOffsets(
                    in: interval, startingAt: gap.startHour, slotCount: gap.slotCount,
                    forecast: forecast, calendar: calendar
                ),
                [gap.expectedOffset],
                "Missing \(gap.missingHour):00 must keep its hatch in the \(gap.startHour) band."
            )
        }
    }

    func testMissingForecastOffsetsStayWithinWeatherBandBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 1)))
        let periods: [(startHour: Int, slotCount: Int)] = [(5, 2), (7, 8), (15, 8), (23, 8)]

        for period in periods {
            let interval = try XCTUnwrap(ForecastHourSelection.bandInterval(
                on: day, startingAt: period.startHour, slotCount: period.slotCount, calendar: calendar
            ))
            let beforeStart = try XCTUnwrap(calendar.date(byAdding: .hour, value: -1, to: interval.lowerBound))
            let lastInBand = try XCTUnwrap(calendar.date(byAdding: .hour, value: -1, to: interval.upperBound))
            let afterEnd = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: interval.upperBound))
            var completeForecast: [ForecastHour] = []
            var time = beforeStart
            while time <= afterEnd {
                completeForecast.append(ForecastHour(
                    time: time, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7
                ))
                time = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: time))
            }

            let boundaryCases: [(missing: Date, expectedOffset: Int?)] = [
                (beforeStart, nil),
                (interval.lowerBound, 0),
                (lastInBand, period.slotCount - 1),
                (interval.upperBound, nil),
            ]
            for boundary in boundaryCases {
                let forecast = completeForecast.filter { $0.time != boundary.missing }
                let offsets = ForecastHourSelection.missingHourOffsets(
                    in: interval, startingAt: period.startHour, slotCount: period.slotCount,
                    forecast: forecast, calendar: calendar
                )
                XCTAssertEqual(
                    offsets,
                    boundary.expectedOffset.map { [$0] } ?? [],
                    "A missing hour must remain inside the \(period.startHour) band."
                )
            }
        }
    }

    func testThirdForecastDayHatchesMissingYrHoursWithoutPlanningPushAlerts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 1)))
        let days = (0..<3).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDay) }
        let visibleDays = ForecastDaySelection.visibleDays(
            from: days.map { ForecastDay(date: $0, hours: []) },
            now: firstDay.addingTimeInterval(12 * 3_600),
            calendar: calendar
        )
        let thirdDay = try XCTUnwrap(visibleDays.last?.date)
        let interval = try XCTUnwrap(ForecastHourSelection.bandInterval(
            on: thirdDay, startingAt: 15, slotCount: 8, calendar: calendar
        ))
        var hours: [ForecastHour] = []
        var time = interval.lowerBound
        while time < interval.upperBound {
            if calendar.component(.hour, from: time) < 21 {
                hours.append(ForecastHour(time: time, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7))
            }
            time = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: time))
        }

        XCTAssertEqual(
            ForecastHourSelection.missingHourOffsets(
                in: interval, startingAt: 15, slotCount: 8, forecast: hours, calendar: calendar
            ),
            [6, 7],
            "The visible third day's unprovided evening cells should remain visibly hatched."
        )

        var place = Place(name: "Klinga", lat: 64, lon: 11)
        var pushRule = Rule(type: .vind)
        pushRule.threshold = 100
        place.rules = [pushRule]
        XCTAssertTrue(Planner.planAll(places: [place], forecasts: [place.id: hours], now: firstDay).isEmpty)
    }

    func testRollingStatusesUseDisplaySolarThresholdWithoutPushRule() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let now = base.addingTimeInterval(6 * 3_600)
        let hour = ForecastHour(time: now, temp: 12, precip: 0, wind: 1, cloud: 30, dew: 6)

        // The row's second solar threshold is 40%, while the default push
        // rule is stricter (20%) and requires four hours. The rolling card
        // must still describe the visible yellow cell, without creating push.
        var displayPlace = place
        displayPlace.displaySunThreshold2 = 40
        let rolling = Planner.rollingStatuses(for: displayPlace, forecast: [hour], now: now)
        XCTAssertEqual(rolling.first?.type, .sol)
        XCTAssertTrue(rolling.first?.isNow == true)
        XCTAssertTrue(
            Planner.planAll(places: [displayPlace], forecasts: [displayPlace.id: [hour]]).isEmpty
        )
    }

    func testRollingSolarStatusAndCurrentIconUseActualTimeAfterSunset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9)))
        let samples = try (0..<(24 * 60)).map { minute in
            try XCTUnwrap(calendar.date(byAdding: .minute, value: minute, to: day))
        }
        let sunset = try XCTUnwrap(samples.first { sample in
            !SolarCycle.isDaylight(sample, latitude: 64.46, longitude: 11.50, calendar: calendar)
                && calendar.date(byAdding: .minute, value: -1, to: sample).map {
                    SolarCycle.isDaylight($0, latitude: 64.46, longitude: 11.50, calendar: calendar)
                } == true
        })
        let latestForecastTime = try XCTUnwrap(calendar.date(byAdding: .minute, value: -10, to: sunset))
        let now = try XCTUnwrap(calendar.date(byAdding: .minute, value: 5, to: sunset))
        XCTAssertTrue(SolarCycle.isDaylight(latestForecastTime, latitude: 64.46, longitude: 11.50, calendar: calendar))
        XCTAssertFalse(SolarCycle.isDaylight(now, latitude: 64.46, longitude: 11.50, calendar: calendar))

        var place = Place(name: "Klinga", lat: 64.46, lon: 11.50)
        place.displaySunThreshold2 = 40
        let lastDaylightHour = ForecastHour(
            time: latestForecastTime, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4
        )
        let rolling = Planner.rollingStatuses(for: place, forecast: [lastDaylightHour], now: now)

        XCTAssertFalse(rolling.contains { $0.type == .sol && $0.isNow })
    }

    func testDeletedRuleImmediatelyDisappearsFromWidgetEventSource() {
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        var rule = Rule(type: .regn)
        rule.threshold = 0.1
        place.rules = [rule]
        let hours = forecast(values: [(8, 1, 1, 90, 6)])
        XCTAssertEqual(Planner.statuses(for: place, forecast: hours, now: base).map(\.type), [.regn])

        place.rules = []
        XCTAssertTrue(Planner.statuses(for: place, forecast: hours, now: base).isEmpty)
    }

    func testSunAlertTextUsesLongerMatchedDurationThanMinimum() {
        var rule = Rule(type: .sol)
        rule.durationHours = 4
        let text = weatherAlertText(
            for: rule,
            eventAt: base.addingTimeInterval(3_600),
            referenceAt: base,
            durationHours: 7
        )
        XCTAssertTrue(text.contains("Sol i 7 timer"))
    }

    func testEventTimePhraseUsesProvidedTimezoneForDayBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(from: DateComponents(year: 2030, month: 1, day: 1, hour: 23))!
        let event = calendar.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 6))!
        XCTAssertEqual(eventTimePhrase(event, relativeTo: reference, calendar: calendar), "i morgen, onsdag kl. 06")
    }

    func testSharedWidgetDataSkipsIdenticalEncodedSnapshot() {
        let data = Data("snapshot".utf8)
        XCTAssertFalse(SharedWidgetData.shouldWrite(existing: data, new: data))
        XCTAssertTrue(SharedWidgetData.shouldWrite(existing: nil, new: data))
        XCTAssertTrue(SharedWidgetData.shouldWrite(existing: Data("old".utf8), new: data))
    }

    func testLiveActivityPolicyStartsNearEventAndContinuesCurrentEvent() {
        let rule = Rule(type: .regn)
        let near = WeatherStatus(
            ruleID: rule.id,
            type: .regn,
            text: "Regn om en halvtime.",
            eventAt: base.addingTimeInterval(30 * 60),
            isNow: false
        )
        let tooSoon = WeatherStatus(
            ruleID: rule.id,
            type: .regn,
            text: "Regn straks.",
            eventAt: base.addingTimeInterval(5 * 60),
            isNow: false
        )
        let movedAway = WeatherStatus(
            ruleID: rule.id,
            type: .regn,
            text: "Regn senere.",
            eventAt: base.addingTimeInterval(90 * 60),
            isNow: false
        )
        let current = WeatherStatus(
            ruleID: rule.id,
            type: .regn,
            text: "Regn nå.",
            eventAt: base,
            isNow: true
        )

        XCTAssertTrue(LiveWeatherActivityPolicy.canStart(near, now: base))
        XCTAssertFalse(LiveWeatherActivityPolicy.canStart(tooSoon, now: base))
        XCTAssertFalse(LiveWeatherActivityPolicy.canStart(current, now: base))
        XCTAssertTrue(LiveWeatherActivityPolicy.canContinue(tooSoon, now: base))
        XCTAssertTrue(LiveWeatherActivityPolicy.canContinue(current, now: base))
        let atLatestStart = WeatherStatus(ruleID: rule.id, type: .regn, text: "", eventAt: base.addingTimeInterval(60 * 60), isNow: false)
        XCTAssertTrue(LiveWeatherActivityPolicy.canContinue(atLatestStart, now: base))
        XCTAssertFalse(LiveWeatherActivityPolicy.canContinue(movedAway, now: base))
        let pastLatestStart = WeatherStatus(ruleID: rule.id, type: .regn, text: "", eventAt: base.addingTimeInterval(60 * 60 + 1), isNow: false)
        XCTAssertFalse(LiveWeatherActivityPolicy.canContinue(pastLatestStart, now: base))
    }

    func testClearSkyRequiresConfiguredDuration() {
        var rule = Rule(type: .sol)
        rule.threshold = 20
        rule.durationHours = 3
        rule.activeFromHour = 0
        rule.activeToHour = 0
        let hours = forecast(values: [
            (5, 0, 2, 10, 2),
            (5, 0, 2, 10, 2),
            (5, 0, 2, 30, 2),
            (5, 0, 2, 10, 2),
            (5, 0, 2, 10, 2),
            (5, 0, 2, 10, 2),
        ])

        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: base.addingTimeInterval(-10_000))

        XCTAssertEqual(result.eventAt, hours[3].time)
    }

    func testSnowDoesNotAlsoMatchRain() {
        let hour = ForecastHour(time: base, temp: 0, precip: 1, wind: 2, cloud: 100, dew: -1)
        XCTAssertTrue(AlertType.sno.matches(hour, threshold: 0.3))
        XCTAssertFalse(AlertType.regn.matches(hour, threshold: 0.5))
    }

    func testRadarRainAndSnowAlertsSwitchExactlyAtOneDegree() {
        let sampleTime = base.addingTimeInterval(15 * 60)
        let temperatures = [Double(1).nextDown, 1.0, Double(1).nextUp]

        func plannedEvent(type: AlertType, temperature: Double) -> Date? {
            var rule = Rule(type: type)
            rule.threshold = 0.5
            let hour = ForecastHour(
                time: base,
                temp: temperature,
                precip: 0,
                wind: 1,
                cloud: 100,
                dew: 0,
                radarSamples: [PrecipitationSample(time: sampleTime, rate: 0.8)]
            )
            return Planner.plan(
                rule: rule,
                forecast: [hour],
                placeName: "Klinga",
                now: base.addingTimeInterval(-60)
            ).eventAt
        }

        for temperature in temperatures {
            let isSnow = temperature <= 1
            XCTAssertEqual(
                plannedEvent(type: .sno, temperature: temperature),
                isSnow ? sampleTime : nil,
                "Snow radar event classification at \(temperature)°C"
            )
            XCTAssertEqual(
                plannedEvent(type: .regn, temperature: temperature),
                isSnow ? nil : sampleTime,
                "Rain radar event classification at \(temperature)°C"
            )
        }
    }

    func testSnowAmountConvertsWaterEquivalentUsingTemperature() {
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: 0), 4.179, accuracy: 0.01)
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: -2), 9.9, accuracy: 0.1)
        XCTAssertGreaterThan(estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: -5), 12)
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: -100), 13, accuracy: 0.001)
        let warmSingle = estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: 5)
        XCTAssertEqual(warmSingle, 4.179, accuracy: 0.001)
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: 2, temperature: 5), warmSingle * 2, accuracy: 0.001)
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: -1, temperature: 0), 0)
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: .nan, temperature: 0), 0)
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: .infinity), 0)
    }

    func testRadarRateSetsExactRainOnset() {
        let onset = base.addingTimeInterval(15 * 60)
        let hour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            radarSamples: [
                PrecipitationSample(time: base.addingTimeInterval(10 * 60), rate: 0.1),
                PrecipitationSample(time: onset, rate: 0.8),
            ]
        )
        var rule = Rule(type: .regn)
        rule.threshold = 0.5

        XCTAssertTrue(AlertType.regn.matches(hour, threshold: rule.threshold))
        XCTAssertEqual(
            Planner.plan(rule: rule, forecast: [hour], placeName: "Oslo", now: base.addingTimeInterval(-60)).eventAt,
            onset
        )
    }

    func testPrecipitationOnsetChoosesEarliestQualifyingSampleRegardlessOfOrder() {
        let cutoff = base.addingTimeInterval(10 * 60)
        let earliest = base.addingTimeInterval(15 * 60)
        let later = base.addingTimeInterval(25 * 60)
        let hour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            radarSamples: [
                PrecipitationSample(time: later, rate: 0.8),
                PrecipitationSample(time: base, rate: 1.0),
                PrecipitationSample(time: earliest, rate: 0.7),
                PrecipitationSample(time: cutoff, rate: 0.2),
            ]
        )

        XCTAssertEqual(hour.precipitationOnset(atOrAbove: 0.5, after: cutoff), earliest)
        XCTAssertNil(hour.precipitationOnset(atOrAbove: 1.1, after: cutoff))
    }

    func testPrecipitationOnsetChoosesEarliestQualifyingSampleWithoutCutoff() {
        let earliest = base.addingTimeInterval(5 * 60)
        let hour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            radarSamples: [
                PrecipitationSample(time: base.addingTimeInterval(20 * 60), rate: 0.8),
                PrecipitationSample(time: base, rate: 0.3),
                PrecipitationSample(time: earliest, rate: 0.6),
            ]
        )

        XCTAssertEqual(hour.precipitationOnset(atOrAbove: 0.5), earliest)
    }

    func testPrecipitationOnsetReturnsNilWhenRadarSamplesAreMissingOrEmpty() {
        let missingSamples = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6
        )
        let emptySamples = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            radarSamples: []
        )

        XCTAssertNil(missingSamples.precipitationOnset(atOrAbove: 0.5))
        XCTAssertNil(emptySamples.precipitationOnset(atOrAbove: 0.5))
    }

    func testPrecipitationOnsetDoesNotInferRadarTimingFromYrHourlyPrecipitation() {
        let hour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0.8,
            wind: 2,
            cloud: 90,
            dew: 6,
            precipMax: 1.2,
            precipProbability: 60
        )

        XCTAssertEqual(hour.precipitationRate, 0.8)
        XCTAssertNil(hour.precipitationOnset(atOrAbove: 0.5))
    }

    func testPrecipitationOnsetIgnoresNonFiniteRadarRatesAndThresholds() {
        let invalidRates = [Double.nan, .infinity, -.infinity]
        let invalidRateHour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            radarSamples: invalidRates.enumerated().map { index, rate in
                PrecipitationSample(time: base.addingTimeInterval(Double(index)), rate: rate)
            }
        )
        let validTime = base.addingTimeInterval(60)
        let validHour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            radarSamples: [PrecipitationSample(time: validTime, rate: 0.8)]
        )

        XCTAssertNil(invalidRateHour.precipitationOnset(atOrAbove: 0.1))
        for threshold in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(validHour.precipitationOnset(atOrAbove: threshold))
        }
        XCTAssertEqual(validHour.precipitationOnset(atOrAbove: 0.5), validTime)
    }

    func testPrecipitationOnsetIncludesExactCutoffAndThreshold() {
        let cutoff = base.addingTimeInterval(10 * 60)
        let hour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            radarSamples: [
                PrecipitationSample(time: cutoff.addingTimeInterval(60), rate: 0.4),
                PrecipitationSample(time: cutoff.addingTimeInterval(-1), rate: 1.0),
                PrecipitationSample(time: cutoff, rate: 0.5),
            ]
        )

        XCTAssertEqual(hour.precipitationOnset(atOrAbove: 0.5, after: cutoff), cutoff)
    }

    func testMalformedPrecipitationValuesDoNotCreateRainRisk() {
        let time = Date(timeIntervalSince1970: 1_900_000_000)
        let invalidAmounts = [Double.nan, Double.infinity, -.infinity, -0.1]
        for amount in invalidAmounts {
            let hour = ForecastHour(
                time: time, temp: 8, precip: amount, wind: 1, cloud: 60, dew: 7,
                radarSamples: invalidAmounts.enumerated().map { index, rate in
                    PrecipitationSample(time: time.addingTimeInterval(Double(index)), rate: rate)
                }
            )
            XCTAssertEqual(hour.precipitationRate, 0)
            XCTAssertEqual(hour.precipitationRiskRate, 0)
            XCTAssertFalse(hour.isPossiblePrecipitation(atOrAbove: 0.1))
        }

        let invalidRiskInputs = [Double.nan, Double.infinity, -1, 101]
        for probability in invalidRiskInputs {
            let hour = ForecastHour(
                time: time, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7,
                precipMax: 2, precipProbability: probability
            )
            XCTAssertEqual(hour.precipitationRiskRate, 0.2)
            XCTAssertFalse(hour.isPossiblePrecipitation(atOrAbove: 1))
        }

        let invalidMaximum = ForecastHour(
            time: time, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7,
            precipMax: .infinity, precipProbability: 80
        )
        XCTAssertEqual(invalidMaximum.precipitationRiskRate, 0.2)

        let validEstimate = ForecastHour(
            time: time, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7,
            precipMax: 2, precipProbability: 80,
            radarSamples: [PrecipitationSample(time: time, rate: 0.6)]
        )
        XCTAssertEqual(validEstimate.precipitationRate, 0.6)
        XCTAssertEqual(validEstimate.precipitationRiskRate, 2)
        XCTAssertTrue(validEstimate.isPossiblePrecipitation(atOrAbove: 1))
    }

    func testMissingPrecipitationProbabilityFallsBackToObservedAndRadarRates() {
        let observedFallback = ForecastHour(
            time: base, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7,
            precipMax: 2
        )
        let radarFallback = ForecastHour(
            time: base, temp: 8, precip: 0.1, wind: 1, cloud: 60, dew: 7,
            precipMax: 2,
            radarSamples: [PrecipitationSample(time: base, rate: 0.6)]
        )

        XCTAssertEqual(observedFallback.precipitationRiskRate, 0.2)
        XCTAssertEqual(radarFallback.precipitationRate, 0.6)
        XCTAssertEqual(radarFallback.precipitationRiskRate, 0.6)
    }

    func testTwentyPercentPrecipitationProbabilityActivatesPrecipMaxInclusively() {
        let atBoundary = ForecastHour(
            time: base, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7,
            precipMax: 2, precipProbability: 20
        )
        let belowBoundary = ForecastHour(
            time: base, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7,
            precipMax: 2, precipProbability: 19
        )

        XCTAssertEqual(atBoundary.precipitationRiskRate, 2)
        XCTAssertEqual(belowBoundary.precipitationRiskRate, 0.2)
    }

    func testOneHundredPercentPrecipitationProbabilityUsesPrecipMaxButOverOneHundredDoesNot() {
        let atMaximum = ForecastHour(
            time: base, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7,
            precipMax: 2, precipProbability: 100
        )
        let overMaximum = ForecastHour(
            time: base, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7,
            precipMax: 2, precipProbability: 101
        )

        XCTAssertEqual(atMaximum.precipitationRiskRate, 2)
        XCTAssertEqual(overMaximum.precipitationRiskRate, 0.2)
    }

    func testNominalPrecipitationIntervalUsesSmallestPositiveGapForUnsortedSamples() {
        let times = [20, 0, 10, 10, 5].map { base.addingTimeInterval(Double($0 * 60)) }
        let samples = times.map { PrecipitationSample(time: $0, rate: 0.4) }

        XCTAssertEqual(PrecipitationSample.nominalInterval(in: samples), 5 * 60)
    }

    func testNominalPrecipitationIntervalIsIndependentOfSampleOrderWithDuplicateTimes() {
        let samples = [
            PrecipitationSample(time: base.addingTimeInterval(20 * 60), rate: 0.4),
            PrecipitationSample(time: base, rate: 0.2),
            PrecipitationSample(time: base.addingTimeInterval(10 * 60), rate: 0.6),
            PrecipitationSample(time: base.addingTimeInterval(10 * 60), rate: 0.8),
            PrecipitationSample(time: base.addingTimeInterval(5 * 60), rate: 0.3)
        ]
        let permutations = [
            samples,
            Array(samples.reversed()),
            [samples[2], samples[4], samples[0], samples[3], samples[1]],
            [samples[3], samples[1], samples[4], samples[2], samples[0]]
        ]

        for permutation in permutations {
            XCTAssertEqual(PrecipitationSample.nominalInterval(in: permutation), 5 * 60)
        }
    }

    func testNominalPrecipitationIntervalUsesElapsedTimeAcrossSpringDSTChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let beforeJump = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024, month: 3, day: 31, hour: 1, minute: 55
        )))
        let afterJump = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024, month: 3, day: 31, hour: 3, minute: 5
        )))
        let samples = [
            PrecipitationSample(time: afterJump, rate: 0.4),
            PrecipitationSample(time: beforeJump, rate: 0.4)
        ]

        XCTAssertEqual(afterJump.timeIntervalSince(beforeJump), 10 * 60)
        XCTAssertEqual(PrecipitationSample.nominalInterval(in: samples), 10 * 60)
    }

    func testNominalPrecipitationIntervalClampsShortAndLongGaps() {
        let shortGap = [0.0, 30.0].map {
            PrecipitationSample(time: base.addingTimeInterval($0), rate: 0.4)
        }
        let oneMinuteGap = [0.0, 60.0].map {
            PrecipitationSample(time: base.addingTimeInterval($0), rate: 0.4)
        }
        let fifteenMinuteGap = [0.0, 15 * 60.0].map {
            PrecipitationSample(time: base.addingTimeInterval($0), rate: 0.4)
        }
        let longGap = [0.0, 20 * 60.0].map {
            PrecipitationSample(time: base.addingTimeInterval($0), rate: 0.4)
        }

        XCTAssertEqual(PrecipitationSample.nominalInterval(in: shortGap), 60)
        XCTAssertEqual(PrecipitationSample.nominalInterval(in: oneMinuteGap), 60)
        XCTAssertEqual(PrecipitationSample.nominalInterval(in: fifteenMinuteGap), 15 * 60)
        XCTAssertEqual(PrecipitationSample.nominalInterval(in: longGap), 15 * 60)
    }

    func testNominalPrecipitationIntervalDefaultsToFiveMinutesWithoutPositiveGaps() {
        let duplicateTime = PrecipitationSample(time: base, rate: 0.4)

        XCTAssertEqual(PrecipitationSample.nominalInterval(in: []), 5 * 60)
        XCTAssertEqual(PrecipitationSample.nominalInterval(in: [duplicateTime]), 5 * 60)
        XCTAssertEqual(
            PrecipitationSample.nominalInterval(in: [duplicateTime, duplicateTime]),
            5 * 60
        )
    }

    func testNowcastIsLimitedToYrsNinetyMinuteWindow() {
        let samples = stride(from: 0, through: 110, by: 5).map { minute in
            PrecipitationSample(time: base.addingTimeInterval(TimeInterval(minute * 60)), rate: 1)
        }

        let limited = YrService.ninetyMinuteNowcast(from: samples)

        XCTAssertEqual(limited.count, 19)
        XCTAssertEqual(limited.last?.time, base.addingTimeInterval(90 * 60))
    }

    func testLikelyMaximumCreatesPossibleRainInsteadOfCertainRain() {
        let hour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            precipMax: 0.8,
            precipProbability: 31
        )
        var rule = Rule(type: .regn)
        rule.threshold = 0.5

        let result = Planner.plan(rule: rule, forecast: [hour], placeName: "Namsos", now: base.addingTimeInterval(-3_600))

        XCTAssertTrue(AlertType.regn.matches(hour, threshold: rule.threshold))
        XCTAssertTrue(hour.isPossiblePrecipitation(atOrAbove: rule.threshold))
        XCTAssertTrue(result.possible)
        XCTAssertEqual(
            weatherAlertText(for: rule, eventAt: base, referenceAt: base.addingTimeInterval(-30 * 60), possible: true),
            "Mulig regn om en halvtime."
        )
    }

    func testVeryLowProbabilityMaximumDoesNotCreateRainBand() {
        let hour = ForecastHour(
            time: base,
            temp: 8,
            precip: 0,
            wind: 2,
            cloud: 90,
            dew: 6,
            precipMax: 1.0,
            precipProbability: 10
        )

        XCTAssertFalse(AlertType.regn.matches(hour, threshold: 0.5))
    }

    func testRotatingPossibleRainAddsNewInformationWithoutRepeatingUncertaintyOrClock() {
        let now = base.addingTimeInterval(5 * 60)
        let dry = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        let event = base.addingTimeInterval(5 * 3_600)
        let possible = ForecastHour(
            time: event, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5,
            precipMax: 0.2, precipProbability: 40
        )
        let second = ForecastHour(
            time: event.addingTimeInterval(3_600), temp: 8, precip: 0,
            wind: 1, cloud: 90, dew: 5, precipMax: 0.2, precipProbability: 40
        )

        let summary = CurrentPrecipitationSummary.make(
            from: [dry, possible, second], current: dry, now: now
        )
        XCTAssertTrue(summary.title.hasPrefix("D kan bli Regn!"))
        XCTAssertEqual(summary.detail, "Opptil 2 timer litt regn.")
        XCTAssertEqual(WeatherLanguage.text(summary.detail ?? "", style: .inntrondersk), "Oppte 2 tima småregn.")
        XCTAssertEqual(summary.title.components(separatedBy: "kl.").count - 1, 1)
        XCTAssertFalse(summary.detail?.contains("Mulig") == true)

        let bokmal = CurrentPrecipitationSummary.make(
            from: [dry, possible, second], current: dry,
            languageStyle: .bokmal, now: now
        )
        XCTAssertTrue(bokmal.title.hasPrefix("Det kan bli Regn!"))
    }

    func testLongPossibleRainUsesShowerWindowTemplateInRollingCard() {
        let now = base.addingTimeInterval(5 * 60)
        let dry = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        let event = base.addingTimeInterval(5 * 3_600)
        let rainHours = (0..<4).map { offset in
            ForecastHour(
                time: event.addingTimeInterval(Double(offset) * 3_600), temp: 8,
                precip: 0, wind: 1, cloud: 90, dew: 5,
                precipMax: 0.2, precipProbability: 40
            )
        }

        let summary = CurrentPrecipitationSummary.make(
            from: [dry] + rainHours, current: dry, now: now
        )

        XCTAssertEqual(
            summary.detail,
            "Opptil 4 timer regnbyger på \(weekdayLabel(event))."
        )
        XCTAssertFalse(summary.detail?.contains("fra kl.") == true)
        XCTAssertEqual(
            WeatherLanguage.text(summary.detail ?? "", style: .inntrondersk),
            "Oppte 4 tima regnbyga på \(WeatherLanguage.text(weekdayLabel(event), style: .inntrondersk))."
        )
    }

    func testFuturePossibleRainWithBroadDayPhrasePutsClockInDetail() {
        let calendar = Calendar.current
        let now = base.addingTimeInterval(5 * 60)
        let dry = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        let event = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: base)!
        let possible = ForecastHour(
            time: event, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5,
            precipMax: 0.2, precipProbability: 40
        )
        let following = ForecastHour(
            time: event.addingTimeInterval(3_600), temp: 8, precip: 0,
            wind: 1, cloud: 90, dew: 5, precipMax: 0.2, precipProbability: 40
        )

        let summary = CurrentPrecipitationSummary.make(
            from: [dry, possible, following], current: dry, now: now
        )

        XCTAssertEqual(summary.title.components(separatedBy: "kl.").count - 1, 0)
        XCTAssertTrue(summary.detail?.contains("fra kl.") == true)
        XCTAssertFalse(summary.detail?.contains("Mulig") == true)
    }

    func testFuturePossibleRainUsesShortTomorrowPhraseInRotatingHeadline() {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let now = base.addingTimeInterval(5 * 60)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: base)!
        let event = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)!
        let dry = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        let possible = ForecastHour(
            time: event, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5,
            precipMax: 0.2, precipProbability: 40
        )

        let summary = CurrentPrecipitationSummary.make(
            from: [dry, possible], current: dry,
            languageStyle: .inntrondersk, now: now
        )

        XCTAssertEqual(
            WeatherLanguage.text(summary.title, style: .inntrondersk),
            "D kan bli Regn! i mårrå."
        )
        XCTAssertFalse(summary.title.contains("tirsdag"))
    }

    func testRotatingRainDurationStopsAtForecastGapOrSnowTransition() {
        let now = base.addingTimeInterval(5 * 60)
        let dry = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        let first = ForecastHour(
            time: base.addingTimeInterval(5 * 3_600), temp: 8, precip: 0.2,
            wind: 1, cloud: 90, dew: 5
        )
        let gap = ForecastHour(
            time: first.time.addingTimeInterval(2 * 3_600), temp: 8,
            precip: 0.2, wind: 1, cloud: 90, dew: 5
        )
        let snow = ForecastHour(
            time: first.time.addingTimeInterval(3_600), temp: 0,
            precip: 0.2, wind: 1, cloud: 90, dew: -1
        )

        let gapSummary = CurrentPrecipitationSummary.make(
            from: [dry, first, gap], current: dry, now: now
        )
        let snowSummary = CurrentPrecipitationSummary.make(
            from: [dry, first, snow], current: dry, now: now
        )
        XCTAssertEqual(gapSummary.detail, "1 time litt regn.")
        XCTAssertEqual(snowSummary.detail, "1 time litt regn.")
    }

    func testFutureSnowDetailUsesTheSnowTemplateWithoutRainConnector() {
        let now = base.addingTimeInterval(5 * 60)
        let dry = ForecastHour(time: base, temp: 0, precip: 0, wind: 1, cloud: 90, dew: -2)
        let first = ForecastHour(
            time: base.addingTimeInterval(3 * 3_600), temp: 0, precip: 0.2,
            wind: 1, cloud: 90, dew: -2
        )
        let second = ForecastHour(
            time: first.time.addingTimeInterval(3_600), temp: 0, precip: 0.2,
            wind: 1, cloud: 90, dew: -2
        )

        let summary = CurrentPrecipitationSummary.make(
            from: [dry, first, second], current: dry, now: now
        )

        XCTAssertTrue(summary.title.hasPrefix("D bli Snø!"))
        XCTAssertEqual(
            summary.detail,
            "2 timer lett snøfall fra kl. \(shortClockLabel(first.time))."
        )
    }

    func testFutureRadarMinuteDoesNotClaimRainIsFallingNow() {
        let now = base.addingTimeInterval(5 * 60)
        var current = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        current.radarSamples = [
            PrecipitationSample(time: now.addingTimeInterval(60), rate: 0.2)
        ]

        let summary = CurrentPrecipitationSummary.make(from: [current], current: current, now: now)
        XCTAssertFalse(summary.isFallingNow)
        XCTAssertTrue(summary.title.hasPrefix("D bli Regn!"))

        var rule = Rule(type: .regn)
        rule.threshold = 0.1
        let status = Planner.status(for: rule, forecast: [current], now: now)
        XCTAssertEqual(status?.isNow, false)
        XCTAssertEqual(status?.eventAt, now.addingTimeInterval(60))
    }

    func testExpiredRadarSampleDoesNotCreateCurrentRainStatus() {
        let now = base.addingTimeInterval(20 * 60)
        var current = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        current.radarSamples = [
            PrecipitationSample(time: now.addingTimeInterval(-14 * 60), rate: 0),
            PrecipitationSample(time: now.addingTimeInterval(-9 * 60), rate: 0.2)
        ]

        let summary = CurrentPrecipitationSummary.make(from: [current], current: current, now: now)
        XCTAssertFalse(summary.isFallingNow)
        XCTAssertTrue(summary.title.isEmpty)
        XCTAssertNil(summary.detail)
    }

    func testCurrentRadarDetailUsesRemainingTimeInsteadOfPastStartClock() {
        let now = base.addingTimeInterval(20 * 60)
        var current = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        current.radarSamples = (0..<4).map { index in
            PrecipitationSample(
                time: now.addingTimeInterval(TimeInterval(index * 5 - 1) * 60),
                rate: 0.2
            )
        }

        let summary = CurrentPrecipitationSummary.make(from: [current], current: current, now: now)
        XCTAssertTrue(summary.isFallingNow)
        XCTAssertEqual(summary.detail, "Litt regn i 15 min til.")
    }

    func testCurrentRadarRainHeadlineUsesBokmalNowForm() {
        let now = base.addingTimeInterval(20 * 60)
        var current = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        current.radarSamples = [PrecipitationSample(time: now.addingTimeInterval(-5 * 60), rate: 0.2)]
        let summary = CurrentPrecipitationSummary.make(
            from: [current], current: current, languageStyle: .bokmal, now: now
        )
        XCTAssertEqual(summary.title, "Det Regner!")
        let dialectSummary = CurrentPrecipitationSummary.make(
            from: [current], current: current, languageStyle: .inntrondersk, now: now
        )
        XCTAssertEqual(dialectSummary.title, "D e Regn!")
    }

    func testFutureRadarUsesTemperatureAtEventInsteadOfCurrentTemperature() {
        let now = base.addingTimeInterval(5 * 60)
        let current = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        var future = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: -2, precip: 0,
            wind: 1, cloud: 90, dew: -3
        )
        future.radarSamples = [
            PrecipitationSample(time: future.time.addingTimeInterval(5 * 60), rate: 0.2)
        ]

        let summary = CurrentPrecipitationSummary.make(
            from: [current, future], current: current, now: now
        )
        XCTAssertTrue(summary.title.hasPrefix("D bli Snø!"))
        XCTAssertEqual(summary.systemImage, "cloud.snow.fill")
        XCTAssertFalse(summary.detail?.contains(" med ") == true)
    }

    func testStaleForecastDoesNotClaimDryWeatherNow() {
        let old = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5)
        let summary = CurrentPrecipitationSummary.make(
            from: [old], current: old, now: base.addingTimeInterval(4 * 3_600)
        )
        XCTAssertEqual(summary.title, "Oppdaterer værdata")
        XCTAssertNil(summary.detail)
    }

    func testCurrentForecastDetailUsesTimeRemainingInTheHour() {
        let current = ForecastHour(
            time: base, temp: 8, precip: 0.2, wind: 1, cloud: 90, dew: 5
        )
        let summary = CurrentPrecipitationSummary.make(
            from: [current], current: current,
            now: base.addingTimeInterval(50 * 60)
        )
        XCTAssertEqual(summary.title, "D bli Regn! denne timen.")
        XCTAssertEqual(summary.detail, "15 min litt regn.")
    }

    func testFutureForecastHourIsNotReportedAsCurrentWeather() {
        var rule = Rule(type: .vind)
        rule.threshold = 9
        var upcoming = ForecastHour(
            time: base.addingTimeInterval(5 * 60), temp: 8, precip: 0,
            wind: 4, cloud: 80, dew: 5
        )
        upcoming.gust = 11

        let status = Planner.status(for: rule, forecast: [upcoming], now: base)
        XCTAssertEqual(status?.eventAt, upcoming.time)
        XCTAssertEqual(status?.isNow, false)
    }

    func testMissingForecastHourBreaksDurationDependentAlertRun() {
        var rule = Rule(type: .sol)
        rule.durationHours = 2
        rule.threshold = 20
        let first = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: 15, precip: 0,
            wind: 2, cloud: 5, dew: 8
        )
        let afterGap = ForecastHour(
            time: base.addingTimeInterval(3 * 3_600), temp: 15, precip: 0,
            wind: 2, cloud: 5, dew: 8
        )

        let result = Planner.plan(
            rule: rule, forecast: [first, afterGap], placeName: "Klinga", now: base
        )
        XCTAssertNil(result.eventAt)
        XCTAssertTrue(result.alerts.isEmpty)
    }

    func testWindRuleUsesDetailedGustForecast() {
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 6, cloud: 50, dew: 4, gust: 12)
        XCTAssertTrue(AlertType.vind.matches(hour, threshold: 10))
    }

    func testCurrentWeatherConditionUsesSharedSymbolsAndThresholds() {
        let rain = ForecastHour(time: base, temp: 8, precip: 0.2, wind: 3, cloud: 80, dew: 5)
        let snow = ForecastHour(time: base, temp: 1, precip: 0.2, wind: 3, cloud: 80, dew: 0)
        let fog = ForecastHour(time: base, temp: 8, precip: 0, wind: 3, cloud: 80, dew: 7, fog: 60)
        let clear = ForecastHour(time: base, temp: 8, precip: 0, wind: 3, cloud: 20, dew: 3)
        let partlyCloudy = ForecastHour(time: base, temp: 8, precip: 0, wind: 3, cloud: 65, dew: 3)

        XCTAssertEqual(CurrentWeatherCondition.resolve(rain), .rain)
        XCTAssertEqual(CurrentWeatherCondition.resolve(rain).systemImage, AlertType.regn.systemImage)
        XCTAssertEqual(CurrentWeatherCondition.resolve(snow), .snow)
        XCTAssertEqual(CurrentWeatherCondition.resolve(fog), .fog)
        XCTAssertEqual(CurrentWeatherCondition.resolve(clear), .clear)
        XCTAssertEqual(CurrentWeatherCondition.resolve(partlyCloudy), .partlyCloudy)
        XCTAssertEqual(CurrentWeatherCondition.resolve(rain, precipitationIsFalling: false), .cloudy)
        XCTAssertEqual(CurrentWeatherCondition.resolve(rain).accessibilityLabel(languageStyle: .bokmal), "Regn")
        XCTAssertEqual(CurrentWeatherCondition.resolve(snow).accessibilityLabel(languageStyle: .bokmal), "Snø")
        XCTAssertEqual(CurrentWeatherCondition.resolve(fog).accessibilityLabel(languageStyle: .bokmal), "Tåke")
        XCTAssertEqual(CurrentWeatherCondition.resolve(rain).accessibilityLabel(languageStyle: .english), "Rain")
        XCTAssertEqual(CurrentWeatherCondition.resolve(fog).accessibilityLabel(languageStyle: .english), "Fog")

        let possibleRain = ForecastHour(
            time: base, temp: 8, precip: 0, wind: 3, cloud: 80, dew: 5,
            precipMax: 2, precipProbability: 50
        )
        let displayedCondition = CurrentWeatherCondition.resolve(
            possibleRain,
            precipitationIsFalling: possibleRain.precipitationRate >= 0.1
        )
        XCTAssertEqual(displayedCondition, .cloudy)
    }

    func testCurrentWeatherMetricLabelsFollowSelectedLanguageStyle() {
        XCTAssertEqual(CurrentWeatherMetricCopy.label(for: .precipitation, languageStyle: .bokmal), "Nedbør")
        XCTAssertEqual(CurrentWeatherMetricCopy.label(for: .windGusts, languageStyle: .bokmal), "Vindkast")
        XCTAssertEqual(CurrentWeatherMetricCopy.label(for: .precipitation, languageStyle: .inntrondersk), "Nedbør")
        XCTAssertEqual(CurrentWeatherMetricCopy.label(for: .windGusts, languageStyle: .inntrondersk), "Vindkast")
        XCTAssertEqual(CurrentWeatherMetricCopy.label(for: .precipitation, languageStyle: .english), "Precipitation")
        XCTAssertEqual(CurrentWeatherMetricCopy.label(for: .windGusts, languageStyle: .english), "Wind gusts")
    }

    func testRotatingStatusDetailsDescribeWeatherWithoutRepeatingTime() {
        let hour = ForecastHour(
            time: base,
            temp: 3.3,
            precip: 0.7,
            wind: 4,
            cloud: 28,
            dew: 2.9,
            precipMax: 0.9,
            precipProbability: 41,
            gust: 12
        )
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.5, frostMargin: 2)

        for type in AlertType.allCases {
            let status = WeatherStatus(
                ruleID: UUID(),
                type: type,
                text: "\(type.label) i dag kl. 20.",
                eventAt: base,
                isNow: false,
                possible: type == .regn || type == .sno
            )
            let detail = Planner.statusDetail(for: status, place: place, forecast: [hour])
            XCTAssertNotNil(detail, "Mangler detalj for \(type)")
            if type != .dugg {
                XCTAssertFalse(detail?.contains("kl.") == true, "Gjentar klokkeslett for \(type): \(detail ?? "")")
            }
            XCTAssertFalse(detail?.contains("Neste hendelse") == true, "Gjentar hendelsen for \(type): \(detail ?? "")")
        }

        let dew = WeatherStatus(ruleID: UUID(), type: .dugg, text: "Duggfall i dag kl. 20.", eventAt: base, isNow: false)
        XCTAssertEqual(
            Planner.statusDetail(for: dew, place: place, forecast: [hour]),
            "Duggfall ved 3,3°."
        )
    }

    func testTemperatureStatusDetailSkipsNonFiniteSamplesAndOmitsAllInvalidForecasts() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let status = WeatherStatus(
            ruleID: UUID(), type: .temperatur, text: "", eventAt: base, isNow: false
        )
        let laterValid = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: 6, precip: 0, wind: 1, cloud: 0, dew: 0
        )

        for invalidTemperature in [Double.nan, .infinity, -.infinity] {
            let invalid = ForecastHour(
                time: base, temp: invalidTemperature, precip: 0, wind: 1, cloud: 0, dew: 0
            )

            XCTAssertEqual(
                Planner.statusDetail(for: status, place: place, forecast: [invalid, laterValid]),
                "Yr melder: 6°."
            )
            XCTAssertNil(Planner.statusDetail(for: status, place: place, forecast: [invalid]))
        }
    }

    func testFrostSnowAndDewStatusDetailsSkipNonFiniteTemperatures() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let valid = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: -2, precip: 0.2,
            wind: 1, cloud: 0, dew: -4
        )
        let statuses: [WeatherStatus] = [
            WeatherStatus(ruleID: UUID(), type: .frost, text: "", eventAt: base, isNow: false),
            WeatherStatus(ruleID: UUID(), type: .sno, text: "", eventAt: base, isNow: false),
            WeatherStatus(ruleID: UUID(), type: .dugg, text: "", eventAt: base, isNow: false),
        ]

        for status in statuses {
            let expected = Planner.statusDetail(for: status, place: place, forecast: [valid])
            XCTAssertNotNil(expected, "Valid detail missing for \(status.type)")

            for invalidTemperature in [Double.nan, .infinity, -.infinity] {
                let invalid = ForecastHour(
                    time: base, temp: invalidTemperature, precip: 0.2,
                    wind: 1, cloud: 0, dew: -4
                )
                XCTAssertEqual(
                    Planner.statusDetail(for: status, place: place, forecast: [invalid, valid]),
                    expected,
                    "Invalid temperature selected for \(status.type)"
                )
                XCTAssertNil(
                    Planner.statusDetail(for: status, place: place, forecast: [invalid]),
                    "A detail must be omitted when \(status.type) has no finite temperature"
                )
            }
        }
    }

    func testCurrentRotatingDewDetailSkipsNonFiniteDewPoints() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let status = WeatherStatus(
            ruleID: UUID(), type: .dugg, text: "", eventAt: base, isNow: true
        )
        let valid = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: 8, precip: 0,
            wind: 1, cloud: 0, dew: 4.3
        )

        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: status, place: place, forecast: [
                ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 0, dew: .nan),
                valid,
            ]),
            "Duggpunkt ved 4,3°C."
        )
        for invalidDewPoint in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(Planner.rotatingStatusDetail(
                for: status,
                place: place,
                forecast: [ForecastHour(
                    time: base, temp: 8, precip: 0, wind: 1, cloud: 0, dew: invalidDewPoint
                )]
            ))
        }
    }

    func testWindGustLevelsProduceDifferentNotificationTitles() {
        var standard = Rule(type: .vind)
        standard.threshold = 12
        var powerful = standard
        powerful.threshold = 20
        var extreme = standard
        extreme.threshold = 40

        XCTAssertEqual(NotificationCopy.title(for: standard), "D bli Vindkast!")
        XCTAssertEqual(NotificationCopy.title(for: powerful), "D bli Vindkast!")
        XCTAssertEqual(NotificationCopy.title(for: extreme), "D bli Vindkast!")
        XCTAssertEqual(WindGustLevel.forSpeed(31), .veryPowerful)
    }

    func testRotatingStatusUsesDirectHeadlineAndDictionaryDetail() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 9, precip: 0.2, wind: 2, cloud: 70, dew: 4)
        let status = WeatherStatus(ruleID: UUID(), type: .regn, text: "D bli Regn! denne timen.", eventAt: base, isNow: false)

        XCTAssertEqual(WeatherLanguage.text(status.text, style: .inntrondersk), "D bli Regn! herre tima.")
        XCTAssertEqual(WeatherLanguage.text("Det blåser!", style: .inntrondersk), "D Blæs!")
        XCTAssertEqual(Planner.statusDetail(for: status, place: place, forecast: [hour]), "Litt regn.")
        XCTAssertEqual(
            WeatherLanguage.text(
                Planner.statusDetail(for: status, place: place, forecast: [hour]) ?? "",
                style: .inntrondersk
            ),
            "Småregn."
        )
    }

    func testRotatingFutureDetailUsesSharedDurationAndStartFormat() {
        var rule = Rule(type: .vind)
        rule.threshold = 9
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.rules = [rule]
        var first = ForecastHour(time: base, temp: 9, precip: 0, wind: 3, cloud: 50, dew: 4)
        first.gust = 9
        var second = ForecastHour(time: base.addingTimeInterval(3_600), temp: 9, precip: 0, wind: 3, cloud: 50, dew: 4)
        second.gust = 10
        let future = WeatherStatus(ruleID: rule.id, type: .vind, text: "", eventAt: base, isNow: false)
        let current = WeatherStatus(ruleID: rule.id, type: .vind, text: "", eventAt: base, isNow: true)

        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: future, place: place, forecast: [first, second]),
            "Frisk bris i 2 timer."
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: current, place: place, forecast: [first, second]),
            "Frisk bris i 2 timer til."
        )
    }

    func testRotatingRuleDetailDoesNotRepeatClockOrUncertainty() {
        var rule = Rule(type: .regn)
        rule.threshold = 0.1
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.rules = [rule]
        let hours = (0..<2).map { index in
            ForecastHour(
                time: base.addingTimeInterval(Double(index) * 3_600),
                temp: 8, precip: 0, wind: 1, cloud: 90, dew: 5,
                precipMax: 0.2, precipProbability: 40
            )
        }
        let future = WeatherStatus(
            ruleID: rule.id, type: .regn, text: "", eventAt: base,
            isNow: false, possible: true
        )
        let possibleNow = WeatherStatus(
            ruleID: rule.id, type: .regn, text: "", eventAt: base,
            isNow: true, possible: true
        )

        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: future, place: place, forecast: hours,
                headlineDescribesTime: true
            ),
            "2 timer litt regn."
        )
        XCTAssertEqual(
            WeatherLanguage.text("2 timer litt regn fra kl. 14.", style: .inntrondersk),
            "2 tima småregn fra kl. 14."
        )
        XCTAssertEqual(
            WeatherLanguage.text("2 timer regn fra kl. 14.", style: .inntrondersk),
            "2 tima regnbyge fra kl. 14."
        )
        XCTAssertEqual(
            WeatherLanguage.text("2 timer kraftig regn fra kl. 14.", style: .inntrondersk),
            "2 tima striskur fra kl. 14."
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: possibleNow, place: place, forecast: hours),
            "Litt regn i opptil 2 timer."
        )
    }

    func testRotatingDewNowUsesTemperatureAndSingularDurationsAreGrammatical() {
        let dewRule = Rule(type: .dugg)
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.rules = [dewRule]
        let dewHour = ForecastHour(time: base, temp: 7, precip: 0, wind: 1, cloud: 70, dew: 6.8)
        let currentDew = WeatherStatus(
            ruleID: dewRule.id, type: .dugg, text: "", eventAt: base, isNow: true
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: currentDew, place: place, forecast: [dewHour]),
            "Duggpunkt ved 6,8°C."
        )
        XCTAssertEqual(
            WeatherLanguage.text("Duggpunkt ved 6,8°C.", style: .inntrondersk),
            "Doggpunkt ved 6,8°C."
        )
        let futureDew = WeatherStatus(
            ruleID: dewRule.id, type: .dugg, text: "", eventAt: base.addingTimeInterval(3_600), isNow: false
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: futureDew, place: place, forecast: [dewHour],
                headlineDescribesTime: true
            ),
            "Duggpunkt ved 6,8°C."
        )

        var windRule = Rule(type: .vind)
        windRule.threshold = 8
        place.rules = [windRule]
        var windyHour = dewHour
        windyHour.gust = 9
        let currentWind = WeatherStatus(
            ruleID: windRule.id, type: .vind, text: "", eventAt: base, isNow: true
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: currentWind, place: place, forecast: [windyHour]),
            "Frisk bris i en time til."
        )
    }

    func testRotatingTomorrowHeadlineAndLongPossibleRainAvoidDuplication() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 16, hour: 20)))
        let tomorrowAtNine = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: reference))
        let event = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrowAtNine))
        let rule = Rule(type: .regn)
        let status = WeatherStatus(ruleID: rule.id, type: .regn, text: "", eventAt: event, isNow: false, possible: true)

        XCTAssertEqual(
            RotatingAlertCopy.headline(for: status, rule: rule, languageStyle: .bokmal, now: reference),
            "Det kan bli Regn! i morgen."
        )
        XCTAssertEqual(
            WeatherLanguage.text(
                RotatingAlertCopy.headline(for: status, rule: rule, languageStyle: .inntrondersk, now: reference),
                style: .inntrondersk
            ),
            "D kan bli Regn! i mårrå."
        )

        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.rules = [rule]
        let rainHours = (0..<10).map { offset in
            ForecastHour(time: event.addingTimeInterval(Double(offset) * 3_600), temp: 8, precip: 0.6, wind: 1, cloud: 90, dew: 5)
        }
        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: status, place: place, forecast: rainHours),
            "Opptil 10 timer regnbyger på tirsdag."
        )
        XCTAssertEqual(
            WeatherLanguage.text("Opptil 10 timer regnbyger på tirsdag.", style: .inntrondersk),
            "Oppte 10 tima regnbyga på tirsda'n."
        )
    }

    func testRotatingBroadDayHeadlineKeepsClockInDetailLine() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 16, hour: 7)))
        let eventAt = try XCTUnwrap(calendar.date(bySettingHour: 11, minute: 0, second: 0, of: reference))
        var rule = Rule(type: .vind)
        rule.threshold = 9
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.rules = [rule]
        let forecast = (0..<4).map { offset in
            var hour = ForecastHour(
                time: eventAt.addingTimeInterval(Double(offset) * 3_600),
                temp: 10, precip: 0, wind: 4, cloud: 50, dew: 5
            )
            hour.gust = 10
            return hour
        }
        let status = WeatherStatus(
            ruleID: rule.id, type: .vind, text: "", eventAt: eventAt, isNow: false
        )
        let headline = RotatingAlertCopy.headline(
            for: status, rule: rule, languageStyle: .bokmal, now: reference
        )

        XCTAssertEqual(headline, "D bli Vindkast! i dag.")
        XCTAssertFalse(Planner.headlineDescribesTime(headline))
        XCTAssertTrue(Planner.headlineDescribesTime("D bli Vindkast! om tre kvarter."))
        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: status, place: place, forecast: forecast,
                headlineDescribesTime: Planner.headlineDescribesTime(headline)
            ),
            "Frisk bris i 4 timer fra kl. 11."
        )
    }

    func testRotatingCurrentTemperatureUsesTodaysRelevantExtreme() throws {
        var below = Rule(type: .temperatur)
        below.threshold = 10
        var above = Rule(type: .temperatur)
        above.threshold = 20
        above.temperatureDirection = .above
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.rules = [below, above]
        let hours = [
            ForecastHour(time: base, temp: 7.6, precip: 0, wind: 1, cloud: 40, dew: 3),
            ForecastHour(time: base.addingTimeInterval(3_600), temp: 5, precip: 0, wind: 1, cloud: 40, dew: 2),
            ForecastHour(time: base.addingTimeInterval(6 * 3_600), temp: 22, precip: 0, wind: 1, cloud: 40, dew: 6),
        ]

        let currentBelow = WeatherStatus(ruleID: below.id, type: .temperatur, text: "", eventAt: base, isNow: true)
        let currentAbove = WeatherStatus(ruleID: above.id, type: .temperatur, text: "", eventAt: base, isNow: true)
        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: currentBelow, place: place, forecast: hours),
            "Laveste temperatur i dag blir 5°C."
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(for: currentAbove, place: place, forecast: hours),
            "Høyeste temperatur i dag blir 22°C."
        )

        // Display-only temperature rules are recreated with a new UUID for
        // each view pass. The type fallback must still retain the default 10°
        // threshold instead of rendering the 0° fallback.
        var displayOnlyPlace = Place(name: "Hornburu", lat: 64, lon: 11)
        displayOnlyPlace.rules = []
        let regenerated = WeatherStatus(
            ruleID: UUID(), type: .temperatur, text: "", eventAt: base, isNow: true
        )
        let regeneratedRule = try XCTUnwrap(Planner.displayRule(for: regenerated, place: displayOnlyPlace))
        XCTAssertEqual(regeneratedRule.threshold, 10)
        XCTAssertEqual(
            RotatingAlertCopy.headline(
                for: regenerated, rule: regeneratedRule, languageStyle: .inntrondersk, now: base
            ),
            "D e under 10°!"
        )
        let futureRegenerated = WeatherStatus(
            ruleID: UUID(), type: .temperatur, text: "", eventAt: base.addingTimeInterval(3_600), isNow: false
        )
        let futureDetail = Planner.rotatingStatusDetail(
            for: futureRegenerated, place: displayOnlyPlace, forecast: hours
        )
        XCTAssertEqual(futureDetail, "Laveste temperatur blir 8°C.")
    }

    func testRotatingTemperatureExtremesStayWithinLocalDayAcrossMidnight() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: base)
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .second, value: -1, to: dayStart))
        let eventAt = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 0, second: 0, of: dayStart))
        let laterToday = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: dayStart))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        var below = Rule(type: .temperatur)
        below.threshold = 10
        var above = Rule(type: .temperatur)
        above.threshold = 20
        above.temperatureDirection = .above
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [below, above])
        let forecast = [
            ForecastHour(time: previousDay, temp: -20, precip: 0, wind: 1, cloud: 0, dew: 0),
            ForecastHour(time: eventAt, temp: 6, precip: 0, wind: 1, cloud: 0, dew: 0),
            ForecastHour(time: laterToday, temp: 4, precip: 0, wind: 1, cloud: 0, dew: 0),
            ForecastHour(time: nextDay, temp: 100, precip: 0, wind: 1, cloud: 0, dew: 0),
        ]

        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: WeatherStatus(ruleID: below.id, type: .temperatur, text: "", eventAt: eventAt, isNow: true),
                place: place, forecast: forecast
            ),
            "Laveste temperatur i dag blir 4°C."
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: WeatherStatus(ruleID: above.id, type: .temperatur, text: "", eventAt: eventAt, isNow: true),
                place: place, forecast: forecast
            ),
            "Høyeste temperatur i dag blir 6°C."
        )
    }

    func testRotatingTemperatureExtremeUsesSingleRemainingSampleInLocalDay() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: base)
        let earlierToday = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart))
        let eventAt = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 0, second: 0, of: dayStart))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        var below = Rule(type: .temperatur)
        below.threshold = 10
        var above = Rule(type: .temperatur)
        above.threshold = 20
        above.temperatureDirection = .above
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [below, above])
        let onlyRemainingSample = ForecastHour(
            time: eventAt, temp: 6, precip: 0, wind: 1, cloud: 0, dew: 0
        )
        let forecast = [
            ForecastHour(time: earlierToday, temp: -15, precip: 0, wind: 1, cloud: 0, dew: 0),
            onlyRemainingSample,
            ForecastHour(time: nextDay, temp: 100, precip: 0, wind: 1, cloud: 0, dew: 0),
        ]

        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: WeatherStatus(ruleID: below.id, type: .temperatur, text: "", eventAt: eventAt, isNow: true),
                place: place, forecast: forecast
            ),
            "Laveste temperatur i dag blir 6°C."
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: WeatherStatus(ruleID: above.id, type: .temperatur, text: "", eventAt: eventAt, isNow: true),
                place: place, forecast: forecast
            ),
            "Høyeste temperatur i dag blir 6°C."
        )
    }

    func testRotatingTemperatureExtremesIgnoreNonFiniteRemainingSamples() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: base)
        let eventAt = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 0, second: 0, of: dayStart))
        let at2315 = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 15, second: 0, of: dayStart))
        let at2330 = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: dayStart))
        let at2345 = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 45, second: 0, of: dayStart))
        let at2350 = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 50, second: 0, of: dayStart))
        var below = Rule(type: .temperatur)
        below.threshold = 10
        var above = Rule(type: .temperatur)
        above.threshold = 20
        above.temperatureDirection = .above
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [below, above])
        let forecast = [
            ForecastHour(time: at2315, temp: .nan, precip: 0, wind: 1, cloud: 0, dew: 0),
            ForecastHour(time: at2330, temp: -.infinity, precip: 0, wind: 1, cloud: 0, dew: 0),
            ForecastHour(time: eventAt, temp: 6, precip: 0, wind: 1, cloud: 0, dew: 0),
            ForecastHour(time: at2345, temp: .infinity, precip: 0, wind: 1, cloud: 0, dew: 0),
            ForecastHour(time: at2350, temp: 4, precip: 0, wind: 1, cloud: 0, dew: 0),
        ]

        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: WeatherStatus(ruleID: below.id, type: .temperatur, text: "", eventAt: eventAt, isNow: true),
                place: place, forecast: forecast
            ),
            "Laveste temperatur i dag blir 4°C."
        )
        XCTAssertEqual(
            Planner.rotatingStatusDetail(
                for: WeatherStatus(ruleID: above.id, type: .temperatur, text: "", eventAt: eventAt, isNow: true),
                place: place, forecast: forecast
            ),
            "Høyeste temperatur i dag blir 6°C."
        )
    }

    func testRotatingTemperatureDetailSkipsNonFiniteNearestEventSample() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: base)
        let eventAt = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart))
        let nextHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: eventAt))
        let laterHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 2, to: eventAt))
        var rule = Rule(type: .temperatur)
        rule.threshold = 10
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let validHours = [
            ForecastHour(time: nextHour, temp: 6, precip: 0, wind: 1, cloud: 0, dew: 0),
            ForecastHour(time: laterHour, temp: 3, precip: 0, wind: 1, cloud: 0, dew: 0),
        ]

        for invalidTemperature in [Double.nan, .infinity, -.infinity] {
            let forecast = [
                ForecastHour(time: eventAt, temp: invalidTemperature, precip: 0, wind: 1, cloud: 0, dew: 0)
            ] + validHours
            let future = WeatherStatus(
                ruleID: rule.id, type: .temperatur, text: "", eventAt: eventAt, isNow: false
            )
            let current = WeatherStatus(
                ruleID: rule.id, type: .temperatur, text: "", eventAt: eventAt, isNow: true
            )

            XCTAssertEqual(
                Planner.rotatingStatusDetail(for: future, place: place, forecast: forecast),
                "Laveste temperatur blir 6°C."
            )
            XCTAssertEqual(
                Planner.rotatingStatusDetail(for: current, place: place, forecast: forecast),
                "Laveste temperatur i dag blir 3°C."
            )
        }
    }

    func testRotatingTemperatureDetailIsOmittedWithoutFiniteForecastTemperature() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: base)
        let eventAt = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayStart))
        let nextHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: eventAt))
        var rule = Rule(type: .temperatur)
        rule.threshold = 10
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let forecast = [Double.nan, .infinity, -.infinity].enumerated().map { index, temperature in
            ForecastHour(
                time: eventAt.addingTimeInterval(Double(index) * 3_600),
                temp: temperature, precip: 0, wind: 1, cloud: 0, dew: 0
            )
        }
        let future = WeatherStatus(
            ruleID: rule.id, type: .temperatur, text: "", eventAt: eventAt, isNow: false
        )
        let current = WeatherStatus(
            ruleID: rule.id, type: .temperatur, text: "", eventAt: nextHour, isNow: true
        )

        XCTAssertNil(Planner.rotatingStatusDetail(for: future, place: place, forecast: forecast))
        XCTAssertNil(Planner.rotatingStatusDetail(for: current, place: place, forecast: forecast))
    }

    func testWindStrengthUsesEverydayBeaufortNames() {
        XCTAssertEqual(windStrengthLabel(for: 0), "stille")
        XCTAssertEqual(windStrengthLabel(for: 4), "lett bris")
        XCTAssertEqual(windStrengthLabel(for: 9), "frisk bris")
        XCTAssertEqual(windStrengthLabel(for: 12), "liten kuling")
        XCTAssertEqual(windStrengthLabel(for: 22), "liten storm")
        XCTAssertEqual(windStrengthLabel(for: 30), "sterk storm")
        XCTAssertEqual(windStrengthLabel(for: 33), "orkan")
    }

    func testPrecipitationHeadlineAlwaysStartsWithCapitalLetter() {
        XCTAssertEqual(precipitationHeadlineName(temperature: 8, possible: false), "Regn")
        XCTAssertEqual(precipitationHeadlineName(temperature: 0, possible: false), "Snø")
        XCTAssertEqual(precipitationHeadlineName(temperature: 8, possible: true), "Mulig regn")
        XCTAssertEqual(precipitationHeadlineName(temperature: 0, possible: true), "Mulig snø")
    }

    func testDewPointIsCalculatedFromTemperatureAndHumidity() {
        XCTAssertEqual(YrService.calculatedDewPoint(temperature: 20, relativeHumidity: 50), 9.3, accuracy: 0.2)
        XCTAssertEqual(YrService.calculatedDewPoint(temperature: 5, relativeHumidity: 100), 5, accuracy: 0.01)
    }

    func testNorwegianNotificationCopy() {
        let reference = base
        XCTAssertEqual(AppCopy.name, "D bli Vær!")
        XCTAssertEqual(AppCopy.heading(placeName: "nerri Namsos"), "D bli Vær! nerri Namsos")
        XCTAssertEqual(
            AppCopy.weatherHeadline(weatherName: "Duggfall", placeName: "på Klinga"),
            "D bli Duggfall! på Klinga"
        )
        XCTAssertEqual(
            AppCopy.weatherHeadline(weatherName: "Regn", placeName: "nerri Namsos", possibility: "kan bli"),
            "D kan bli Regn! nerri Namsos"
        )
        XCTAssertEqual(NotificationCopy.title(for: Rule(type: .regn), possible: true), "Det kan bli Regn!")
        XCTAssertEqual(NotificationCopy.title(for: Rule(type: .regn), placeName: "nerri Namsos", possible: true), "Det kan bli Regn! nerri Namsos")
        XCTAssertEqual(
            NotificationCopy.title(
                for: Rule(type: .regn),
                placeName: "nerri Namsos",
                possible: true,
                languageStyle: .inntrondersk
            ),
            "D kan bli Regn! nerri Namsos"
        )
        XCTAssertEqual(NotificationCopy.message(for: Rule(type: .regn), eventAt: reference.addingTimeInterval(30 * 60), referenceAt: reference), "Om en halvtime.")
        XCTAssertEqual(NotificationCopy.title(for: Rule(type: .sno)), "D bli Snø!")
        XCTAssertEqual(NotificationCopy.title(for: Rule(type: .dugg)), "D bli Duggfall!")
        XCTAssertEqual(NotificationCopy.message(for: Rule(type: .sno), eventAt: reference.addingTimeInterval(45 * 60), referenceAt: reference), "Om tre kvarter.")

        var sun = Rule(type: .sol)
        sun.durationHours = 4
        sun.customName = "Klipp gresset!"
        XCTAssertEqual(NotificationCopy.title(for: sun), "D bli Sol!")
        XCTAssertEqual(NotificationCopy.message(for: sun, eventAt: reference.addingTimeInterval(60 * 60), referenceAt: reference), "4 timer om en time.\nKlipp gresset!")

        XCTAssertEqual(
            NotificationCopy.title(for: Rule(type: .regn), placeName: "i Oslo"),
            "D bli Regn! i Oslo"
        )
        let tomorrow = reference.addingTimeInterval(26 * 60 * 60)
        let dialectMessage = NotificationCopy.message(
            for: Rule(type: .regn),
            eventAt: tomorrow,
            referenceAt: reference,
            languageStyle: .inntrondersk
        )
        XCTAssertTrue(dialectMessage.contains("I mårrå"), dialectMessage)
    }

    func testTemperatureAlertCopyAlwaysUsesConfiguredDirection() {
        var below = Rule(type: .temperatur)
        below.threshold = 10
        var above = below
        above.threshold = 20
        above.temperatureDirection = .above

        XCTAssertEqual(alertWeatherName(for: below), "Under 10°")
        XCTAssertEqual(alertWeatherName(for: above), "Over 20°")
        XCTAssertEqual(
            NotificationCopy.title(for: below, placeName: "på Klinga", languageStyle: .bokmal),
            "D bli Under 10°! på Klinga"
        )
        XCTAssertEqual(
            NotificationCopy.title(for: above, placeName: "på Klinga", languageStyle: .bokmal),
            "D bli Over 20°! på Klinga"
        )
        XCTAssertEqual(
            NotificationCopy.title(for: above, placeName: "på Klinga", languageStyle: .inntrondersk),
            "D bli Over 20°! på Klinga"
        )
        XCTAssertEqual(
            NotificationCopy.title(for: above, placeName: "in Oslo", languageStyle: .english),
            "It’s Above 20°! in Oslo"
        )

        let nowStatus = WeatherStatus(
            ruleID: above.id, type: .temperatur, text: "", eventAt: base, isNow: true
        )
        let futureStatus = WeatherStatus(
            ruleID: above.id, type: .temperatur, text: "", eventAt: base.addingTimeInterval(3 * 3_600), isNow: false
        )
        XCTAssertEqual(
            RotatingAlertCopy.headline(for: nowStatus, rule: above, languageStyle: .bokmal, now: base),
            "Det er over 20°!"
        )
        XCTAssertEqual(
            RotatingAlertCopy.headline(for: nowStatus, rule: above, languageStyle: .inntrondersk, now: base),
            "D e Over 20°!"
        )
        XCTAssertEqual(
            RotatingAlertCopy.headline(for: futureStatus, rule: above, languageStyle: .bokmal, now: base),
            "D bli Over 20°! om tre timer."
        )
    }

    func testRotatingAlertCopyCoversEveryWeatherTypeAndPossibleNowStatus() {
        let expectedBokmal: [AlertType: String] = [
            .regn: "Det Regner!", .sno: "Det Snør!", .vind: "Det Blåser!",
            .dugg: "Det er Duggfall!", .frost: "Det er frost!", .sol: "Det er sol!"
        ]
        let expectedInntrondersk: [AlertType: String] = [
            .regn: "D e Regn!", .sno: "Det Snør!", .vind: "D Blæs!",
            .dugg: "D Dogge!", .frost: "D Rime!", .sol: "D e Sol!"
        ]

        for type in [AlertType.regn, .sno, .vind, .dugg, .frost, .sol] {
            let rule = Rule(type: type)
            let status = WeatherStatus(ruleID: rule.id, type: type, text: "", eventAt: base, isNow: true)
            XCTAssertEqual(RotatingAlertCopy.headline(for: status, rule: rule, languageStyle: .bokmal, now: base), expectedBokmal[type])
            XCTAssertEqual(RotatingAlertCopy.headline(for: status, rule: rule, languageStyle: .inntrondersk, now: base), expectedInntrondersk[type])

            if type == .sno {
                XCTAssertEqual(
                    RotatingAlertCopy.headline(for: status, rule: rule, languageStyle: .english, now: base),
                    "It’s snowing!"
                )
            }

            let possible = WeatherStatus(ruleID: rule.id, type: type, text: "", eventAt: base, isNow: true, possible: true)
            XCTAssertTrue(
                RotatingAlertCopy.headline(for: possible, rule: rule, languageStyle: .bokmal, now: base).hasPrefix("Det kan bli "),
                "\(type)"
            )
        }
    }

    func testRotatingCurrentHourHeadlineUsesSharedLanguagePrefix() {
        XCTAssertEqual(
            RotatingAlertCopy.currentHourHeadline(
                for: .regn, possible: false, languageStyle: .bokmal
            ),
            "D bli Regn! denne timen."
        )
        XCTAssertEqual(
            WeatherLanguage.text(
                RotatingAlertCopy.currentHourHeadline(
                    for: .sno, possible: true, languageStyle: .inntrondersk
                ),
                style: .inntrondersk
            ),
            "D kan bli Snø! herre tima."
        )
    }

    func testDewUsesCompactDialectHeadlineButFullPossiblePushWording() {
        let rule = Rule(type: .dugg)
        let future = WeatherStatus(
            ruleID: rule.id, type: .dugg, text: "", eventAt: base.addingTimeInterval(3 * 3_600), isNow: false
        )
        let headline = RotatingAlertCopy.headline(
            for: future, rule: rule, languageStyle: .inntrondersk, now: base
        )
        XCTAssertEqual(WeatherLanguage.text(headline, style: .inntrondersk), "D bli Dogg! om tre tima.")
        XCTAssertEqual(
            NotificationCopy.title(for: rule, placeName: "på Klinga", languageStyle: .inntrondersk),
            "D bli Dogg! på Klinga"
        )
        XCTAssertEqual(
            NotificationCopy.title(for: rule, placeName: "på Klinga", possible: true, languageStyle: .inntrondersk),
            "D kan bli Doggfall! på Klinga"
        )
    }

    func testPushDetailAlwaysIncludesSingleHourDuration() {
        let rule = Rule(type: .regn)
        let hour = ForecastHour(time: base, temp: 8, precip: 0.2, wind: 1, cloud: 80, dew: 5)
        XCTAssertEqual(
            Planner.notificationEventDetail(rule: rule, hours: [hour], possible: false),
            "Litt regn {tid} — i en time."
        )
    }

    func testEveryWeatherTypeKeepsTheRequiredDurationInPushDetail() {
        var hour = ForecastHour(time: base, temp: 8, precip: 0.2, wind: 1, cloud: 20, dew: 7.8)
        hour.gust = 9

        for type in AlertType.allCases {
            var rule = Rule(type: type)
            if type == .temperatur { rule.temperatureDirection = .above }
            let detail = Planner.notificationEventDetail(
                rule: rule, hours: [hour], possible: false
            )
            XCTAssertTrue(
                detail?.hasSuffix("— i en time.") == true,
                "Mangler varighet i pushdetalj for \(type): \(detail ?? "nil")"
            )
        }
    }

    func testFrostAndSnowPushDetailsSkipNonFiniteTemperatures() {
        let valid = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: -1, precip: 0.6,
            wind: 1, cloud: 80, dew: -2
        )
        var frost = Rule(type: .frost)
        frost.threshold = 0
        var snow = Rule(type: .sno)
        snow.threshold = 0.5

        for invalidTemperature in [Double.nan, .infinity, -.infinity] {
            let invalid = ForecastHour(
                time: base, temp: invalidTemperature, precip: 0.6,
                wind: 1, cloud: 80, dew: -2
            )
            for rule in [frost, snow] {
                let reference = Planner.notificationEventDetail(
                    rule: rule, hours: [valid], possible: false
                )?.components(separatedBy: " {tid}").first
                let mixed = Planner.notificationEventDetail(
                    rule: rule, hours: [invalid, valid], possible: false
                )
                XCTAssertEqual(mixed?.components(separatedBy: " {tid}").first, reference)
                XCTAssertNil(Planner.notificationEventDetail(
                    rule: rule, hours: [invalid], possible: false
                ))
            }
        }
    }

    func testDewPushDetailsSkipNonFiniteTemperatureAndDewPoint() {
        let valid = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: 8, precip: 0,
            wind: 1, cloud: 60, dew: 7
        )
        let rule = Rule(type: .dugg)

        for invalidValue in [Double.nan, .infinity, -.infinity] {
            let invalidTemperature = ForecastHour(
                time: base, temp: invalidValue, precip: 0,
                wind: 1, cloud: 60, dew: 7
            )
            let invalidDewPoint = ForecastHour(
                time: base, temp: 8, precip: 0,
                wind: 1, cloud: 60, dew: invalidValue
            )
            for invalid in [invalidTemperature, invalidDewPoint] {
                let reference = Planner.notificationEventDetail(
                    rule: rule, hours: [valid], possible: false
                )?.components(separatedBy: " {tid}").first
                let mixed = Planner.notificationEventDetail(
                    rule: rule, hours: [invalid, valid], possible: false
                )
                XCTAssertEqual(mixed?.components(separatedBy: " {tid}").first, reference)
                XCTAssertNil(Planner.notificationEventDetail(
                    rule: rule, hours: [invalid], possible: false
                ))
            }
        }
    }

    func testEveryAlertTypeHasAUsablePushTitleInBothActiveNorwegianStyles() {
        for language in [AlertLanguageStyle.bokmal, .inntrondersk] {
            for type in AlertType.allCases {
                var rule = Rule(type: type)
                for direction in type == .temperatur ? [Rule.TemperatureDirection.below, .above] : [.below] {
                    rule.temperatureDirection = direction
                    let certain = NotificationCopy.title(
                        for: rule, placeName: "på Klinga", eventAt: base.addingTimeInterval(2 * 3_600),
                        referenceAt: base, languageStyle: language
                    )
                    let possible = NotificationCopy.title(
                        for: rule, placeName: "på Klinga", eventAt: base.addingTimeInterval(2 * 3_600),
                        referenceAt: base, possible: true, languageStyle: language
                    )
                    XCTAssertFalse(certain.isEmpty, "\(language) / \(type) / \(direction)")
                    XCTAssertFalse(possible.isEmpty, "\(language) / \(type) / \(direction)")
                    XCTAssertTrue(certain.contains("på Klinga"), "\(certain)")
                    XCTAssertTrue(possible.contains("på Klinga"), "\(possible)")
                    if type == .temperatur {
                        XCTAssertFalse(certain.contains("Temperatur"), "\(certain)")
                        XCTAssertTrue(certain.contains(direction == .above ? "Over" : "Under"), "\(certain)")
                    }
                }
            }
        }
    }

    func testPushTitleUsesDialectTomorrowAndReservesWeekendForWeekendRules() {
        let calendar = Calendar.current
        let reference = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: base)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference)!
        let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: reference)!
        let rule = Rule(type: .regn)

        let dialectTomorrow = NotificationCopy.title(
            for: rule, placeName: "på Klinga", eventAt: tomorrow,
            referenceAt: reference, languageStyle: .inntrondersk
        )
        let ordinaryLaterDay = NotificationCopy.title(
            for: rule, placeName: "på Klinga", eventAt: dayAfterTomorrow,
            referenceAt: reference, languageStyle: .bokmal
        )
        var weekendRule = rule
        weekendRule.notificationWeekday = 5
        let weekend = NotificationCopy.title(
            for: weekendRule, placeName: "på Klinga", eventAt: dayAfterTomorrow,
            referenceAt: reference, languageStyle: .inntrondersk
        )

        XCTAssertTrue(dialectTomorrow.contains("i mårrå"), dialectTomorrow)
        XCTAssertTrue(ordinaryLaterDay.contains("på "), ordinaryLaterDay)
        XCTAssertFalse(ordinaryLaterDay.contains("til helga"), ordinaryLaterDay)
        XCTAssertTrue(weekend.contains("te helga"), weekend)
    }

    func testMemoSuggestionIsNotSentUntilActivated() {
        let reference = base
        var rule = Rule(type: .sol)
        rule.durationHours = 4
        rule.memoSuggestion = "Klipp gresset!"

        XCTAssertEqual(
            NotificationCopy.message(
                for: rule,
                eventAt: reference.addingTimeInterval(60 * 60),
                referenceAt: reference
            ),
            "4 timer om en time."
        )

        rule.customName = rule.memoSuggestion
        XCTAssertEqual(
            NotificationCopy.message(
                for: rule,
                eventAt: reference.addingTimeInterval(60 * 60),
                referenceAt: reference
            ),
            "4 timer om en time.\nKlipp gresset!"
        )
    }

    func testNotificationCopyUsesDetailInsteadOfRepeatingHeadlineTime() {
        var rule = Rule(type: .regn)
        rule.customName = "Vann plantene"
        let body = NotificationCopy.message(
            for: rule,
            eventAt: base.addingTimeInterval(2 * 3_600),
            referenceAt: base,
            eventDetail: "Opptil 0,9 mm over 1 time."
        )

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Opptil 0,9 mm over 1 time.")
        XCTAssertEqual(lines[1], "Vann plantene")
        XCTAssertFalse(lines[0].contains("om to timer"))
    }

    func testNotificationDetailUsesClockOnlyWhenItHelps() {
        let sameDay = NotificationCopy.message(
            for: Rule(type: .regn),
            eventAt: base.addingTimeInterval(2 * 3_600),
            referenceAt: base,
            eventDetail: "Litt regn {tid} — i 2 timer."
        )
        XCTAssertTrue(sameDay.contains("kl. "), sameDay)
        XCTAssertFalse(sameDay.contains("om to timer"), sameDay)

        let near = NotificationCopy.message(
            for: Rule(type: .regn),
            eventAt: base.addingTimeInterval(30 * 60),
            referenceAt: base,
            eventDetail: "Yr {tid}."
        )
        XCTAssertEqual(near, "Yr.")

        let calendar = Calendar.current
        let evening = try! XCTUnwrap(calendar.date(bySettingHour: 21, minute: 0, second: 0, of: base))
        let tomorrow = try! XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: evening))
        let night = try! XCTUnwrap(calendar.date(bySettingHour: 2, minute: 0, second: 0, of: tomorrow))
        let overnight = NotificationCopy.message(
            for: Rule(type: .frost),
            eventAt: night,
            referenceAt: evening,
            eventDetail: "Frost {tid}."
        )
        XCTAssertEqual(overnight, "Frost kl. 02.")
    }

    func testInntronderskKeepsMemoAsSeparateFinalLineForWeatherTypes() {
        for type in [AlertType.regn, .sno, .dugg, .frost, .vind, .temperatur, .sol] {
            var rule = Rule(type: type)
            rule.customName = "Ta med utstyr"
            let body = NotificationCopy.message(for: rule, eventAt: base.addingTimeInterval(3_600), referenceAt: base, languageStyle: .inntrondersk)
            XCTAssertEqual(body.split(separator: "\n").last, "Ta med utstyr", "\(type)")
        }
    }

    func testMainIconAndAlertTypeAgreeAtSleetBoundary() {
        let sleet = ForecastHour(time: base, temp: 1, precip: 0.2, wind: 2, cloud: 90, dew: 0)
        let rain = ForecastHour(time: base, temp: 1.1, precip: 0.2, wind: 2, cloud: 90, dew: 0)
        XCTAssertEqual(CurrentWeatherCondition.resolve(sleet).label, "Snø")
        XCTAssertTrue(AlertType.sno.matches(sleet, threshold: 0.1))
        XCTAssertEqual(CurrentWeatherCondition.resolve(rain).label, "Regn")
        XCTAssertTrue(AlertType.regn.matches(rain, threshold: 0.1))
    }

    func testTemperatureRuleAlertsBelowChosenThreshold() {
        var rule = Rule(type: .temperatur)
        rule.threshold = 10
        rule.leadMinutes = 60
        let hours = forecast(values: [
            (12, 0, 2, 20, 5),
            (9, 0, 2, 20, 5),
            (7, 0, 2, 20, 5),
            (11, 0, 2, 20, 5),
        ])

        let result = Planner.plan(
            rule: rule,
            forecast: hours,
            placeName: "på Klinga",
            now: base.addingTimeInterval(-2 * 3_600)
        )

        XCTAssertEqual(result.hitIndices, [1, 2])
        XCTAssertEqual(result.alerts.first?.eventDetail, "Under 10° {tid} — i 2 timer.")
        XCTAssertEqual(NotificationCopy.title(for: rule, placeName: "på Klinga"), "D bli Under 10°! på Klinga")
    }

    func testPlannerDoesNotScheduleTemperatureAlertForNonFiniteThreshold() {
        let hours = forecast(values: [(21, 0, 1, 20, 5)])

        for threshold in [Double.nan, .infinity, -.infinity] {
            for direction in Rule.TemperatureDirection.allCases {
                var rule = Rule(type: .temperatur)
                rule.threshold = threshold
                rule.temperatureDirection = direction
                rule.leadMinutes = 60

                let result = Planner.plan(
                    rule: rule,
                    forecast: hours,
                    placeName: "på Klinga",
                    now: base.addingTimeInterval(-2 * 3_600)
                )

                XCTAssertTrue(result.hitIndices.isEmpty, "\(direction.label) accepted threshold \(threshold).")
                XCTAssertTrue(result.alerts.isEmpty, "\(direction.label) scheduled threshold \(threshold).")
            }
        }
    }

    func testDuplicateForecastTimestampDoesNotSplitOrDuplicateAlertRun() {
        var rule = Rule(type: .regn)
        rule.threshold = 0.5
        rule.durationHours = 4
        rule.count = 1
        let uniqueHours = forecast(values: [
            (8, 1, 1, 80, 5),
            (8, 1, 1, 80, 5),
            (8, 1, 1, 80, 5),
            (8, 1, 1, 80, 5),
        ])
        let duplicateForecast = [
            uniqueHours[0], uniqueHours[1], uniqueHours[1], uniqueHours[2], uniqueHours[3]
        ]
        let now = base.addingTimeInterval(-2 * 3_600)

        let withoutDuplicate = Planner.plan(
            rule: rule, forecast: uniqueHours, placeName: "på Klinga", now: now
        )
        let withDuplicate = Planner.plan(
            rule: rule, forecast: duplicateForecast, placeName: "på Klinga", now: now
        )

        XCTAssertEqual(withoutDuplicate.alerts.count, 1)
        XCTAssertEqual(withDuplicate.alerts.count, withoutDuplicate.alerts.count)
        XCTAssertEqual(withDuplicate.alerts.first?.eventAt, withoutDuplicate.alerts.first?.eventAt)
        XCTAssertTrue(withDuplicate.alerts.first?.eventDetail?.contains("i 4 timer") == true)
    }

    func testPlannerDeduplicatesSamplesBeforeTemperatureWindAndDewPushDetails() throws {
        let uniqueHours = forecast(values: [
            (9, 0, 3, 40, 8),
            (8, 0, 3, 40, 7),
            (7, 0, 3, 40, 6),
        ])
        var gustHours = uniqueHours
        gustHours[0].gust = 10
        gustHours[1].gust = 12
        gustHours[2].gust = 11
        let duplicateTime = uniqueHours[2].time
        let now = base.addingTimeInterval(-2 * 3_600)

        func plannedDetail(for rule: Rule, hours: [ForecastHour]) -> String? {
            Planner.plan(rule: rule, forecast: hours, placeName: "på Klinga", now: now)
                .alerts.first?.eventDetail
        }

        var temperatureRule = Rule(type: .temperatur)
        temperatureRule.threshold = 10
        let temperatureDuplicate = ForecastHour(
            time: duplicateTime, temp: 0, precip: 0, wind: 3, cloud: 40, dew: 6
        )
        let temperatureDetail = try XCTUnwrap(plannedDetail(for: temperatureRule, hours: uniqueHours))
        let duplicateTemperatureDetail = try XCTUnwrap(plannedDetail(
            for: temperatureRule,
            hours: [uniqueHours[0], uniqueHours[1], uniqueHours[2], temperatureDuplicate]
        ))
        XCTAssertEqual(duplicateTemperatureDetail, temperatureDetail)
        XCTAssertTrue(temperatureDetail.contains("i 3 timer"), temperatureDetail)

        var windRule = Rule(type: .vind)
        windRule.threshold = 9
        var windDuplicate = gustHours[2]
        windDuplicate.gust = 40
        let windDetail = try XCTUnwrap(plannedDetail(for: windRule, hours: gustHours))
        let duplicateWindDetail = try XCTUnwrap(plannedDetail(
            for: windRule, hours: [gustHours[0], gustHours[1], gustHours[2], windDuplicate]
        ))
        XCTAssertEqual(duplicateWindDetail, windDetail)
        XCTAssertTrue(windDetail.contains("12 m/s"), windDetail)

        var dewRule = Rule(type: .dugg)
        dewRule.threshold = 1
        let dewDuplicate = ForecastHour(
            time: duplicateTime, temp: 7, precip: 0, wind: 3, cloud: 40, dew: 7
        )
        let dewDetail = try XCTUnwrap(plannedDetail(for: dewRule, hours: uniqueHours))
        let duplicateDewDetail = try XCTUnwrap(plannedDetail(
            for: dewRule, hours: [uniqueHours[0], uniqueHours[1], uniqueHours[2], dewDuplicate]
        ))
        XCTAssertEqual(duplicateDewDetail, dewDetail)
        XCTAssertTrue(dewDetail.contains("i 3 timer"), dewDetail)
        XCTAssertTrue(dewDetail.contains("ved 9°"), dewDetail)
    }

    func testConflictingDuplicateForecastTimestampDoesNotInflateRainSummary() {
        var rule = Rule(type: .regn)
        rule.threshold = 0.5
        rule.durationHours = 3
        rule.leadMinutes = 60
        rule.count = 1
        let uniqueHours = forecast(values: [
            (8, 0.6, 1, 80, 5),
            (8, 0.6, 1, 80, 5),
            (8, 0.6, 1, 80, 5),
        ])
        let conflictingDuplicate = ForecastHour(
            time: uniqueHours[1].time, temp: 8, precip: 5, wind: 1, cloud: 80, dew: 5
        )
        let now = base.addingTimeInterval(-2 * 3_600)

        let withoutDuplicate = Planner.plan(
            rule: rule, forecast: uniqueHours, placeName: "på Klinga", now: now
        )
        let withDuplicate = Planner.plan(
            rule: rule,
            forecast: [uniqueHours[0], uniqueHours[1], conflictingDuplicate, uniqueHours[2]],
            placeName: "på Klinga",
            now: now
        )

        XCTAssertEqual(withoutDuplicate.alerts.count, 1)
        XCTAssertEqual(withDuplicate.alerts.count, 1)
        XCTAssertEqual(withDuplicate.alerts.first?.eventDetail, withoutDuplicate.alerts.first?.eventDetail)
        XCTAssertEqual(withDuplicate.alerts.first?.eventDetail, "Regn {tid} — i 3 timer.")
    }

    func testLocalFrostMarginCreatesPossibleFrostAlertWithoutChangingForecastTemperature() {
        var rule = Rule(type: .frost)
        rule.threshold = 0
        rule.leadMinutes = 60
        let hours = forecast(values: [
            (2, 0, 1, 5, 1),
            (1.5, 0, 1, 5, 1),
            (3, 0, 1, 5, 1),
        ])

        let withoutMargin = Planner.plan(
            rule: rule,
            forecast: hours,
            placeName: "på Andersmovegen",
            now: base.addingTimeInterval(-2 * 3_600)
        )
        let withMargin = Planner.plan(
            rule: rule,
            forecast: hours,
            placeName: "på Andersmovegen",
            frostMargin: 2.5,
            now: base.addingTimeInterval(-2 * 3_600)
        )

        XCTAssertTrue(withoutMargin.hitIndices.isEmpty)
        XCTAssertEqual(withMargin.hitIndices, [0, 1])
        XCTAssertTrue(withMargin.possible)
        XCTAssertEqual(
            withMargin.alerts.first?.eventDetail,
            "Yr melder ned mot 1,5°. Lokal frostmargin er +2,5°."
        )
        let liveStatus = Planner.status(
            for: rule,
            forecast: hours,
            frostMargin: 2.5,
            now: base.addingTimeInterval(-2 * 3_600)
        )
        XCTAssertEqual(liveStatus?.type, .frost)
        XCTAssertTrue(liveStatus?.possible == true)
        XCTAssertEqual(hours[0].temp, 2)
    }

    func testPlaceCanDisablePushAndChooseRuleOnlyDisplay() {
        var rain = Rule(type: .regn)
        rain.leadMinutes = 60
        var place = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: [rain])
        place.notificationsEnabled = false
        let hours = forecast(values: [(5, 1, 2, 80, 2), (5, 1, 2, 80, 2)])
        XCTAssertTrue(Planner.planAll(places: [place], forecasts: [place.id: hours]).isEmpty)

        XCTAssertEqual(place.rulesForDisplay.count, AlertType.allCases.count)
        place.rulesOnlyDisplay = true
        XCTAssertEqual(place.rulesForDisplay.count, 1)
    }

    func testLongLeadUsesCalendarLanguageInsteadOfHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 3, hour: 0)))
        let event = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 5, hour: 17)))

        XCTAssertEqual(eventTimePhrase(event, relativeTo: reference, calendar: calendar), "i overmorgen, onsdag kl. 17")
        XCTAssertFalse(eventTimePhrase(event, relativeTo: reference, calendar: calendar).contains("timer"))
    }

    func testFortyOneHoursUsesDayAndClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 3, hour: 12)))
        let event = reference.addingTimeInterval(41 * 60 * 60)

        XCTAssertEqual(eventTimePhrase(event, relativeTo: reference, calendar: calendar), "natt til onsdag kl. 05")
    }

    func testTomorrowStartsAtSixAndEarlierHoursAreTonight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 3, hour: 20)))
        let atTwo = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 4, hour: 2)))
        let atSix = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 6, day: 4, hour: 6)))

        XCTAssertEqual(eventTimePhrase(atTwo, relativeTo: reference, calendar: calendar), "i natt kl. 02")
        XCTAssertEqual(eventTimePhrase(atSix, relativeTo: reference, calendar: calendar), "i morgen, tirsdag kl. 06")
    }

    func testPlannerUsesInjectedOsloCalendarAcrossDaylightSavingTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 3, day: 30, hour: 20)))
        let event = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 3, day: 31, hour: 8)))
        var rule = Rule(type: .regn)
        rule.activeFromHour = 7
        rule.activeToHour = 22
        rule.previousDayNotificationHour = 21

        let result = Planner.plan(
            rule: rule,
            forecast: [ForecastHour(time: event, temp: 6, precip: 1, wind: 2, cloud: 100, dew: 5)],
            placeName: "Oslo",
            now: now,
            calendar: calendar
        )
        let alert = try XCTUnwrap(result.alerts.first)
        let expectedFire = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 3, day: 30, hour: 21)))

        XCTAssertEqual(alert.eventAt, event)
        XCTAssertEqual(alert.fireAt, expectedFire)
    }

    func testTodayAndTonightDoNotRepeatTheWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 8)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 16)))
        let tonight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 15, hour: 2)))

        XCTAssertEqual(eventTimePhrase(today, relativeTo: reference, calendar: calendar), "i dag kl. 16")
        XCTAssertEqual(eventTimePhrase(tonight, relativeTo: reference, calendar: calendar), "i natt kl. 02")
    }

    func testClearSkyWindowStartsAtSeven() throws {
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2030, month: 6, day: 3, hour: 6)))
        var rule = Rule(type: .sol)
        rule.durationHours = 4
        rule.activeFromHour = 7
        rule.activeToHour = 22
        let hours = (0..<6).map { index in
            ForecastHour(time: day.addingTimeInterval(TimeInterval(index * 3_600)), temp: 15, precip: 0, wind: 2, cloud: 5, dew: 8)
        }

        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: day.addingTimeInterval(-3_600))

        XCTAssertEqual(result.eventAt, hours[1].time)
        XCTAssertFalse(result.hitIndices.contains(0))
        XCTAssertTrue(result.hitIndices.contains(1))
    }

    func testCurrentClearSkyStatusShowsActualDuration() throws {
        let seven = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2030, month: 6, day: 3, hour: 7)))
        var rule = Rule(type: .sol)
        rule.durationHours = 4
        let hours = (0..<6).map { index in
            ForecastHour(time: seven.addingTimeInterval(TimeInterval(index * 3_600)), temp: 15, precip: 0, wind: 2, cloud: 5, dew: 8)
        }

        let status = Planner.status(for: rule, forecast: hours, now: seven.addingTimeInterval(5 * 60))

        XCTAssertEqual(status?.text, "Sol i 6 timer nå.")
        XCTAssertEqual(status?.isNow, true)
    }

    func testRepeatsAreOffUntilExplicitlyEnabled() {
        var rule = Rule(type: .regn)
        rule.leadMinutes = 120
        rule.count = 3
        let hours = forecast(values: [
            (5, 0, 2, 80, 2),
            (5, 0, 2, 80, 2),
            (5, 1, 2, 80, 2),
        ])

        XCTAssertEqual(Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: base.addingTimeInterval(-60)).alerts.count, 1)
        rule.repeatsEnabled = true
        XCTAssertEqual(Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: base.addingTimeInterval(-60)).alerts.count, 3)
    }

    func testDewAlertWaitsUntilThreeRainFreeHoursHavePassed() {
        var rule = Rule(type: .dugg)
        rule.threshold = 1
        let hours = forecast(values: [
            (5, 1, 2, 100, 4.5),
            (5, 0, 2, 100, 4.5),
            (5, 0, 2, 100, 4.5),
            (5, 0, 2, 100, 4.5),
            (5, 0, 2, 100, 4.5),
        ])

        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: base.addingTimeInterval(-60))

        XCTAssertEqual(result.eventAt, hours[4].time)
        XCTAssertEqual(result.hitIndices, [4])
    }

    func testDewAlertIsAlsoSuppressedAfterSnow() {
        var rule = Rule(type: .dugg)
        rule.threshold = 1
        let hours = forecast(values: [
            (0, 1, 2, 100, -0.5),
            (0, 0, 2, 100, -0.5),
            (0, 0, 2, 100, -0.5),
        ])

        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Selbu", now: base.addingTimeInterval(-60))

        XCTAssertTrue(result.hitIndices.isEmpty)
        XCTAssertNil(result.eventAt)
    }

    func testDewAlertResumesAfterRainAcrossMidnight() {
        var rule = Rule(type: .dugg)
        rule.threshold = 1
        let rainAt = base.addingTimeInterval(-2 * 3_600)
        let dewAt = base.addingTimeInterval(2 * 3_600)
        let hours = [
            ForecastHour(time: rainAt, temp: 5, precip: 1, wind: 2, cloud: 100, dew: 4.5),
            ForecastHour(time: base, temp: 5, precip: 0, wind: 2, cloud: 100, dew: 4.5),
            ForecastHour(time: base.addingTimeInterval(3_600), temp: 5, precip: 0, wind: 2, cloud: 100, dew: 4.5),
            ForecastHour(time: dewAt, temp: 5, precip: 0, wind: 2, cloud: 100, dew: 4.5)
        ]
        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Klinga", now: base.addingTimeInterval(-60))
        XCTAssertEqual(result.eventAt, dewAt)
    }

    func testNearbyRainRulesDoNotCreateDuplicateNotifications() {
        var first = Rule(type: .regn)
        first.leadMinutes = 60
        var second = Rule(type: .regn)
        second.leadMinutes = 60
        second.customName = "Ta med paraply"
        let place = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: [first, second])
        let event = Date().addingTimeInterval(3 * 3_600)
        let hours = [ForecastHour(time: event, temp: 5, precip: 1, wind: 2, cloud: 100, dew: 4)]

        let alerts = Planner.planAll(places: [place], forecasts: [place.id: hours])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.placeID, place.id)
    }

    func testPlanAllKeepsSameRainEventForDifferentPlaces() {
        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 60
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 60

        let firstPlace = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: [firstRule])
        let secondPlace = Place(name: "Klinga", lat: 64.6, lon: 11.6, rules: [secondRule])
        let eventAt = base.addingTimeInterval(3 * 3_600)
        let forecast = [ForecastHour(time: eventAt, temp: 8, precip: 1, wind: 1, cloud: 60, dew: 7)]

        let alerts = Planner.planAll(
            places: [firstPlace, secondPlace],
            forecasts: [firstPlace.id: forecast, secondPlace.id: forecast]
        )

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.placeID)), Set([firstPlace.id, secondPlace.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([eventAt]))
    }

    func testPlanAllDeduplicatesRainIndependentlyAcrossPlaces() {
        let firstEventAt = base.addingTimeInterval(2 * 3_600)
        let secondEventAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func rainRule(at eventAt: Date) -> Rule {
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = 60
            let hour = calendar.component(.hour, from: eventAt)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }
        let firstPlaceRules = [rainRule(at: firstEventAt), rainRule(at: secondEventAt)]
        let secondPlaceRules = [rainRule(at: firstEventAt), rainRule(at: secondEventAt)]
        let firstPlace = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: firstPlaceRules)
        let secondPlace = Place(name: "Klinga", lat: 64.6, lon: 11.6, rules: secondPlaceRules)
        let forecast = makeForecast(through: 5, precipitationOffsets: [2, 5])

        let alerts = Planner.planAll(
            places: [firstPlace, secondPlace],
            forecasts: [firstPlace.id: forecast, secondPlace.id: forecast],
            now: base
        )

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.placeID)), Set([firstPlace.id, secondPlace.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([firstEventAt]))
        XCTAssertEqual(
            Set(alerts.map(\.rule.id)),
            Set([firstPlaceRules[0].id, secondPlaceRules[0].id])
        )
    }

    func testPlanAllKeepsNearbyOnlyRainForOnePlaceWithoutDeduplicatingAnotherPlace() {
        let firstEventAt = base.addingTimeInterval(2 * 3_600)
        let nearbyEventAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func rainRule(at eventAt: Date, onlyWhenNearby: Bool = false) -> Rule {
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = 60
            rule.onlyWhenNearby = onlyWhenNearby
            let hour = calendar.component(.hour, from: eventAt)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }
        let firstRule = rainRule(at: firstEventAt)
        let nearbyRule = rainRule(at: nearbyEventAt, onlyWhenNearby: true)
        let firstPlace = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: [firstRule])
        let nearbyPlace = Place(name: "Klinga", lat: 64.6, lon: 11.6, rules: [nearbyRule])
        let forecast = makeForecast(through: 5, precipitationOffsets: [2, 5])

        let alerts = Planner.planAll(
            places: [firstPlace, nearbyPlace],
            forecasts: [firstPlace.id: forecast, nearbyPlace.id: forecast],
            nearbyPlaceIDs: [nearbyPlace.id],
            now: base
        )
        let alertsWhileAway = Planner.planAll(
            places: [firstPlace, nearbyPlace],
            forecasts: [firstPlace.id: forecast, nearbyPlace.id: forecast],
            now: base
        )

        XCTAssertEqual(nearbyEventAt.timeIntervalSince(firstEventAt), 3 * 3_600)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.placeID)), Set([firstPlace.id, nearbyPlace.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([firstEventAt, nearbyEventAt]))
        XCTAssertEqual(alertsWhileAway.map(\.placeID), [firstPlace.id])
    }

    func testPlanAllSortsAlertsByFireTimeAcrossPlaces() {
        let earlierEvent = base.addingTimeInterval(3 * 3_600)
        let laterEvent = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func rainRule(at eventAt: Date, leadMinutes: Int) -> Rule {
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = leadMinutes
            let hour = calendar.component(.hour, from: eventAt)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }
        let earlierRule = rainRule(at: earlierEvent, leadMinutes: 60)
        let laterRule = rainRule(at: laterEvent, leadMinutes: 240)
        let earlierPlace = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: [earlierRule])
        let laterPlace = Place(name: "Klinga", lat: 64.6, lon: 11.6, rules: [laterRule])
        let forecast = makeForecast(through: 5, precipitationOffsets: [3, 5])

        let alerts = Planner.planAll(
            places: [earlierPlace, laterPlace],
            forecasts: [earlierPlace.id: forecast, laterPlace.id: forecast],
            now: base
        )

        XCTAssertLessThan(alerts[0].fireAt, alerts[1].fireAt)
        XCTAssertEqual(alerts.map(\.rule.id), [laterRule.id, earlierRule.id])
        XCTAssertEqual(alerts.map(\.eventAt), [laterEvent, earlierEvent])
    }

    func testPlanAllOrdersEqualFireTimesByEventThenSeverityThenRuleID() {
        let eventAt = base.addingTimeInterval(2 * 3_600)
        let calendar = Calendar.current
        let eventHour = calendar.component(.hour, from: eventAt)
        var frost = Rule(type: .frost)
        frost.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        frost.threshold = 0
        frost.leadMinutes = 60
        frost.activeFromHour = eventHour
        frost.activeToHour = (eventHour + 1) % 24
        var snow = Rule(type: .sno)
        snow.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        snow.threshold = 0.3
        snow.leadMinutes = 60
        snow.activeFromHour = eventHour
        snow.activeToHour = (eventHour + 1) % 24
        var wind = Rule(type: .vind)
        wind.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        wind.threshold = 9
        wind.leadMinutes = 60
        wind.activeFromHour = eventHour
        wind.activeToHour = (eventHour + 1) % 24
        let placeID = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        var place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [wind, snow, frost])
        place.id = placeID
        var hour = ForecastHour(time: eventAt, temp: -2, precip: 1, wind: 1, cloud: 60, dew: -3)
        hour.gust = 12
        let forecast = [hour]

        func planned(_ rules: [Rule]) -> [PlannedAlert] {
            var reorderedPlace = place
            reorderedPlace.rules = rules
            return Planner.planAll(
                places: [reorderedPlace], forecasts: [placeID: forecast], now: base
            )
        }

        let forward = planned([wind, snow, frost])
        let reverse = planned([frost, snow, wind])

        XCTAssertEqual(
            forward.map(\.fireAt),
            Array(repeating: eventAt.addingTimeInterval(-3_600), count: 3)
        )
        XCTAssertEqual(forward.map(\.eventAt), Array(repeating: eventAt, count: 3))
        XCTAssertEqual(forward.map(\.id), reverse.map(\.id))
        XCTAssertEqual(forward.map { $0.rule.type }, [.frost, .sno, .vind])
        XCTAssertEqual(forward.map { $0.rule.id.uuidString }, [
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003",
        ])
    }

    func testPlanAllDeduplicatesRainWithoutDroppingOtherWeatherAlerts() {
        var firstRain = Rule(type: .regn)
        firstRain.threshold = 0.5
        firstRain.leadMinutes = 60
        var secondRain = Rule(type: .regn)
        secondRain.threshold = 0.5
        secondRain.leadMinutes = 60
        secondRain.customName = "Ta med paraply"
        var wind = Rule(type: .vind)
        wind.threshold = 9
        wind.leadMinutes = 60
        var dew = Rule(type: .dugg)
        dew.threshold = 1
        dew.leadMinutes = 60
        var temperature = Rule(type: .temperatur)
        temperature.threshold = 10
        temperature.leadMinutes = 60

        let place = Place(
            name: "Klinga", lat: 64.5, lon: 11.5,
            rules: [firstRain, secondRain, wind, dew, temperature]
        )
        var hours = forecast(values: [
            (8, 1, 3, 80, 7),
            (8, 0, 3, 80, 7),
            (8, 0, 3, 80, 7),
            (8, 0, 3, 80, 7),
            (8, 0, 3, 80, 7),
        ])
        for index in hours.indices { hours[index].gust = 10 }

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: base.addingTimeInterval(-3 * 3_600)
        )

        XCTAssertEqual(alerts.filter { $0.rule.type == .regn }.count, 1)
        XCTAssertEqual(alerts.filter { $0.rule.type == .vind }.count, 1)
        XCTAssertEqual(alerts.filter { $0.rule.type == .dugg }.count, 1)
        XCTAssertEqual(alerts.filter { $0.rule.type == .temperatur }.count, 1)
    }

    func testPlanAllRainCooldownDoesNotDropNearbySnowAlert() {
        var rain = Rule(type: .regn)
        rain.threshold = 0.5
        rain.leadMinutes = 60
        var snow = Rule(type: .sno)
        snow.threshold = 0.5
        snow.leadMinutes = 60

        let rainAt = base.addingTimeInterval(2 * 3_600)
        let snowAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        let rainHour = calendar.component(.hour, from: rainAt)
        rain.activeFromHour = rainHour
        rain.activeToHour = (rainHour + 1) % 24
        let snowHour = calendar.component(.hour, from: snowAt)
        snow.activeFromHour = snowHour
        snow.activeToHour = (snowHour + 1) % 24

        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [rain, snow])
        let forecast: [ForecastHour] = (0...5).map { offset -> ForecastHour in
            let temperature = offset == 5 ? 0.0 : 8.0
            let precipitation = offset == 2 || offset == 5 ? 1.0 : 0.0
            return ForecastHour(
                time: base.addingTimeInterval(TimeInterval(offset) * 3_600),
                temp: temperature,
                precip: precipitation,
                wind: 1,
                cloud: 60,
                dew: 7
            )
        }

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: forecast]
        )

        let rainAlerts: [PlannedAlert] = alerts.filter { $0.rule.type == AlertType.regn }
        let snowAlerts: [PlannedAlert] = alerts.filter { $0.rule.type == AlertType.sno }
        let ruleIDs: Set<UUID> = Set(alerts.map { $0.rule.id })
        let eventTimes: Set<Date> = Set(alerts.map { $0.eventAt })
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(rainAlerts.count, 1)
        XCTAssertEqual(snowAlerts.count, 1)
        XCTAssertEqual(ruleIDs, Set([rain.id, snow.id]))
        XCTAssertEqual(eventTimes, Set([rainAt, snowAt]))
    }

    func testPlanAllDoesNotDeduplicateRainAgainstNearbySnowAtAnotherPlace() {
        let rainAt = base.addingTimeInterval(2 * 3_600)
        let snowAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        var rain = Rule(type: .regn)
        rain.threshold = 0.5
        rain.leadMinutes = 60
        let rainHour = calendar.component(.hour, from: rainAt)
        rain.activeFromHour = rainHour
        rain.activeToHour = (rainHour + 1) % 24

        var snow = Rule(type: .sno)
        snow.threshold = 0.5
        snow.leadMinutes = 60
        let snowHour = calendar.component(.hour, from: snowAt)
        snow.activeFromHour = snowHour
        snow.activeToHour = (snowHour + 1) % 24

        let rainPlace = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: [rain])
        let snowPlace = Place(name: "Klinga", lat: 64.6, lon: 11.6, rules: [snow])
        let forecast: [ForecastHour] = (0...5).map { offset -> ForecastHour in
            let temperature = offset == 5 ? 0.0 : 8.0
            let precipitation = offset == 2 || offset == 5 ? 1.0 : 0.0
            return ForecastHour(
                time: base.addingTimeInterval(TimeInterval(offset) * 3_600),
                temp: temperature,
                precip: precipitation,
                wind: 1,
                cloud: 60,
                dew: 7
            )
        }

        let alerts = Planner.planAll(
            places: [rainPlace, snowPlace],
            forecasts: [rainPlace.id: forecast, snowPlace.id: forecast],
            now: base
        )

        XCTAssertEqual(alerts.count, 2)
        let placeIDs: Set<UUID> = Set(alerts.compactMap { $0.placeID })
        let rainEvents: [Date] = alerts.filter { $0.rule.type == AlertType.regn }.map { $0.eventAt }
        let snowEvents: [Date] = alerts.filter { $0.rule.type == AlertType.sno }.map { $0.eventAt }
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(placeIDs, Set([rainPlace.id, snowPlace.id]))
        XCTAssertEqual(rainEvents, [rainAt])
        XCTAssertEqual(snowEvents, [snowAt])
    }

    func testPlanAllKeepsWindAlertBetweenDeduplicatedRainAlerts() {
        var firstRain = Rule(type: .regn)
        firstRain.threshold = 0.5
        firstRain.leadMinutes = 60
        var wind = Rule(type: .vind)
        wind.threshold = 9
        wind.leadMinutes = 60
        var secondRain = Rule(type: .regn)
        secondRain.threshold = 0.5
        secondRain.leadMinutes = 60

        let firstRainAt = base.addingTimeInterval(2 * 3_600)
        let windAt = base.addingTimeInterval(4 * 3_600)
        let secondRainAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func isolateRule(_ rule: inout Rule, at time: Date) {
            let hour = calendar.component(.hour, from: time)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
        }
        isolateRule(&firstRain, at: firstRainAt)
        isolateRule(&wind, at: windAt)
        isolateRule(&secondRain, at: secondRainAt)

        var hours = makeForecast(through: 5, precipitationOffsets: [2, 5])
        hours[4].gust = 12
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRain, wind, secondRain])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: base
        )

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.rule.id)), Set([firstRain.id, wind.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([firstRainAt, windAt]))
    }

    func testRainDeduplicationUsesEventTimeInsteadOfNotificationTime() {
        var eveningRule = Rule(type: .regn)
        eveningRule.leadMinutes = 12 * 60
        var shortLeadRule = Rule(type: .regn)
        shortLeadRule.leadMinutes = 60
        let place = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: [eveningRule, shortLeadRule])
        let event = base.addingTimeInterval(15 * 3_600)
        let hours = [ForecastHour(time: event, temp: 5, precip: 1, wind: 2, cloud: 100, dew: 4)]

        let alerts = Planner.planAll(places: [place], forecasts: [place.id: hours])

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.rule.id, eveningRule.id)
    }

    func testPlanAllKeepsRainAlertsExactlyAtSixHourCooldownBoundary() {
        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 60
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 60

        let firstEventAt = base.addingTimeInterval(2 * 3_600)
        let secondEventAt = firstEventAt.addingTimeInterval(6 * 3_600)
        let calendar = Calendar.current
        func isolateRule(_ rule: inout Rule, at time: Date) {
            let hour = calendar.component(.hour, from: time)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
        }
        isolateRule(&firstRule, at: firstEventAt)
        isolateRule(&secondRule, at: secondEventAt)

        let hours = makeForecast(through: 8, precipitationOffsets: [2, 8])
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRule, secondRule])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: base
        )

        XCTAssertEqual(firstEventAt.timeIntervalSince(base), 2 * 3_600)
        XCTAssertEqual(secondEventAt.timeIntervalSince(firstEventAt), 6 * 3_600)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.rule.id)), Set([firstRule.id, secondRule.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([firstEventAt, secondEventAt]))
    }

    func testPlanAllRainCooldownUsesElapsedTimeAcrossSpringDSTTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let firstEventAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2030, month: 3, day: 31, hour: 1
        )))
        let secondEventAt = firstEventAt.addingTimeInterval(5 * 3_600)
        XCTAssertEqual(calendar.component(.hour, from: firstEventAt), 1)
        XCTAssertEqual(calendar.component(.hour, from: secondEventAt), 7)
        XCTAssertEqual(secondEventAt.timeIntervalSince(firstEventAt), 5 * 3_600)

        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 60
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 60
        firstRule.activeFromHour = 1
        firstRule.activeToHour = 2
        secondRule.activeFromHour = 7
        secondRule.activeToHour = 8

        let forecastStart = firstEventAt.addingTimeInterval(-3_600)
        let hours = makeForecast(through: 7, startingAt: forecastStart, precipitationOffsets: [1, 6])
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRule, secondRule])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours],
            now: forecastStart.addingTimeInterval(-3_600), calendar: calendar
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.rule.id, firstRule.id)
        XCTAssertEqual(alerts.first?.eventAt, firstEventAt)
    }

    func testPlanAllDeduplicatesRainAlertsWithinSixHourCooldown() {
        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 60
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 60

        let firstEventAt = base.addingTimeInterval(2 * 3_600)
        let secondEventAt = firstEventAt.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func isolateRule(_ rule: inout Rule, at time: Date) {
            let hour = calendar.component(.hour, from: time)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
        }
        isolateRule(&firstRule, at: firstEventAt)
        isolateRule(&secondRule, at: secondEventAt)

        let hours = makeForecast(through: 7, precipitationOffsets: [2, 7])
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRule, secondRule])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: base
        )

        XCTAssertEqual(secondEventAt.timeIntervalSince(firstEventAt), 5 * 3_600)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.rule.id, firstRule.id)
        XCTAssertEqual(alerts.first?.eventAt, firstEventAt)
    }

    func testPlanAllRainCooldownKeepsEarlierEventWhenItFiresLater() throws {
        let firstEventAt = base.addingTimeInterval(2 * 3_600)
        let secondEventAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 30
        let firstHour = calendar.component(.hour, from: firstEventAt)
        firstRule.activeFromHour = firstHour
        firstRule.activeToHour = (firstHour + 1) % 24
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 300
        let secondHour = calendar.component(.hour, from: secondEventAt)
        secondRule.activeFromHour = secondHour
        secondRule.activeToHour = (secondHour + 1) % 24

        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRule, secondRule])
        let forecast = makeForecast(through: 5, precipitationOffsets: [2, 5])
        let now = base.addingTimeInterval(-3_600)
        let firstFireAt = try XCTUnwrap(Planner.plan(
            rule: firstRule, forecast: forecast, placeName: place.name,
            now: now, calendar: calendar
        ).alerts.first?.fireAt)
        let secondFireAt = try XCTUnwrap(Planner.plan(
            rule: secondRule, forecast: forecast, placeName: place.name,
            now: now, calendar: calendar
        ).alerts.first?.fireAt)
        XCTAssertLessThan(secondFireAt, firstFireAt)

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: forecast], now: now
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.rule.id, firstRule.id)
        XCTAssertEqual(alerts.first?.eventAt, firstEventAt)
    }

    func testPlanAllRainCooldownIsDeterministicForTiedFireTimes() throws {
        let firstEventAt = base.addingTimeInterval(2 * 3_600)
        let secondEventAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func rainRule(at eventAt: Date, leadMinutes: Int) -> Rule {
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = leadMinutes
            let hour = calendar.component(.hour, from: eventAt)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }

        let earlierFirst = rainRule(at: firstEventAt, leadMinutes: 60)
        let laterSecond = rainRule(at: secondEventAt, leadMinutes: 240)
        let laterFirst = rainRule(at: secondEventAt, leadMinutes: 240)
        let earlierSecond = rainRule(at: firstEventAt, leadMinutes: 60)
        let earlierPlace = Place(
            name: "Namsos", lat: 64.5, lon: 11.5,
            rules: [laterSecond, earlierFirst]
        )
        let reversedPlace = Place(
            name: "Klinga", lat: 64.6, lon: 11.6,
            rules: [earlierSecond, laterFirst]
        )
        let forecast = makeForecast(through: 5, precipitationOffsets: [2, 5])
        let now = base
        let earlyFireAt = try XCTUnwrap(Planner.plan(
            rule: earlierFirst, forecast: forecast, placeName: earlierPlace.name,
            now: now, calendar: calendar
        ).alerts.first?.fireAt)
        let lateFireAt = try XCTUnwrap(Planner.plan(
            rule: laterSecond, forecast: forecast, placeName: earlierPlace.name,
            now: now, calendar: calendar
        ).alerts.first?.fireAt)
        XCTAssertEqual(earlyFireAt, lateFireAt)

        let alerts = Planner.planAll(
            places: [earlierPlace, reversedPlace],
            forecasts: [earlierPlace.id: forecast, reversedPlace.id: forecast],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(alerts.count, 2)
        for place in [earlierPlace, reversedPlace] {
            let placeAlerts = alerts.filter { $0.placeID == place.id }
            XCTAssertEqual(placeAlerts.count, 1)
            XCTAssertEqual(placeAlerts.first?.eventAt, firstEventAt)
        }
    }

    func testPlanAllIgnoresFilteredRainRulesDuringCooldownDeduplication() {
        let ignoredEventAt = base.addingTimeInterval(2 * 3_600)
        let validEventAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func rainRule(at eventAt: Date) -> Rule {
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = 60
            let hour = calendar.component(.hour, from: eventAt)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }
        let forecast = makeForecast(through: 5, precipitationOffsets: [2, 5])
        func plan(with ignoredRule: Rule) -> (alerts: [PlannedAlert], validRuleID: UUID) {
            let validRule = rainRule(at: validEventAt)
            let place = Place(
                name: "Klinga", lat: 64.5, lon: 11.5,
                rules: [ignoredRule, validRule]
            )
            let alerts = Planner.planAll(
                places: [place], forecasts: [place.id: forecast], now: base
            )
            return (alerts, validRule.id)
        }

        var disabledRule = rainRule(at: ignoredEventAt)
        disabledRule.enabled = false
        let disabledResult = plan(with: disabledRule)
        XCTAssertEqual(disabledResult.alerts.count, 1)
        XCTAssertEqual(disabledResult.alerts.first?.rule.id, disabledResult.validRuleID)
        XCTAssertEqual(disabledResult.alerts.first?.eventAt, validEventAt)

        var notNearbyRule = rainRule(at: ignoredEventAt)
        notNearbyRule.onlyWhenNearby = true
        let notNearbyResult = plan(with: notNearbyRule)
        XCTAssertEqual(notNearbyResult.alerts.count, 1)
        XCTAssertEqual(notNearbyResult.alerts.first?.rule.id, notNearbyResult.validRuleID)
        XCTAssertEqual(notNearbyResult.alerts.first?.eventAt, validEventAt)
    }

    func testPlanAllKeepsRainAlertsAtSixHourBoundaryWithReversedFireOrder() throws {
        let firstEventAt = base.addingTimeInterval(2 * 3_600)
        let secondEventAt = firstEventAt.addingTimeInterval(6 * 3_600)
        let calendar = Calendar.current
        func rainRule(at eventAt: Date, leadMinutes: Int) -> Rule {
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = leadMinutes
            let hour = calendar.component(.hour, from: eventAt)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }
        let firstRule = rainRule(at: firstEventAt, leadMinutes: 60)
        let secondRule = rainRule(at: secondEventAt, leadMinutes: 480)
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [secondRule, firstRule])
        let forecast = makeForecast(through: 8, precipitationOffsets: [2, 8])
        let now = base.addingTimeInterval(-3_600)
        let firstFireAt = try XCTUnwrap(Planner.plan(
            rule: firstRule, forecast: forecast, placeName: place.name,
            now: now, calendar: calendar
        ).alerts.first?.fireAt)
        let secondFireAt = try XCTUnwrap(Planner.plan(
            rule: secondRule, forecast: forecast, placeName: place.name,
            now: now, calendar: calendar
        ).alerts.first?.fireAt)
        XCTAssertEqual(secondEventAt.timeIntervalSince(firstEventAt), 6 * 3_600)
        XCTAssertLessThan(secondFireAt, firstFireAt)

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: forecast],
            now: now, calendar: calendar
        )

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.rule.id)), Set([firstRule.id, secondRule.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([firstEventAt, secondEventAt]))
        XCTAssertEqual(alerts.map(\.fireAt), [secondFireAt, firstFireAt])
    }

    func testPlanAllKeepsEveryRepeatForTheRetainedRainEvent() {
        let firstEventAt = base.addingTimeInterval(2 * 3_600)
        let duplicateEventAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func rainRule(at eventAt: Date, leadMinutes: Int) -> Rule {
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = leadMinutes
            let hour = calendar.component(.hour, from: eventAt)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }
        var retainedRule = rainRule(at: firstEventAt, leadMinutes: 120)
        retainedRule.repeatsEnabled = true
        retainedRule.count = 3
        retainedRule.intervalMinutes = 30
        let duplicateRule = rainRule(at: duplicateEventAt, leadMinutes: 60)
        let place = Place(
            name: "Klinga", lat: 64.5, lon: 11.5,
            rules: [retainedRule, duplicateRule]
        )
        let forecast = makeForecast(through: 5, precipitationOffsets: [2, 5])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: forecast],
            now: base.addingTimeInterval(-3_600), calendar: calendar
        )

        XCTAssertEqual(alerts.count, 3)
        XCTAssertEqual(Set(alerts.map(\.rule.id)), Set([retainedRule.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([firstEventAt]))
        XCTAssertEqual(
            Set(alerts.map(\.fireAt)),
            Set([base, base.addingTimeInterval(30 * 60), base.addingTimeInterval(60 * 60)])
        )
    }

    func testPlanAllIncludedNearbyRainRuleParticipatesInCooldown() {
        let nearbyEventAt = base.addingTimeInterval(2 * 3_600)
        let ordinaryEventAt = base.addingTimeInterval(5 * 3_600)
        let calendar = Calendar.current
        func rainRule(at eventAt: Date, nearbyOnly: Bool) -> Rule {
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = 60
            rule.onlyWhenNearby = nearbyOnly
            let hour = calendar.component(.hour, from: eventAt)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }
        let nearbyRule = rainRule(at: nearbyEventAt, nearbyOnly: true)
        let ordinaryRule = rainRule(at: ordinaryEventAt, nearbyOnly: false)
        let place = Place(
            name: "Klinga", lat: 64.5, lon: 11.5,
            rules: [ordinaryRule, nearbyRule]
        )
        let forecast = makeForecast(through: 5, precipitationOffsets: [2, 5])

        let alertsWhenAway = Planner.planAll(
            places: [place], forecasts: [place.id: forecast], now: base
        )
        let alertsWhenNearby = Planner.planAll(
            places: [place], forecasts: [place.id: forecast],
            nearbyPlaceIDs: [place.id], now: base
        )

        XCTAssertEqual(alertsWhenAway.count, 1)
        XCTAssertEqual(alertsWhenAway.first?.rule.id, ordinaryRule.id)
        XCTAssertEqual(alertsWhenAway.first?.eventAt, ordinaryEventAt)
        XCTAssertEqual(alertsWhenNearby.count, 1)
        XCTAssertEqual(alertsWhenNearby.first?.rule.id, nearbyRule.id)
        XCTAssertEqual(alertsWhenNearby.first?.eventAt, nearbyEventAt)
    }

    func testPlanAllUsesPreciseRadarTimesJustBelowRainCooldown() {
        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 60
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 60

        let firstForecastEventAt = base.addingTimeInterval(2 * 3_600)
        let secondForecastEventAt = firstForecastEventAt.addingTimeInterval(6 * 3_600)
        let firstRadarEventAt = firstForecastEventAt.addingTimeInterval(4 * 60)
        let secondRadarEventAt = firstRadarEventAt.addingTimeInterval(6 * 3_600 - 60)
        let calendar = Calendar.current
        func isolateRule(_ rule: inout Rule, at time: Date) {
            let hour = calendar.component(.hour, from: time)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
        }
        isolateRule(&firstRule, at: firstRadarEventAt)
        isolateRule(&secondRule, at: secondRadarEventAt)

        var hours = makeForecast(through: 8, precipitationOffsets: [2, 8])
        hours[2].radarSamples = [PrecipitationSample(time: firstRadarEventAt, rate: 0.8)]
        hours[8].radarSamples = [PrecipitationSample(time: secondRadarEventAt, rate: 0.8)]
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRule, secondRule])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: base
        )

        XCTAssertEqual(secondForecastEventAt.timeIntervalSince(firstForecastEventAt), 6 * 3_600)
        XCTAssertEqual(secondRadarEventAt.timeIntervalSince(firstRadarEventAt), 6 * 3_600 - 60)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.rule.id, firstRule.id)
        XCTAssertEqual(alerts.first?.eventAt, firstRadarEventAt)
    }

    func testPlanAllKeepsSeparatedRadarEventsWhenForecastRunsAreCloser() {
        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 60
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 60

        let firstForecastEventAt = base.addingTimeInterval(2 * 3_600)
        let secondForecastEventAt = firstForecastEventAt.addingTimeInterval(5 * 3_600)
        let firstRadarEventAt = firstForecastEventAt.addingTimeInterval(4 * 60)
        let secondRadarEventAt = firstRadarEventAt.addingTimeInterval(6 * 3_600)
        let calendar = Calendar.current
        let firstHour = calendar.component(.hour, from: firstForecastEventAt)
        firstRule.activeFromHour = firstHour
        firstRule.activeToHour = (firstHour + 1) % 24
        let secondHour = calendar.component(.hour, from: secondForecastEventAt)
        secondRule.activeFromHour = secondHour
        secondRule.activeToHour = (secondHour + 2) % 24

        var hours = makeForecast(through: 7, precipitationOffsets: [2, 7])
        hours[2].radarSamples = [PrecipitationSample(time: firstRadarEventAt, rate: 0.8)]
        hours[7].radarSamples = [PrecipitationSample(time: secondRadarEventAt, rate: 0.8)]
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRule, secondRule])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: base
        )

        XCTAssertEqual(secondForecastEventAt.timeIntervalSince(firstForecastEventAt), 5 * 3_600)
        XCTAssertEqual(secondRadarEventAt.timeIntervalSince(firstRadarEventAt), 6 * 3_600)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.rule.id)), Set([firstRule.id, secondRule.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([firstRadarEventAt, secondRadarEventAt]))
    }

    func testPlanAllDeduplicatesRadarRainByEventTimeWhenPushTimesAreFarApart() throws {
        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 12 * 60
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 60

        let firstForecastEventAt = base.addingTimeInterval(2 * 3_600)
        let secondForecastEventAt = firstForecastEventAt.addingTimeInterval(5 * 3_600)
        let firstRadarEventAt = firstForecastEventAt.addingTimeInterval(4 * 60)
        let secondRadarEventAt = secondForecastEventAt.addingTimeInterval(4 * 60)
        let calendar = Calendar.current
        func isolateRule(_ rule: inout Rule, at time: Date) {
            let hour = calendar.component(.hour, from: time)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
        }
        isolateRule(&firstRule, at: firstRadarEventAt)
        isolateRule(&secondRule, at: secondRadarEventAt)

        var hours = makeForecast(through: 7, precipitationOffsets: [2, 7])
        hours[2].radarSamples = [PrecipitationSample(time: firstRadarEventAt, rate: 0.8)]
        hours[7].radarSamples = [PrecipitationSample(time: secondRadarEventAt, rate: 0.8)]
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRule, secondRule])
        let now = base.addingTimeInterval(-24 * 3_600)
        let firstPlannedAlert = try XCTUnwrap(Planner.plan(
            rule: firstRule, forecast: hours, placeName: place.name,
            placeID: place.id, latitude: place.lat, longitude: place.lon, now: now
        ).alerts.first)
        let secondPlannedAlert = try XCTUnwrap(Planner.plan(
            rule: secondRule, forecast: hours, placeName: place.name,
            placeID: place.id, latitude: place.lat, longitude: place.lon, now: now
        ).alerts.first)

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: now
        )

        XCTAssertEqual(secondRadarEventAt.timeIntervalSince(firstRadarEventAt), 5 * 3_600)
        XCTAssertGreaterThanOrEqual(
            abs(secondPlannedAlert.fireAt.timeIntervalSince(firstPlannedAlert.fireAt)),
            6 * 3_600
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.rule.id, firstRule.id)
        XCTAssertEqual(alerts.first?.eventAt, firstRadarEventAt)
    }

    func testPlanAllKeepsRainAlertsAtExactSixHourRadarBoundary() {
        var firstRule = Rule(type: .regn)
        firstRule.threshold = 0.5
        firstRule.leadMinutes = 60
        var secondRule = Rule(type: .regn)
        secondRule.threshold = 0.5
        secondRule.leadMinutes = 60

        let firstForecastEventAt = base.addingTimeInterval(2 * 3_600)
        let secondForecastEventAt = firstForecastEventAt.addingTimeInterval(6 * 3_600)
        let firstRadarEventAt = firstForecastEventAt.addingTimeInterval(4 * 60)
        let secondRadarEventAt = firstRadarEventAt.addingTimeInterval(6 * 3_600)
        let calendar = Calendar.current
        func isolateRule(_ rule: inout Rule, at time: Date) {
            let hour = calendar.component(.hour, from: time)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
        }
        isolateRule(&firstRule, at: firstRadarEventAt)
        isolateRule(&secondRule, at: secondRadarEventAt)

        var hours = makeForecast(through: 8, precipitationOffsets: [2, 8])
        hours[2].radarSamples = [PrecipitationSample(time: firstRadarEventAt, rate: 0.8)]
        hours[8].radarSamples = [PrecipitationSample(time: secondRadarEventAt, rate: 0.8)]
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [firstRule, secondRule])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: base
        )

        XCTAssertEqual(secondForecastEventAt.timeIntervalSince(firstForecastEventAt), 6 * 3_600)
        XCTAssertEqual(secondRadarEventAt.timeIntervalSince(firstRadarEventAt), 6 * 3_600)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.rule.id)), Set([firstRule.id, secondRule.id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([firstRadarEventAt, secondRadarEventAt]))
    }

    func testPlanAllMeasuresRainCooldownFromLastKeptAlert() {
        let eventOffsets = [2, 6, 10]
        let eventTimes = eventOffsets.map { base.addingTimeInterval(TimeInterval($0 * 3_600)) }
        let calendar = Calendar.current
        let rules = eventTimes.map { time in
            var rule = Rule(type: .regn)
            rule.threshold = 0.5
            rule.leadMinutes = 60
            let hour = calendar.component(.hour, from: time)
            rule.activeFromHour = hour
            rule.activeToHour = (hour + 1) % 24
            return rule
        }
        let hours = makeForecast(through: 10, precipitationOffsets: Set(eventOffsets))
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: rules)

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: base
        )

        XCTAssertEqual(eventTimes[1].timeIntervalSince(eventTimes[0]), 4 * 3_600)
        XCTAssertEqual(eventTimes[2].timeIntervalSince(eventTimes[1]), 4 * 3_600)
        XCTAssertEqual(eventTimes[2].timeIntervalSince(eventTimes[0]), 8 * 3_600)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.rule.id)), Set([rules[0].id, rules[2].id]))
        XCTAssertEqual(Set(alerts.map(\.eventAt)), Set([eventTimes[0], eventTimes[2]]))
    }

    func testPlanAllKeepsRainEventsWithinSixHoursFromSameRule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 20)))
        var rule = Rule(type: .regn)
        rule.threshold = 0.5
        rule.activeFromHour = 18
        rule.activeToHour = 6
        rule.previousDayNotificationHour = 21
        rule.notificationDayOffset = 0

        let hours = makeForecast(through: 9, startingAt: now, precipitationOffsets: [3, 8])
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5, rules: [rule])

        let alerts = Planner.planAll(
            places: [place], forecasts: [place.id: hours], now: now, calendar: calendar
        )

        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(alerts.map(\.rule.id), [rule.id, rule.id])
        XCTAssertEqual(alerts.map(\.eventAt), [hours[3].time, hours[8].time])
        XCTAssertLessThan(alerts[1].eventAt.timeIntervalSince(alerts[0].eventAt), 6 * 3_600)
    }

    func testNotificationLimitKeepsNearestUniqueFutureAlerts() {
        let rule = Rule(type: .regn)
        let placeID = UUID()
        let alerts = (0..<70).map { index in
            let fireAt = base.addingTimeInterval(TimeInterval((70 - index) * 60))
            return PlannedAlert(
                rule: rule,
                placeID: placeID,
                placeName: "Namsos",
                eventAt: fireAt.addingTimeInterval(3_600),
                fireAt: fireAt,
                index: index + 1,
                total: 70,
                quiet: false,
                possible: false,
                eventDetail: nil
            )
        }

        let scheduled = NotificationScheduler.alertsToSchedule(alerts + [alerts[0]], now: base)

        XCTAssertEqual(scheduled.count, 64)
        XCTAssertEqual(scheduled.first?.fireAt, base.addingTimeInterval(60))
        XCTAssertEqual(scheduled.last?.fireAt, base.addingTimeInterval(64 * 60))
        XCTAssertEqual(Set(scheduled.map(\.id)).count, scheduled.count)
    }

    func testNotificationPresentationPolicyPreservesQuietAndAudibleAlertBehavior() {
        let quietOptions = NotificationPresentationPolicy.options(hasSound: false)
        let audibleOptions = NotificationPresentationPolicy.options(hasSound: true)

        XCTAssertTrue(quietOptions.contains(.banner))
        XCTAssertTrue(quietOptions.contains(.list))
        XCTAssertFalse(quietOptions.contains(.sound))
        XCTAssertEqual(audibleOptions, [.banner, .list, .sound])
        XCTAssertNil(NotificationPresentationPolicy.sound(isQuiet: true))
        XCTAssertNotNil(NotificationPresentationPolicy.sound(isQuiet: false))
        XCTAssertEqual(NotificationPresentationPolicy.interruptionLevel(isQuiet: true), .passive)
        XCTAssertEqual(NotificationPresentationPolicy.interruptionLevel(isQuiet: false), .active)
    }

    @MainActor
    func testNotificationReplacementsDoNotInterleaveAtSuspensionPoints() async {
        let queue = NotificationSchedulingQueue()
        var pending: [String] = []
        var resumeFirst: CheckedContinuation<Void, Never>?
        let firstStarted = expectation(description: "First replacement suspended during add")
        let result = NotificationScheduleResult(requestedCount: 1, scheduledCount: 1,
                                              failedCount: 0, firstScheduledAt: base)
        let first = queue.enqueue {
            pending.removeAll()
            await withCheckedContinuation { continuation in
                resumeFirst = continuation
                firstStarted.fulfill()
            }
            pending.append("old")
            return result
        }
        await fulfillment(of: [firstStarted], timeout: 5)
        let second = queue.enqueue {
            pending.removeAll()
            pending.append("new")
            return result
        }
        // A caller disappearing must not interrupt an in-progress replacement.
        first.cancel()
        resumeFirst?.resume()
        _ = await second.value
        XCTAssertEqual(pending, ["new"])
        let third = queue.enqueue {
            pending.removeAll()
            return result
        }
        _ = await third.value
        XCTAssertTrue(pending.isEmpty)
    }

    @MainActor
    func testCancelledQueuedNotificationReplacementIsSkipped() async {
        let queue = NotificationSchedulingQueue()
        var operations: [String] = []
        var resumeFirst: CheckedContinuation<Void, Never>?
        let firstStarted = expectation(description: "First replacement is active")
        let result = NotificationScheduleResult(requestedCount: 1, scheduledCount: 1,
                                              failedCount: 0, firstScheduledAt: base)

        let first = queue.enqueue {
            operations.append("first")
            await withCheckedContinuation { continuation in
                resumeFirst = continuation
                firstStarted.fulfill()
            }
            return result
        }
        await fulfillment(of: [firstStarted], timeout: 5)

        let cancelled = queue.enqueue {
            operations.append("cancelled")
            return result
        }
        let newest = queue.enqueue {
            operations.append("newest")
            return result
        }
        cancelled.cancel()
        resumeFirst?.resume()

        _ = await first.value
        _ = await cancelled.value
        _ = await newest.value
        XCTAssertEqual(operations, ["first", "newest"])
    }

    func testSharedNotificationSlotKeepsNearestEventRegardlessOfInputOrder() {
        let rule = Rule(type: .regn)
        let placeID = UUID()
        let fireAt = base.addingTimeInterval(3600)
        func alert(eventOffset: TimeInterval) -> PlannedAlert {
            PlannedAlert(rule: rule, placeID: placeID, placeName: "Namsos",
                         eventAt: base.addingTimeInterval(eventOffset), fireAt: fireAt,
                         index: 1, total: 1, quiet: false, possible: false, eventDetail: nil)
        }
        let early = alert(eventOffset: 7200)
        let late = alert(eventOffset: 14400)
        XCTAssertEqual(early.id, late.id)
        for input in [[late, early], [early, late]] {
            let scheduled = NotificationScheduler.alertsToSchedule(input, now: base, limit: 1)
            XCTAssertEqual(scheduled, [early])
        }
        XCTAssertTrue(NotificationScheduler.alertsToSchedule([early], now: fireAt).isEmpty)
        XCTAssertTrue(NotificationScheduler.alertsToSchedule([early], now: base, limit: 0).isEmpty)
    }

    func testNotificationIDsSeparateSameRuleAndTimeAcrossPlaces() {
        let rule = Rule(type: .regn)
        let fireAt = base.addingTimeInterval(3_600)
        let first = PlannedAlert(rule: rule, placeID: UUID(), placeName: "Klinga",
                                 eventAt: fireAt, fireAt: fireAt, index: 1, total: 1,
                                 quiet: false, possible: false, eventDetail: nil)
        let second = PlannedAlert(rule: rule, placeID: UUID(), placeName: "Namsos",
                                  eventAt: fireAt, fireAt: fireAt, index: 1, total: 1,
                                  quiet: false, possible: false, eventDetail: nil)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(NotificationScheduler.alertsToSchedule([first, second], now: base).map(\.id)).count, 2)
    }

    func testIdenticallyNamedRulesKeepDistinctNotificationIDs() {
        var firstRule = Rule(type: .regn)
        firstRule.customName = "Paraply"
        var secondRule = firstRule
        secondRule.id = UUID()
        let fireAt = base.addingTimeInterval(3_600)
        let first = PlannedAlert(rule: firstRule, placeID: UUID(), placeName: "Klinga", eventAt: fireAt, fireAt: fireAt, index: 1, total: 1, quiet: false, possible: false, eventDetail: nil)
        let second = PlannedAlert(rule: secondRule, placeID: first.placeID, placeName: "Klinga", eventAt: fireAt, fireAt: fireAt, index: 1, total: 1, quiet: false, possible: false, eventDetail: nil)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testLanguageChangeDoesNotChangeRuleOrNotificationIdentity() {
        let rule = Rule(type: .regn)
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let fireAt = base.addingTimeInterval(3_600)
        let alert = PlannedAlert(rule: rule, placeID: place.id, placeName: place.displayName,
                                 eventAt: fireAt, fireAt: fireAt, index: 1, total: 1,
                                 quiet: false, possible: false, eventDetail: nil)
        XCTAssertEqual(NotificationScheduler.alertsToSchedule([alert], now: base).first?.id, alert.id)
        XCTAssertEqual(rule.id, alert.rule.id)
        XCTAssertNotEqual(
            NotificationCopy.title(for: rule, placeName: "på Klinga", languageStyle: .bokmal),
            NotificationCopy.title(for: rule, placeName: "på Klinga", languageStyle: .english)
        )
    }

    func testNotificationQueueSortsEqualTimesByWeatherSeverityRegardlessOfInputOrder() {
        let fireAt = base.addingTimeInterval(3_600)
        let placeID = UUID()
        func alert(_ type: AlertType, id: String) -> PlannedAlert {
            var rule = Rule(type: type)
            rule.id = UUID(uuidString: id)!
            return PlannedAlert(rule: rule, placeID: placeID, placeName: "Klinga",
                                eventAt: fireAt, fireAt: fireAt, index: 1, total: 1,
                                quiet: false, possible: false, eventDetail: nil)
        }
        let frost = alert(.frost, id: "00000000-0000-0000-0000-000000000001")
        let snow = alert(.sno, id: "00000000-0000-0000-0000-000000000002")
        let wind = alert(.vind, id: "00000000-0000-0000-0000-000000000003")
        let rain = alert(.regn, id: "00000000-0000-0000-0000-000000000004")
        let expectedIDs = [frost.id, snow.id, wind.id, rain.id]
        let inputOrders = [
            [rain, wind, snow, frost],
            [frost, snow, wind, rain],
            [snow, rain, frost, wind],
            [wind, frost, rain, snow]
        ]

        for input in inputOrders {
            let scheduled = NotificationScheduler.alertsToSchedule(input, now: base)
            XCTAssertEqual(scheduled.map(\.id), expectedIDs)
            XCTAssertEqual(scheduled.map(\.rule.type), [.frost, .sno, .vind, .regn])
        }
    }

    func testNotificationQueuePrioritizesNearestEventBeforeSeverityRegardlessOfInputOrder() {
        let fireAt = base.addingTimeInterval(3_600)
        let placeID = UUID()
        func alert(_ type: AlertType, eventOffset: TimeInterval) -> PlannedAlert {
            PlannedAlert(rule: Rule(type: type), placeID: placeID, placeName: "Klinga",
                         eventAt: base.addingTimeInterval(eventOffset), fireAt: fireAt,
                         index: 1, total: 1, quiet: false, possible: false, eventDetail: nil)
        }
        let rain = alert(.regn, eventOffset: 7_200)
        let wind = alert(.vind, eventOffset: 10_800)
        let frost = alert(.frost, eventOffset: 14_400)
        let inputOrders = [
            [frost, wind, rain],
            [rain, frost, wind],
            [wind, rain, frost]
        ]

        for input in inputOrders {
            let scheduled = NotificationScheduler.alertsToSchedule(input, now: base)
            XCTAssertEqual(scheduled.map(\.id), [rain.id, wind.id, frost.id])
            XCTAssertEqual(
                NotificationScheduler.alertsToSchedule(input, now: base, limit: 1).first?.id,
                rain.id
            )
        }
    }

    func testLanguageCatalogRejectsEmptyTranslation() {
        XCTAssertEqual(LanguageCatalog.value("missing.key", language: "en", fallback: "Weather"), "Weather")
        XCTAssertFalse(LanguageCatalog.value("missing.key", language: "en", fallback: "Weather").isEmpty)
    }

    func testInntronderskKeepsTonightDistinctFromTomorrowAtMidnight() {
        XCTAssertEqual(WeatherLanguage.text("Regn i natt kl. 02", style: .inntrondersk), "Regn i natt kl. 02")
        XCTAssertEqual(WeatherLanguage.text("Regn i morgen kl. 06", style: .inntrondersk), "Regn i mårrå kl. 06")
    }

    func testLiveActivityRejectsFutureDatedForecastAsNotFresh() {
        XCTAssertTrue(LiveWeatherActivityPolicy.forecastIsFresh(fetchedAt: base, now: base.addingTimeInterval(60)))
        XCTAssertFalse(LiveWeatherActivityPolicy.forecastIsFresh(fetchedAt: base.addingTimeInterval(60), now: base))
        XCTAssertFalse(LiveWeatherActivityPolicy.forecastIsFresh(fetchedAt: base, now: base.addingTimeInterval(6 * 3_600 + 1)))
    }

    func testLiveActivityRejectsUnknownOrExpiredForecastCache() {
        XCTAssertFalse(LiveWeatherActivityPolicy.forecastIsUsable(fetchedAt: nil, now: base))
        XCTAssertFalse(LiveWeatherActivityPolicy.forecastIsUsable(
            fetchedAt: base.addingTimeInterval(-6 * 3_600 - 1), now: base
        ))
        XCTAssertTrue(LiveWeatherActivityPolicy.forecastIsUsable(
            fetchedAt: base.addingTimeInterval(-6 * 3_600), now: base
        ))
    }

    func testLiveActivityStopsUsingCachedForecastWhenRuleIsDisabled() {
        var rule = Rule(type: .regn)
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])

        XCTAssertTrue(LiveWeatherActivityPolicy.canUseRule(
            rule, for: place, nearbyPlaceIDs: []
        ))

        rule.enabled = false
        XCTAssertFalse(LiveWeatherActivityPolicy.canUseRule(
            rule, for: place, nearbyPlaceIDs: [place.id]
        ))
    }

    func testNearbyOnlyLiveActivityStopsWhenNearnessIsRemoved() {
        var rule = Rule(type: .regn)
        rule.onlyWhenNearby = true
        let place = Place(name: "Hytta", lat: 64.5, lon: 11.5, rules: [rule])

        XCTAssertTrue(LiveWeatherActivityPolicy.canUseRule(
            rule, for: place, nearbyPlaceIDs: [place.id]
        ))
        // A new location update can empty the nearby set. A cached forecast
        // must not keep a place-bound activity alive after that transition.
        XCTAssertFalse(LiveWeatherActivityPolicy.canUseRule(
            rule, for: place, nearbyPlaceIDs: []
        ))
    }

    func testLiveActivityPrefersNearestQualifiedEventAcrossPlaces() {
        XCTAssertTrue(LiveWeatherActivityPolicy.prefers(
            firstEventAt: base.addingTimeInterval(15 * 60), firstType: .regn,
            over: base.addingTimeInterval(30 * 60), secondType: .sno
        ))
        XCTAssertFalse(LiveWeatherActivityPolicy.prefers(
            firstEventAt: base.addingTimeInterval(30 * 60), firstType: .regn,
            over: base.addingTimeInterval(15 * 60), secondType: .sno
        ))
        XCTAssertTrue(LiveWeatherActivityPolicy.prefers(
            firstEventAt: base.addingTimeInterval(30 * 60), firstType: .sno,
            over: base.addingTimeInterval(30 * 60), secondType: .regn
        ))
    }

    func testLiveActivityReadsOnlyCandidatePlaceForecastCache() {
        let klinga = Place(name: "Klinga", lat: 64, lon: 11)
        let hornburu = Place(name: "Hornburu", lat: 64.2, lon: 11.2)
        let klingaForecast = [ForecastHour(time: base, temp: 3, precip: 1, wind: 1, cloud: 90, dew: 1)]
        let hornburuForecast = [ForecastHour(time: base, temp: -2, precip: 1, wind: 1, cloud: 90, dew: -2)]
        let caches = [klinga.id: klingaForecast, hornburu.id: hornburuForecast]

        XCTAssertEqual(LiveWeatherActivityPolicy.forecast(for: klinga, in: caches), klingaForecast)
        XCTAssertEqual(LiveWeatherActivityPolicy.forecast(for: hornburu, in: caches), hornburuForecast)
        XCTAssertNil(LiveWeatherActivityPolicy.forecast(
            for: Place(name: "Selbu", lat: 63.2, lon: 11.0), in: caches
        ))
    }

    @MainActor
    func testWidgetFreshSnapshotAppliesLocalTemperatureOffsetLikeFallback() throws {
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.temperatureOffset = 2
        let raw = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 20, dew: 5)
        let snapshot = try XCTUnwrap(Store.widgetSnapshot(place: place, forecast: [raw], updatedAt: base, cached: nil))
        XCTAssertEqual(snapshot.forecast.first?.temp, 12)
        XCTAssertEqual(snapshot.forecast.first?.dew, 5)
        let fallback = try XCTUnwrap(Store.widgetSnapshot(place: place, forecast: [], updatedAt: nil, cached: snapshot))
        XCTAssertEqual(fallback.forecast.first?.temp, 12)
    }

    @MainActor
    func testWidgetFallbackAppliesOnlyChangedLocalTemperatureOffset() throws {
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.temperatureOffset = 1
        let raw = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 20, dew: 5)
        let cached = try XCTUnwrap(Store.widgetSnapshot(
            place: place, forecast: [raw], updatedAt: base, cached: nil
        ))
        XCTAssertEqual(cached.forecast.first?.temp, 11)

        place.temperatureOffset = 3
        let fallback = try XCTUnwrap(Store.widgetSnapshot(
            place: place, forecast: [], updatedAt: nil, cached: cached
        ))
        XCTAssertEqual(fallback.forecast.first?.temp, 13)
        XCTAssertEqual(cached.forecast.first?.temp, 11)
        XCTAssertEqual(raw.temp, 10)
    }

    @MainActor
    func testWatchTransferKeepsUpdatedOfflineLocalTemperatureOffset() throws {
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.temperatureOffset = 1
        let raw = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 20, dew: 5)
        let cached = try XCTUnwrap(Store.widgetSnapshot(
            place: place, forecast: [raw], updatedAt: base, cached: nil
        ))
        place.temperatureOffset = 3
        let offline = try XCTUnwrap(Store.widgetSnapshot(
            place: place, forecast: [], updatedAt: nil, cached: cached
        ))

        let received = try JSONDecoder().decode(
            WatchWeatherTransfer.self,
            from: JSONEncoder().encode(WatchWeatherTransfer(snapshot: offline, sentAt: base))
        )
        XCTAssertEqual(received.snapshot?.forecast.first?.temp, 13)
        XCTAssertEqual(received.snapshot?.place.localTemperatureOffset, 3)
    }

    func testSeparatorChangeChangesReplanConfigurationSignature() {
        XCTAssertNotEqual(Store.configurationSignature(languageStyle: .bokmal, separator: .space), Store.configurationSignature(languageStyle: .bokmal, separator: .dash))
        XCTAssertNotEqual(Store.configurationSignature(languageStyle: .bokmal, separator: .dash), Store.configurationSignature(languageStyle: .english, separator: .dash))
    }

    func testCalendarChangesChangeReplanSignature() {
        var osloCalendar = Calendar(identifier: .gregorian)
        osloCalendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        osloCalendar.locale = Locale(identifier: "nb_NO")

        var londonCalendar = osloCalendar
        londonCalendar.timeZone = TimeZone(identifier: "Europe/London")!

        var sundayCalendar = osloCalendar
        sundayCalendar.firstWeekday = 1

        XCTAssertNotEqual(Store.calendarSignature(osloCalendar), Store.calendarSignature(londonCalendar))
        XCTAssertNotEqual(Store.calendarSignature(osloCalendar), Store.calendarSignature(sundayCalendar))
    }

    func testNotificationLogRetainsOnlyRecentEntries() {
        let old = LogEntry(time: base.addingTimeInterval(-73 * 3_600), text: "gammel")
        let recent = LogEntry(time: base.addingTimeInterval(-1 * 3_600), text: "ny")
        let future = LogEntry(time: base.addingTimeInterval(60), text: "framtidig")
        let olderRecent = LogEntry(time: base.addingTimeInterval(-2 * 3_600), text: "eldre ny")
        XCTAssertEqual(
            Store.retainedLog([olderRecent, recent, old, future], now: base).map(\.text),
            ["ny", "eldre ny"]
        )
        XCTAssertEqual(
            Store.retainedLog([olderRecent, recent], now: base, maxCount: 1).map(\.text),
            ["ny"]
        )

        let cutoff = base.addingTimeInterval(-72 * 3_600)
        let atCutoff = LogEntry(time: cutoff, text: "akkurat 72 timer")
        let beforeCutoff = LogEntry(time: cutoff.addingTimeInterval(-0.001), text: "eldre enn 72 timer")
        let atNow = LogEntry(time: base, text: "akkurat nå")
        let justFuture = LogEntry(time: base.addingTimeInterval(0.001), text: "svakt i framtiden")
        XCTAssertEqual(
            Store.retainedLog([atCutoff, beforeCutoff, justFuture, atNow], now: base).map(\.text),
            ["akkurat nå", "akkurat 72 timer"]
        )
    }

    @MainActor
    func testStoreRestorePrunesNotificationLogAndPersistsWithoutReplanning() throws {
        let persistenceKey = "varsel.test.restore-prunes-notification-log.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let recentEntries = (0..<51).reversed().map { index in
            LogEntry(time: base.addingTimeInterval(-Double(index * 60)), text: "ny-\(index)")
        }
        let staleEntry = LogEntry(time: base.addingTimeInterval(-73 * 3_600), text: "utløpt")
        let futureEntry = LogEntry(time: base.addingTimeInterval(60), text: "framtidig")
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [place], selectedID: place.id, log: recentEntries + [staleEntry, futureEntry]
        )), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey, now: base)

        XCTAssertEqual(restored.log.count, 50)
        XCTAssertEqual(restored.log.first?.text, "ny-0")
        XCTAssertEqual(restored.log.last?.text, "ny-49")
        XCTAssertFalse(restored.log.contains { $0.text == "utløpt" })
        XCTAssertFalse(restored.log.contains { $0.text == "framtidig" })
        let persistedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: persistedData)
        XCTAssertEqual(persisted.log.count, 50)
        XCTAssertEqual(persisted.log.first?.text, "ny-0")
        XCTAssertEqual(persisted.log.last?.text, "ny-49")
        XCTAssertFalse(persisted.log.contains { $0.text == "utløpt" })
        XCTAssertFalse(persisted.log.contains { $0.text == "framtidig" })
    }

    @MainActor
    func testStoreRestoreDeduplicatesNotificationLogIDsAndPersistsRepair() throws {
        let persistenceKey = "varsel.test.restore-deduplicates-notification-log.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let duplicateID = UUID()
        let state = PersistedStoreState(
            places: [place], selectedID: place.id,
            log: [
                LogEntry(id: duplicateID, time: base, text: "første"),
                LogEntry(id: duplicateID, time: base.addingTimeInterval(-60), text: "duplikat")
            ]
        )
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey, now: base)

        XCTAssertEqual(restored.log.map(\.text), ["første"])
        XCTAssertEqual(Set(restored.log.map(\.id)).count, restored.log.count)
        let persistedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: persistedData)
        XCTAssertEqual(persisted.log.map(\.text), ["første"])
        XCTAssertEqual(Set(persisted.log.map(\.id)).count, persisted.log.count)
    }

    @MainActor
    func testStoreRestorePersistsLossyPlaceAndLogRows() throws {
        let persistenceKey = "varsel.test.restore-lossy-place-and-log-rows.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let validPlaceID = UUID()
        let invalidPlaceID = UUID()
        let validLogID = UUID()
        let logTimestamp = base.timeIntervalSinceReferenceDate
        let data = Data("""
        {"places":[
          {"id":"\(validPlaceID)","name":"Klinga","lat":64.4,"lon":11.4},
          {"id":"\(invalidPlaceID)","name":"Ugyldig","lat":91,"lon":0}
        ],"selectedID":"\(validPlaceID)","log":[
          {"id":"\(validLogID)","time":\(logTimestamp),"text":"beholdt"},
          {"time":\(logTimestamp),"text":42}
        ]}
        """.utf8)
        UserDefaults.standard.set(data, forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey, now: base)

        XCTAssertEqual(restored.places.map(\.id), [validPlaceID])
        XCTAssertEqual(restored.log.map(\.text), ["beholdt"])
        let repairedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repaired = try JSONDecoder().decode(PersistedStoreState.self, from: repairedData)
        XCTAssertEqual(repaired.places.map(\.id), [validPlaceID])
        XCTAssertEqual(repaired.log.map(\.id), [validLogID])
    }

    @MainActor
    func testStoreRestoreRepairsWrongTypeLogContainerImmediately() throws {
        let persistenceKey = "varsel.test.restore-wrong-type-log-container.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)
        let placeID = UUID()
        let malformedData = Data("""
        {"places":[{"id":"\(placeID)","name":"Klinga","lat":64.4,"lon":11.4}],"selectedID":"\(placeID)","log":"not-an-array"}
        """.utf8)
        UserDefaults.standard.set(malformedData, forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey, now: base)

        XCTAssertEqual(restored.places.map(\.id), [placeID])
        XCTAssertEqual(restored.log, [])
        let repairedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        XCTAssertNotEqual(repairedData, malformedData)
        let repaired = try JSONDecoder().decode(PersistedStoreState.self, from: repairedData)
        XCTAssertEqual(repaired.places.map(\.id), [placeID])
        XCTAssertEqual(repaired.log, [])
    }

    @MainActor
    func testStoreRestoreRepairsAndPersistsDuplicatePlaceIDs() throws {
        let persistenceKey = "varsel.test.restore-deduplicates-place-ids.\(UUID().uuidString)"
        let launchVersionKey = "varsel.launchPlacesVersion"
        let previousLaunchVersion = UserDefaults.standard.object(forKey: launchVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousLaunchVersion {
                UserDefaults.standard.set(previousLaunchVersion, forKey: launchVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: launchVersionKey)
            }
        }
        UserDefaults.standard.set(9, forKey: launchVersionKey)

        let first = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        var duplicate = first
        duplicate.name = "Duplikat"
        let other = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let cachedHour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4)
        let state = PersistedStoreState(
            places: [first, duplicate, other], selectedID: first.id, log: [],
            forecasts: [first.id: [cachedHour]], forecastUpdatedAt: [first.id: base], lastUpdate: base
        )
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: persistenceKey)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey, now: base)

        XCTAssertEqual(restored.places.map(\.name), ["Klinga", "Namsos"])
        XCTAssertEqual(restored.places.map(\.id), [first.id, other.id])
        XCTAssertEqual(restored.forecasts[first.id], [cachedHour])
        let persistedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: persistedData)
        XCTAssertEqual(persisted.places.map(\.id), [first.id, other.id])
        XCTAssertEqual(persisted.forecasts[first.id], [cachedHour])
        XCTAssertEqual(persisted.forecastUpdatedAt[first.id], base)

        let relaunched = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey, now: base)
        XCTAssertEqual(relaunched.places.map(\.id), [first.id, other.id])
        XCTAssertEqual(relaunched.forecasts[first.id], [cachedHour])
    }

    @MainActor
    func testSelectingPlaceFromHomeUsesSameSelectionForRules() {
        let store = Store.shared
        let original = store.selectedID
        defer { store.selectedID = original }
        let target = store.places.dropFirst().first ?? store.places[0]
        store.select(target)
        XCTAssertEqual(store.selected?.id, target.id)
        XCTAssertFalse(store.selectionIsCurrentLocation)
    }

    func testSharedWidgetPlacesAreCappedAtThreeUniqueIDs() {
        let first = Place(name: "Klinga", lat: 64, lon: 11)
        let second = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let third = Place(name: "Selbu", lat: 63.2, lon: 11)
        let fourth = Place(name: "Bangdalen", lat: 64.2, lon: 12)
        SharedWidgetData.clear()
        defer { SharedWidgetData.clear() }
        SharedWidgetData.saveSharedPlaces([first, first, second, third, fourth])
        let summaries = SharedWidgetData.loadSharedPlaces()
        XCTAssertEqual(summaries.count, 3)
        XCTAssertEqual(Set(summaries.map(\.id)).count, 3)
        XCTAssertEqual(summaries.map(\.id), [first.id, second.id, third.id])
    }

    func testSharedWidgetStorageDoesNotRunWhenAppGroupIsUnavailable() {
        var attemptedWrite = false
        var reportedFailure = false

        let result = SharedWidgetData.withAppGroupDefaults(
            suiteName: SharedWidgetData.appGroup,
            defaultsProvider: { _ in nil },
            onUnavailable: { reportedFailure = true },
            operation: { _ in
                attemptedWrite = true
                return true
            }
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedWrite)
        XCTAssertTrue(reportedFailure)
    }

    func testWeatherTextSeparatorDoesNotPersistWhenAppGroupIsUnavailable() {
        let key = "varsel.test.separator.standard-sentinel"
        let standard = UserDefaults.standard
        standard.set("sentinel", forKey: key)
        defer { standard.removeObject(forKey: key) }

        var attemptedWrite = false
        var reportedFailure = false
        let result = WeatherTextSeparator.withAppGroupDefaults(
            defaultsProvider: { _ in nil },
            onUnavailable: { reportedFailure = true },
            operation: { defaults in
                attemptedWrite = true
                defaults.set(WeatherTextSeparator.bullet.rawValue, forKey: WeatherTextSeparator.key)
                standard.set(WeatherTextSeparator.bullet.rawValue, forKey: key)
                return true
            }
        )

        XCTAssertNil(result)
        XCTAssertFalse(attemptedWrite)
        XCTAssertTrue(reportedFailure)
        XCTAssertEqual(standard.string(forKey: key), "sentinel")
    }

    func testSharedWidgetPlacesOnlyWriteWhenOrderOrContentChanges() {
        let first = Place(name: "Klinga", lat: 64, lon: 11)
        let second = Place(name: "Hornburu", lat: 64.1, lon: 11.1)
        SharedWidgetData.clear()
        defer { SharedWidgetData.clear() }

        XCTAssertTrue(SharedWidgetData.saveSharedPlaces([first, second]))
        XCTAssertFalse(SharedWidgetData.saveSharedPlaces([first, second]))
        XCTAssertTrue(SharedWidgetData.saveSharedPlaces([second, first]))
        XCTAssertEqual(SharedWidgetData.loadSharedPlaces().map(\.id), [second.id, first.id])
    }

    func testSharedWidgetClearRemovesSnapshotAndCarPlayPlacesTogether() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 20, dew: 5)
        SharedWidgetData.clear()
        defer { SharedWidgetData.clear() }

        XCTAssertTrue(SharedWidgetData.save(place: place, forecast: [hour], updatedAt: base))
        XCTAssertTrue(SharedWidgetData.saveSharedPlaces([place]))
        XCTAssertNotNil(SharedWidgetData.load())
        XCTAssertEqual(SharedWidgetData.loadSharedPlaces().map(\.id), [place.id])

        SharedWidgetData.clear()
        XCTAssertNil(SharedWidgetData.load())
        XCTAssertTrue(SharedWidgetData.loadSharedPlaces().isEmpty)
    }

    @MainActor
    func testNotificationPlanLogReportsActualSchedulingResult() {
        XCTAssertEqual(
            Store.notificationPlanLogText(.init(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil)),
            "Varslingsplan oppdatert – ingen varsler planlagt."
        )
        XCTAssertEqual(
            Store.notificationPlanLogText(.init(requestedCount: 3, scheduledCount: 0, failedCount: 3, firstScheduledAt: nil)),
            "Kunne ikke aktivere 3 planlagte varsler."
        )
        XCTAssertEqual(
            Store.notificationPlanLogText(.init(requestedCount: 3, scheduledCount: 2, failedCount: 1, firstScheduledAt: base)),
            "Varslingsplan delvis oppdatert – 2 av 3 varsler aktivert."
        )
        XCTAssertTrue(
            Store.notificationPlanLogText(.init(requestedCount: 2, scheduledCount: 2, failedCount: 0, firstScheduledAt: base))
                .hasPrefix("Varslingsplan oppdatert – 2 varsler planlagt, første ")
        )
    }

    @MainActor
    func testNotificationPlanLogUsesEnglishForEmptySuccessfulAndFailedResults() {
        XCTAssertEqual(
            Store.notificationPlanLogText(
                .init(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil),
                languageStyle: .english
            ),
            "Notification plan updated – no alerts scheduled."
        )
        XCTAssertEqual(
            Store.notificationPlanLogText(
                .init(requestedCount: 3, scheduledCount: 0, failedCount: 3, firstScheduledAt: nil),
                languageStyle: .english
            ),
            "Could not activate 3 scheduled alerts."
        )
        XCTAssertEqual(
            Store.notificationPlanLogText(
                .init(requestedCount: 3, scheduledCount: 2, failedCount: 1, firstScheduledAt: base),
                languageStyle: .english
            ),
            "Notification plan partially updated – 2 of 3 alerts activated."
        )
        XCTAssertTrue(
            Store.notificationPlanLogText(
                .init(requestedCount: 2, scheduledCount: 2, failedCount: 0, firstScheduledAt: base),
                languageStyle: .english
            ).hasPrefix("Notification plan updated – 2 alerts scheduled, first ")
        )
    }

    @MainActor
    func testNotificationPlanLogUsesInntronderskForEverySchedulingOutcome() {
        XCTAssertEqual(
            Store.notificationPlanLogText(
                .init(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil),
                languageStyle: .inntrondersk
            ),
            "Varslingsplan oppdatert – ingen varsler planlagt."
        )
        XCTAssertEqual(
            Store.notificationPlanLogText(
                .init(requestedCount: 3, scheduledCount: 0, failedCount: 3, firstScheduledAt: nil),
                languageStyle: .inntrondersk
            ),
            "Kunne ikke aktivere 3 planlagte varsler."
        )
        XCTAssertEqual(
            Store.notificationPlanLogText(
                .init(requestedCount: 3, scheduledCount: 2, failedCount: 1, firstScheduledAt: nil),
                languageStyle: .inntrondersk
            ),
            "Varslingsplan delvis oppdatert – 2 av 3 varsler aktivert."
        )

        let result = NotificationScheduleResult(
            requestedCount: 2,
            scheduledCount: 2,
            failedCount: 0,
            firstScheduledAt: Date().addingTimeInterval(2 * 3_600)
        )
        let text = Store.notificationPlanLogText(result, languageStyle: .inntrondersk)
        XCTAssertTrue(text.hasPrefix("Varslingsplan oppdatert – 2 varsler planlagt, første "))
        XCTAssertTrue(text.hasSuffix("om to tima."))
        XCTAssertFalse(text.hasSuffix("om to timer."))
    }

    func testWatchTransferRoundTripsLatestSnapshotAndExplicitClear() throws {
        let place = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let snapshot = WidgetWeatherSnapshot(
            place: place,
            forecast: [ForecastHour(time: base, temp: 5, precip: 1, wind: 2, cloud: 100, dew: 4)],
            updatedAt: base
        )
        let transfer = WatchWeatherTransfer(snapshot: snapshot, sentAt: base.addingTimeInterval(1))
        let clear = WatchWeatherTransfer(snapshot: nil, sentAt: base.addingTimeInterval(2))

        let decodedTransfer = try JSONDecoder().decode(
            WatchWeatherTransfer.self,
            from: JSONEncoder().encode(transfer)
        )
        let decodedClear = try JSONDecoder().decode(
            WatchWeatherTransfer.self,
            from: JSONEncoder().encode(clear)
        )

        XCTAssertEqual(decodedTransfer.snapshot?.place.id, place.id)
        XCTAssertEqual(decodedTransfer.snapshot?.forecast.first?.temp, 5)
        XCTAssertNil(decodedClear.snapshot)
        XCTAssertGreaterThan(decodedClear.sentAt, decodedTransfer.sentAt)
    }

    func testWatchTransferPolicyDecodesExplicitClearAndRetainsSentAt() throws {
        let clear = WatchWeatherTransfer(snapshot: nil, sentAt: base.addingTimeInterval(2))
        let payload = try JSONEncoder().encode(clear)

        let decoded = try XCTUnwrap(
            WatchTransferPolicy.decodeTransferPayload(payload, referenceDate: base)
        )

        XCTAssertNil(decoded.snapshot)
        XCTAssertEqual(decoded.sentAt, clear.sentAt)
    }

    func testWatchTransferPolicyBoundsPayloadBytesWithoutRejectingFullForecast() throws {
        let place = Place(name: "Klinga", lat: 64.5, lon: 11.5)
        let forecast = (0..<240).map { hourIndex in
            let hour = base.addingTimeInterval(Double(hourIndex) * 3_600)
            let radar = (0..<4).map { sampleIndex in
                PrecipitationSample(
                    time: hour.addingTimeInterval(Double(sampleIndex) * 15 * 60),
                    rate: Double(sampleIndex) / 10
                )
            }
            return ForecastHour(
                time: hour, temp: 6, precip: 0.2, wind: 3, cloud: 50, dew: 4,
                radarSamples: radar
            )
        }
        let transfer = WatchWeatherTransfer(
            snapshot: WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: base),
            sentAt: base
        )
        let encoded = try JSONEncoder().encode(transfer)
        XCTAssertLessThan(encoded.count, WatchTransferPolicy.maximumPayloadBytes)
        XCTAssertNotNil(WatchTransferPolicy.decodeTransferPayload(encoded, referenceDate: base))

        var oversized = encoded
        oversized.append(Data(repeating: 0x20, count: WatchTransferPolicy.maximumPayloadBytes + 1 - encoded.count))
        XCTAssertEqual(oversized.count, WatchTransferPolicy.maximumPayloadBytes + 1)
        XCTAssertNil(WatchTransferPolicy.decodeTransferPayload(oversized, referenceDate: base))
    }

    func testNextDayRainCanNotifyAtNineTheEveningBefore() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 20)))
        let tomorrowRain = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 15, hour: 8)))
        var rule = Rule(type: .regn)
        rule.activeFromHour = 7
        rule.activeToHour = 22
        rule.previousDayNotificationHour = 21
        rule.previousDayNotificationMinute = 0

        let result = Planner.plan(
            rule: rule,
            forecast: [ForecastHour(time: tomorrowRain, temp: 6, precip: 1, wind: 2, cloud: 100, dew: 5)],
            placeName: "Oslo",
            now: today
        )

        let expectedFire = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 21)))
        XCTAssertEqual(result.alerts.first?.fireAt, expectedFire)
    }

    func testNightRuleNotifiesAtNineOnTheSameEvening() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 20)))
        let rainTonight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 23)))
        var rule = Rule(type: .regn)
        rule.activeFromHour = 22
        rule.activeToHour = 7
        rule.previousDayNotificationHour = 21

        let result = Planner.plan(
            rule: rule,
            forecast: [ForecastHour(time: rainTonight, temp: 6, precip: 1, wind: 2, cloud: 100, dew: 5)],
            placeName: "Oslo",
            now: now
        )

        let expectedFire = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 21)))
        XCTAssertEqual(result.alerts.first?.fireAt, expectedFire)
    }

    func testFixedEveningRulePlansBothTomorrowAndDayAfterTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 20)))
        let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 15, hour: 8)))
        let tomorrowDry = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 15, hour: 9)))
        let dayAfterTomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 16, hour: 8)))
        var rule = Rule(type: .regn)
        rule.activeFromHour = 7
        rule.activeToHour = 22
        rule.previousDayNotificationHour = 21
        let hours = [
            ForecastHour(time: tomorrow, temp: 6, precip: 1, wind: 2, cloud: 100, dew: 5),
            ForecastHour(time: tomorrowDry, temp: 6, precip: 0, wind: 2, cloud: 100, dew: 5),
            ForecastHour(time: dayAfterTomorrow, temp: 6, precip: 1, wind: 2, cloud: 100, dew: 5),
        ]

        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: now)

        XCTAssertEqual(result.alerts.count, 2)
        XCTAssertEqual(result.alerts[1].eventAt, dayAfterTomorrow)
        XCTAssertEqual(
            result.alerts[1].fireAt,
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 15, hour: 21)))
        )
    }

    func testWeekendSunCanBeCollectedIntoThursdayEveningAlert() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 16, hour: 12)))
        let saturday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 19, hour: 10)))
        let saturdayEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 19, hour: 20)))
        let sunday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 20, hour: 10)))

        var rule = Rule(type: .sol)
        rule.threshold = 25
        rule.durationHours = 1
        rule.activeFromHour = 8
        rule.activeToHour = 20
        rule.days = [5, 6]
        rule.previousDayNotificationHour = 21
        rule.notificationWeekday = 3

        let forecast = [
            ForecastHour(time: saturday, temp: 8, precip: 0, wind: 2, cloud: 10, dew: 4),
            ForecastHour(time: saturdayEvening, temp: 7, precip: 0, wind: 2, cloud: 100, dew: 4),
            ForecastHour(time: sunday, temp: 9, precip: 0, wind: 2, cloud: 10, dew: 4),
        ]
        let result = Planner.plan(rule: rule, forecast: forecast, placeName: "oppi Selbu", now: now)
        let alert = try XCTUnwrap(result.alerts.first)

        XCTAssertEqual(result.alerts.count, 1)
        XCTAssertEqual(calendar.component(.weekday, from: alert.fireAt), 5) // torsdag
        XCTAssertEqual(calendar.component(.hour, from: alert.fireAt), 21)
    }

    func testMorningSummaryCanNotifyAtSevenTheSameDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 6)))
        let rain = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 14, hour: 10)))
        var rule = Rule(type: .regn)
        rule.threshold = 0.3
        rule.activeFromHour = 7
        rule.activeToHour = 23
        rule.previousDayNotificationHour = 7
        rule.notificationDayOffset = 0

        let result = Planner.plan(
            rule: rule,
            forecast: [ForecastHour(time: rain, temp: 8, precip: 1, wind: 2, cloud: 100, dew: 5)],
            placeName: "på Klinga",
            now: now
        )
        let alert = try XCTUnwrap(result.alerts.first)

        XCTAssertEqual(calendar.component(.day, from: alert.fireAt), 14)
        XCTAssertEqual(calendar.component(.hour, from: alert.fireAt), 7)
    }

    func testNearbyOnlyRuleIsPlannedOnlyAtThePlace() {
        var rule = Rule(type: .regn)
        rule.onlyWhenNearby = true
        rule.leadMinutes = 60
        let place = Place(name: "Hytta", lat: 64.5, lon: 11.5, rules: [rule])
        let hours = forecast(values: [
            (5, 0, 2, 80, 2),
            (5, 1, 2, 80, 2),
        ])
        let forecasts = [place.id: hours]

        XCTAssertTrue(Planner.planAll(places: [place], forecasts: forecasts).isEmpty)
        XCTAssertEqual(
            Planner.planAll(places: [place], forecasts: forecasts, nearbyPlaceIDs: [place.id]).count,
            1
        )
    }

    func testNearbyOnlyRulesAreFilteredIndependentlyPerPlace() {
        var nearbyRule = Rule(type: .regn)
        nearbyRule.onlyWhenNearby = true
        nearbyRule.leadMinutes = 60
        let distantRule = nearbyRule

        let nearbyPlace = Place(name: "Nær", lat: 64.5, lon: 11.5, rules: [nearbyRule])
        let distantPlace = Place(name: "Fjern", lat: 65.5, lon: 12.5, rules: [distantRule])
        let hours = forecast(values: [
            (5, 0, 2, 80, 2),
            (5, 1, 2, 80, 2),
        ])

        let alerts = Planner.planAll(
            places: [distantPlace, nearbyPlace],
            forecasts: [distantPlace.id: hours, nearbyPlace.id: hours],
            nearbyPlaceIDs: [nearbyPlace.id]
        )

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.placeID, nearbyPlace.id)
        XCTAssertEqual(alerts.first?.rule.id, nearbyRule.id)
    }

    func testOrdinaryRuleIsPlannedWhileAwayFromPlace() {
        var rule = Rule(type: .sol)
        rule.activeFromHour = 0
        rule.activeToHour = 0
        rule.durationHours = 2
        rule.leadMinutes = 60
        let place = Place(name: "Hytta", lat: 64.5, lon: 11.5, rules: [rule])
        let hours = forecast(values: [
            (5, 0, 2, 5, 2),
            (5, 0, 2, 5, 2),
        ])

        XCTAssertEqual(Planner.planAll(places: [place], forecasts: [place.id: hours]).count, 1)
    }

    func testCustomRuleNameIsReservedForNotificationAftertext() {
        var rule = Rule(type: .sol)
        rule.templateTitle = "Sol i morgen"
        rule.customName = "  Slå gresset  "

        XCTAssertEqual(rule.cleanedCustomName, "Slå gresset")
        XCTAssertEqual(rule.displayName, "Sol i morgen")
        XCTAssertEqual(rule.statusText("Sol i 4 timer nå."), "Sol i 4 timer nå.")
    }

    func testPlacePrepositionUsesSavedChoiceAndSafeLegacyDefaults() {
        XCTAssertEqual(Place(name: "Oslo", lat: 0, lon: 0).nameWithPreposition, "i Oslo")
        XCTAssertEqual(Place(name: "Klinga", lat: 0, lon: 0).nameWithPreposition, "på Klinga")
        XCTAssertEqual(
            Place(name: "Sentrum", lat: 0, lon: 0, preposition: .pa).nameWithPreposition,
            "på Sentrum"
        )
        var cabin = Place(name: "Fjellvegen", lat: 0, lon: 0, preposition: .oppi)
        cabin.customName = "Hytta"
        XCTAssertEqual(cabin.nameWithPreposition, "oppi Hytta")
        XCTAssertEqual(PlacePreposition.allCases.count, 15)
    }

    func testCurrentLocationHeadingAddsLowercasePrefixWithoutChangingPrepositionOrPlaceName() {
        for preposition in PlacePreposition.allCases {
            let place = Place(name: "Klinga", lat: 64.4, lon: 11.4, preposition: preposition)
            let heading = CurrentLocationPlaceHeading(place: place)

            XCTAssertEqual(heading.prefixedPreposition, "her \(preposition.rawValue)")
            XCTAssertEqual(heading.placeName, "Klinga")
            XCTAssertEqual(heading.visibleText, "her \(preposition.rawValue) Klinga")
        }

        let defaultKlinga = CurrentLocationPlaceHeading(place: Place(name: "Klinga", lat: 64.4, lon: 11.4))
        XCTAssertEqual(defaultKlinga.visibleText, "her på Klinga")
    }

    func testLiveLocationBadgeOnlyPulsesWhenReduceMotionIsDisabled() {
        XCTAssertTrue(LiveLocationBadgeMotionPolicy.shouldPulse(reduceMotion: false))
        XCTAssertFalse(LiveLocationBadgeMotionPolicy.shouldPulse(reduceMotion: true))
    }

    func testLocationPresenceAccessibilityCopyFollowsLanguageStyle() {
        XCTAssertEqual(
            LocationPresenceAccessibilityCopy.label(languageStyle: .bokmal),
            "GPS-posisjon, live"
        )
        XCTAssertEqual(
            LocationPresenceAccessibilityCopy.label(languageStyle: .inntrondersk),
            WeatherLanguage.text("GPS-posisjon, live", style: .inntrondersk)
        )
        XCTAssertEqual(
            LocationPresenceAccessibilityCopy.label(languageStyle: .english),
            "Live GPS location"
        )
        XCTAssertEqual(
            LocationPresenceAccessibilityCopy.hint(languageStyle: .bokmal),
            "Dette stedet følger telefonens aktuelle posisjon."
        )
        XCTAssertEqual(
            LocationPresenceAccessibilityCopy.hint(languageStyle: .english),
            "This place follows the phone’s current location."
        )
    }

    func testLocalCalibrationCopyFollowsBokmalAndEnglishSelections() {
        let strings = [
            ("Lokale målinger", "Local measurements"),
            ("Målt lufttemperatur (valgfritt)", "Measured air temperature (optional)"),
            ("Frost i natt", "Frost last night"),
            ("Lagre observasjon", "Save observation"),
            ("Registreringer", "Records"),
            ("Ingen registreringer ennå.", "No records yet."),
            ("Slett", "Delete"),
            ("Vis flere registreringer", "Show more records"),
            ("Observasjonen er lagret.", "The observation was saved.")
        ]

        for (bokmal, english) in strings {
            XCTAssertEqual(LocalCalibrationCopy.text(bokmal, english: english, style: .bokmal), bokmal)
            XCTAssertEqual(LocalCalibrationCopy.text(bokmal, english: english, style: .english), english)
        }
        XCTAssertEqual(LocalCalibrationCopy.surface("Gress og bil/tak", style: .bokmal), "Gress og bil/tak")
        XCTAssertEqual(LocalCalibrationCopy.surface("Gress og bil/tak", style: .english), "grass and car/roof")
        XCTAssertEqual(
            LocalCalibrationCopy.summary(measuredTemperature: nil, frost: true, surface: "Gress", style: .bokmal),
            ["Frost: Gress"]
        )
        XCTAssertEqual(
            LocalCalibrationCopy.summary(measuredTemperature: nil, frost: false, surface: "", style: .bokmal),
            ["Ingen frost observert"]
        )
        XCTAssertTrue(LocalCalibrationCopy.summary(measuredTemperature: nil, frost: nil, surface: "", style: .bokmal).isEmpty)
        XCTAssertEqual(
            LocalCalibrationCopy.summary(measuredTemperature: nil, frost: true, surface: "Bil/tak", style: .english),
            ["Frost: car/roof"]
        )
        XCTAssertEqual(
            LocalCalibrationCopy.summary(measuredTemperature: 2, frost: false, surface: "", style: .bokmal),
            ["Målt 2 °C", "Ingen frost observert"]
        )
    }

    func testYrFixturePrefersDetailedHourOverOverlappingSixHourEstimate() throws {
        let forecast = try YrService.decodeLocationForecast(Self.locationForecastFixture)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(forecast.count, 6)
        XCTAssertEqual(forecast.map { calendar.component(.hour, from: $0.time) }, [10, 11, 12, 13, 14, 15])
        XCTAssertEqual(forecast[0].precip, 1, accuracy: 0.001)
        XCTAssertEqual(forecast[2].precip, 0.8, accuracy: 0.001)
        XCTAssertEqual(forecast[2].precipMax, 1.2)
        XCTAssertEqual(forecast[2].precipProbability, 60)
        XCTAssertEqual(forecast[2].temp, 2)
    }

    func testYrWeatherBodiesAreReadWithinEndpointLimits() async throws {
        let locationFixture = Self.locationForecastFixture
        let locationBody = try await YrService.readLimitedBody(
            from: Self.byteStream(locationFixture),
            maximumBytes: YrService.maximumLocationForecastPayloadBytes,
            expectedContentLength: Int64(locationFixture.count)
        )
        XCTAssertEqual(try YrService.decodeLocationForecast(locationBody).count, 6)

        let nowcastFixture = Self.nowcastFixture(rateAtFiveMinutes: 0.8)
        let nowcastBody = try await YrService.readLimitedBody(
            from: Self.byteStream(nowcastFixture),
            maximumBytes: YrService.maximumNowcastPayloadBytes,
            expectedContentLength: Int64(nowcastFixture.count)
        )
        XCTAssertEqual(try YrService.decodeNowcast(nowcastBody).samples.count, 1)

        let exactLimit = try await YrService.readLimitedBody(
            from: Self.byteStream(Data([1, 2, 3, 4])),
            maximumBytes: 4,
            expectedContentLength: -1
        )
        XCTAssertEqual(Array(exactLimit), [1, 2, 3, 4])

        do {
            _ = try await YrService.readLimitedBody(
                from: Self.byteStream(Data([1, 2, 3, 4, 5])),
                maximumBytes: 4,
                expectedContentLength: -1
            )
            XCTFail("A body exceeding the cap must be rejected even without Content-Length")
        } catch {
            XCTAssertEqual(error as? YrForecastPayloadError, .tooLarge)
        }

        do {
            _ = try await YrService.readLimitedBody(
                from: Self.byteStream(Data([1, 2, 3, 4, 5])),
                maximumBytes: 4,
                expectedContentLength: 5
            )
            XCTFail("A declared oversized body must be rejected before it is read")
        } catch {
            XCTAssertEqual(error as? YrForecastPayloadError, .tooLarge)
        }
    }

    private static func byteStream(_ data: Data) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in data { continuation.yield(byte) }
            continuation.finish()
        }
    }

    func testYrLocationForecastRejectsOversizedPayloadBeforeDecoding() {
        let oversized = Data(repeating: 0, count: YrService.maximumLocationForecastPayloadBytes + 1)
        XCTAssertThrowsError(try YrService.decodeLocationForecast(oversized)) { error in
            XCTAssertEqual(error as? YrForecastPayloadError, .tooLarge)
        }
    }

    func testYrLocationForecastRejectsUnreasonableTimeseriesCount() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.locationForecastFixture) as? [String: Any])
        var properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let series = try XCTUnwrap(properties["timeseries"] as? [[String: Any]])
        let first = try XCTUnwrap(series.first)
        properties["timeseries"] = Array(
            repeating: first,
            count: YrService.maximumLocationForecastTimeSteps + 1
        )
        root["properties"] = properties
        let excessive = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(try YrService.decodeLocationForecast(excessive)) { error in
            XCTAssertEqual(error as? YrForecastPayloadError, .tooManyTimeSteps)
        }
    }

    func testYrNowcastAcceptsPayloadAtByteLimitAndRejectsOversizedPayloadBeforeDecoding() throws {
        let fixture = Self.nowcastFixture(rateAtFiveMinutes: 0.8)
        XCTAssertNoThrow(try YrService.decodeNowcast(fixture))

        var atLimit = fixture
        atLimit.append(contentsOf: Data(repeating: 0x20, count: YrService.maximumNowcastPayloadBytes - fixture.count))
        XCTAssertEqual(atLimit.count, YrService.maximumNowcastPayloadBytes)
        XCTAssertNoThrow(try YrService.decodeNowcast(atLimit))

        let oversized = Data(repeating: 0, count: YrService.maximumNowcastPayloadBytes + 1)
        XCTAssertThrowsError(try YrService.decodeNowcast(oversized)) { error in
            XCTAssertEqual(error as? YrForecastPayloadError, .tooLarge)
        }
    }

    func testYrNowcastAcceptsMaximumTimeseriesCountAndRejectsOneMoreBeforeSorting() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.nowcastFixture(rateAtFiveMinutes: 0.8)) as? [String: Any])
        var properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let series = try XCTUnwrap(properties["timeseries"] as? [[String: Any]])
        let first = try XCTUnwrap(series.first)
        properties["timeseries"] = Array(repeating: first, count: YrService.maximumNowcastTimeSteps)
        root["properties"] = properties
        let atLimit = try JSONSerialization.data(withJSONObject: root)
        XCTAssertNoThrow(try YrService.decodeNowcast(atLimit))

        properties["timeseries"] = Array(repeating: first, count: YrService.maximumNowcastTimeSteps + 1)
        root["properties"] = properties
        let excessive = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try YrService.decodeNowcast(excessive)) { error in
            XCTAssertEqual(error as? YrForecastPayloadError, .tooManyTimeSteps)
        }
    }

    func testYrDecodersIgnoreCorruptNumbersWithoutLosingValidWeather() throws {
        let location = Data("""
        {"properties":{"timeseries":[
          {"time":"2033-05-18T10:00:00Z","data":{"instant":{"details":{"air_temperature":7,"relative_humidity":70,"wind_speed":2,"cloud_area_fraction":90}},"next_1_hours":{"details":{"precipitation_amount":0.7,"probability_of_precipitation":80}}}},
          {"time":"2033-05-18T11:00:00Z","data":{"instant":{"details":{"air_temperature":7,"relative_humidity":70,"wind_speed":151,"cloud_area_fraction":90}},"next_1_hours":{"details":{"precipitation_amount":99,"probability_of_precipitation":100}}}},
          {"time":"2033-05-18T12:00:00Z","data":{"instant":{"details":{"air_temperature":-89,"relative_humidity":100,"wind_speed":130,"wind_speed_of_gust":145,"cloud_area_fraction":100,"dew_point_temperature":-90}},"next_1_hours":{"details":{"precipitation_amount":900,"probability_of_precipitation":100}}}}
        ]}}
        """.utf8)

        let forecast = try YrService.decodeLocationForecast(location)
        XCTAssertEqual(forecast.count, 2)
        XCTAssertEqual(forecast[0].precip, 0.7, accuracy: 0.001)
        XCTAssertFalse(AlertType.vind.matches(forecast[0], threshold: 12))
        XCTAssertTrue(AlertType.regn.matches(forecast[0], threshold: 0.5))
        XCTAssertEqual(forecast[1].temp, -89)
        XCTAssertEqual(forecast[1].wind, 130)
        XCTAssertEqual(forecast[1].precip, 900)

        let nowcast = Data("""
        {"properties":{"meta":{"radar_coverage":"ok"},"timeseries":[
          {"time":"2033-05-18T10:00:00Z","data":{"instant":{"details":{"precipitation_rate":2000,"air_temperature":999,"relative_humidity":150,"wind_speed":151,"wind_speed_of_gust":-1}}}},
          {"time":"2033-05-18T10:05:00Z","data":{"instant":{"details":{"precipitation_rate":0.8}}}}
        ]}}
        """.utf8)
        let decodedNowcast = try YrService.decodeNowcast(nowcast)
        XCTAssertEqual(decodedNowcast.samples.map(\.rate), [0.8])
        XCTAssertNil(decodedNowcast.observation?.temperature)
        XCTAssertNil(decodedNowcast.observation?.relativeHumidity)
        XCTAssertNil(decodedNowcast.observation?.wind)
        XCTAssertNil(decodedNowcast.observation?.gust)

        let merged = YrService.applying(nowcast: decodedNowcast, to: [forecast[0]])
        XCTAssertEqual(merged[0].temp, forecast[0].temp)
        XCTAssertEqual(merged[0].wind, forecast[0].wind)
        XCTAssertTrue(AlertType.regn.matches(merged[0], threshold: 0.5))
    }

    func testWetNowcastOverridesDryTableAndUsesExactOnset() throws {
        let table = try YrService.decodeLocationForecast(Self.dryLocationForecastFixture)
        let nowcast = try YrService.decodeNowcast(Self.nowcastFixture(rateAtFiveMinutes: 0.8))
        let merged = YrService.applying(nowcast: nowcast, to: table)
        let onset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2033-05-18T10:05:00Z"))
        var rule = Rule(type: .regn)
        rule.threshold = 0.5

        XCTAssertEqual(merged[0].radarSamples?.count, 2)
        XCTAssertEqual(merged[0].precipitationRate, 0.8, accuracy: 0.001)
        XCTAssertEqual(merged[0].temp, 8)
        XCTAssertEqual(merged[0].wind, 4)
        XCTAssertEqual(merged[0].gust, 9)
        XCTAssertEqual(merged[0].dew, 4.7, accuracy: 0.2)
        XCTAssertEqual(
            Planner.plan(rule: rule, forecast: merged, placeName: "Namsos", now: onset.addingTimeInterval(-6 * 60)).eventAt,
            onset
        )
    }

    func testNowcastDeduplicatesTimestampKeepingHighestRate() {
        let samples = [
            PrecipitationSample(time: base, rate: 0.2),
            PrecipitationSample(time: base.addingTimeInterval(5 * 60), rate: 0.1),
            PrecipitationSample(time: base.addingTimeInterval(5 * 60), rate: 0.8),
            PrecipitationSample(time: base.addingTimeInterval(2 * 3_600), rate: 1.2)
        ]

        let normalized = YrService.ninetyMinuteNowcast(from: samples)

        XCTAssertEqual(normalized.map(\.time), [base, base.addingTimeInterval(5 * 60)])
        XCTAssertEqual(normalized.last?.rate, 0.8)
    }

    func testWetNowcastFlowsFromYrPayloadToPushAndWidgetStatus() throws {
        let table = try YrService.decodeLocationForecast(Self.dryLocationForecastFixture)
        let nowcast = try YrService.decodeNowcast(Self.nowcastFixture(rateAtFiveMinutes: 0.8))
        let forecast = YrService.applying(nowcast: nowcast, to: table)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2033-05-18T09:30:00Z"))
        let onset = try XCTUnwrap(ISO8601DateFormatter().date(from: "2033-05-18T10:05:00Z"))
        var rule = Rule(type: .regn)
        rule.threshold = 0.5
        rule.leadMinutes = 30
        let place = Place(name: "Namsos", lat: 64.4662, lon: 11.4957, preposition: .nerri, rules: [rule])

        let plan = Planner.plan(
            rule: rule,
            forecast: forecast,
            placeName: place.nameWithPreposition,
            placeID: place.id,
            now: now
        )
        let alert = try XCTUnwrap(plan.alerts.first)
        let snapshot = WidgetWeatherSnapshot(place: place, forecast: forecast, updatedAt: now)
        let transferred = try JSONDecoder().decode(
            WidgetWeatherSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        let status = try XCTUnwrap(
            Planner.statuses(for: transferred.place, forecast: transferred.forecast, now: now)
                .first(where: { $0.type == .regn })
        )

        XCTAssertEqual(alert.eventAt, onset)
        XCTAssertEqual(alert.fireAt, now.addingTimeInterval(5 * 60))
        XCTAssertFalse(alert.possible)
        XCTAssertEqual(
            NotificationCopy.title(
                for: alert.rule,
                placeName: alert.placeName,
                possible: alert.possible,
                languageStyle: .inntrondersk
            ),
            "D bli Regn! nerri Namsos"
        )
        XCTAssertEqual(status.type, .regn)
        XCTAssertEqual(status.eventAt, onset)
        XCTAssertEqual(status.text, "Regn om en halvtime.")
    }

    func testDryNowcastDoesNotEraseRainFromTableForecast() throws {
        let table = try YrService.decodeLocationForecast(Self.rainyLocationForecastFixture)
        let nowcast = try YrService.decodeNowcast(Self.nowcastFixture(rateAtFiveMinutes: 0))
        let merged = YrService.applying(nowcast: nowcast, to: table)

        XCTAssertEqual(merged[0].precip, 0.7, accuracy: 0.001)
        XCTAssertEqual(merged[0].precipitationRate, 0.7, accuracy: 0.001)
        XCTAssertTrue(AlertType.regn.matches(merged[0], threshold: 0.5))
    }

    func testWeatherTypeFixtureLocksThresholdsAndSleetBoundary() {
        let rain = ForecastHour(time: base, temp: 1.1, precip: 0.6, wind: 3, cloud: 90, dew: 0)
        let sleetAsSnow = ForecastHour(time: base, temp: 1, precip: 0.6, wind: 3, cloud: 90, dew: 0)
        let dew = ForecastHour(time: base, temp: 5, precip: 0, wind: 2, cloud: 60, dew: 4.5)
        let sunAndWind = ForecastHour(time: base, temp: 9, precip: 0, wind: 4, cloud: 10, dew: 1, gust: 13)
        let frost = ForecastHour(time: base, temp: -0.1, precip: 0, wind: 1, cloud: 20, dew: -2)

        XCTAssertTrue(AlertType.regn.matches(rain, threshold: 0.5))
        XCTAssertFalse(AlertType.sno.matches(rain, threshold: 0.5))
        XCTAssertTrue(AlertType.sno.matches(sleetAsSnow, threshold: 0.5))
        XCTAssertFalse(AlertType.regn.matches(sleetAsSnow, threshold: 0.5))
        XCTAssertTrue(AlertType.dugg.matches(dew, threshold: 1))
        XCTAssertTrue(AlertType.sol.matches(sunAndWind, threshold: 20))
        XCTAssertTrue(AlertType.vind.matches(sunAndWind, threshold: 12))
        XCTAssertTrue(AlertType.temperatur.matches(sunAndWind, threshold: 10))
        XCTAssertTrue(AlertType.frost.matches(frost, threshold: 0))
    }

    func testRainAndSnowAlertsSwitchExactlyAtOneDegree() {
        func hour(_ temperature: Double) -> ForecastHour {
            ForecastHour(time: base, temp: temperature, precip: 0.6, wind: 1, cloud: 50, dew: 0)
        }

        for temperature in [(1.0).nextDown, 1.0] {
            XCTAssertTrue(AlertType.sno.matches(hour(temperature), threshold: 0.5))
            XCTAssertFalse(AlertType.regn.matches(hour(temperature), threshold: 0.5))
        }
        XCTAssertFalse(AlertType.sno.matches(hour((1.0).nextUp), threshold: 0.5))
        XCTAssertTrue(AlertType.regn.matches(hour((1.0).nextUp), threshold: 0.5))
    }

    func testLegacyStoredStateKeepsValidPlacesAndSkipsOnlyUnknownRules() throws {
        let data = Data("""
        {"places":[
          {"name":"Gamle Klinga","lat":64.4,"lon":11.4,"preposition":"på","rules":[
            {"type":"skyfritt"},
            {"type":"ukjent-værtype"}
          ]},
          {"name":42,"lat":0,"lon":0}
        ],"selectedID":"00000000-0000-0000-0000-000000000001"}
        """.utf8)

        let state = try JSONDecoder().decode(PersistedStoreState.self, from: data)

        XCTAssertEqual(state.places.count, 1)
        XCTAssertEqual(state.places[0].displayName, "Gamle Klinga")
        XCTAssertEqual(state.places[0].resolvedPreposition, .pa)
        XCTAssertEqual(state.places[0].rules.count, 1)
        XCTAssertEqual(state.places[0].rules[0].type, .sol)
        XCTAssertEqual(state.places[0].rules[0].activeFromHour, 7)
        XCTAssertTrue(state.places[0].areNotificationsEnabled)
        XCTAssertTrue(state.log.isEmpty)
        XCTAssertTrue(state.needsPersistedStateRepair)
    }

    func testLegacyNamesForLanguageAndWeatherTypesRemainReadable() throws {
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode(AlertLanguageStyle.self, from: Data("\"inntrøndersk\"".utf8)), .inntrondersk)
        XCTAssertEqual(try decoder.decode(AlertType.self, from: Data("\"snø\"".utf8)), .sno)
        XCTAssertEqual(try decoder.decode(AlertType.self, from: Data("\"duggfall\"".utf8)), .dugg)
        XCTAssertEqual(try decoder.decode(AlertType.self, from: Data("\"vindkast\"".utf8)), .vind)
    }

    func testPersistedStateRoundTripKeepsCurrentPlaceAndRuleSettings() throws {
        var rule = Rule(type: .frost)
        rule.templateTitle = "Frost i natt"
        rule.onlyWhenNearby = true
        var place = Place(name: "Andersmovegen 15", lat: 64.4, lon: 11.5, preposition: .bortpa, rules: [rule])
        place.customName = "Hjemme"
        place.notificationsEnabled = false
        place.rulesOnlyDisplay = true
        place.hiddenAlertTypes = [.dugg, .vind]
        place.frostMargin = 2.5
        let state = PersistedStoreState(places: [place], selectedID: place.id, log: [])

        let decoded = try JSONDecoder().decode(PersistedStoreState.self, from: JSONEncoder().encode(state))
        let saved = try XCTUnwrap(decoded.places.first)

        XCTAssertEqual(decoded.selectedID, place.id)
        XCTAssertEqual(saved.customName, "Hjemme")
        XCTAssertEqual(saved.preposition, .bortpa)
        XCTAssertEqual(saved.notificationsEnabled, false)
        XCTAssertEqual(saved.rulesOnlyDisplay, true)
        XCTAssertEqual(saved.hiddenAlertTypes, [.dugg, .vind])
        XCTAssertEqual(saved.frostMargin, 2.5)
        XCTAssertTrue(saved.rules[0].onlyWhenNearby)
    }

    func testPlaceCustomNameIsNormalizedAndLengthBounded() throws {
        let ordinary = Place(name: "Klinga", customName: "  Hytta  ", lat: 64.4, lon: 11.4)
        XCTAssertEqual(ordinary.customName, "Hytta")
        XCTAssertEqual(ordinary.displayName, "Hytta")

        let repeatedGrapheme = "👨‍👩‍👧‍👦"
        let importedName = String(repeating: repeatedGrapheme, count: Place.maximumCustomNameLength + 5)
        let rawPlaceJSON = """
        {"id":"\(UUID())","name":"Klinga","customName":"\(importedName)","lat":64.4,"lon":11.4}
        """
        let imported = try JSONDecoder().decode(Place.self, from: Data(rawPlaceJSON.utf8))
        let rawStateJSON = """
        {"places":[\(rawPlaceJSON)],"selectedID":null,"log":[]}
        """
        let restored = try JSONDecoder().decode(PersistedStoreState.self, from: Data(rawStateJSON.utf8))
        let expectedName = String(importedName.prefix(Place.maximumCustomNameLength))

        XCTAssertEqual(imported.customName?.count, Place.maximumCustomNameLength)
        XCTAssertEqual(imported.customName, expectedName)
        XCTAssertEqual(restored.places.first?.customName, expectedName)
        XCTAssertEqual(Place.normalizedCustomName(" \(importedName) ")?.count, Place.maximumCustomNameLength)
        XCTAssertNil(Place.normalizedCustomName(" \n "))
    }

    func testConfigurationExportPreservesLanguageAndSelectedPlaceAcrossRestart() throws {
        var place = Place(name: "Namsos", lat: 64.5, lon: 11.5, preposition: .nerri)
        place.temperatureOffset = -1.5
        let export = WeatherConfigurationExport(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(WeatherConfigurationExport.self, from: encoder.encode(export))

        XCTAssertEqual(restored.alertLanguageStyle, .english)
        XCTAssertNil(restored.appSettings, "Older setup copies remain valid and do not overwrite app preferences.")
        XCTAssertEqual(restored.selectedPlaceID, place.id)
        XCTAssertEqual(restored.places.first?.nameWithPreposition, "nerri Namsos")
        XCTAssertEqual(restored.places.first?.localTemperatureOffset, -1.5)
    }

    func testConfigurationDocumentFileRoundTripPreservesISODateLanguageSelectionAndRules() throws {
        var rule = Rule(type: .regn)
        rule.threshold = 4.5
        let home = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        var place = Place(name: "Åfjord", lat: 64.8, lon: 10.2, rules: [rule])
        place.temperatureOffset = -1.5
        let startedAt = Date()
        let document = WeatherConfigurationDocument(
            places: [home, place], selectedPlaceID: place.id, alertLanguageStyle: .english
        )

        let data = try document.serializedData()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exportedAtString = try XCTUnwrap(json["exportedAt"] as? String)
        XCTAssertTrue(exportedAtString.contains("T"))
        XCTAssertTrue(exportedAtString.hasSuffix("Z"))

        let importedDocument = try WeatherConfigurationDocument(data: data)
        let imported = importedDocument.configuration

        XCTAssertEqual(imported.formatVersion, 1)
        XCTAssertGreaterThanOrEqual(imported.exportedAt, startedAt.addingTimeInterval(-1))
        XCTAssertLessThanOrEqual(imported.exportedAt, Date().addingTimeInterval(1))
        XCTAssertEqual(imported.alertLanguageStyle, .english)
        XCTAssertEqual(imported.selectedPlaceID, place.id)
        XCTAssertEqual(imported.places.map(\.id), [home.id, place.id])
        let importedPlace = try XCTUnwrap(imported.places.first { $0.id == place.id })
        XCTAssertEqual(importedPlace.name, "Åfjord")
        XCTAssertEqual(importedPlace.temperatureOffset, -1.5)
        XCTAssertEqual(importedPlace.rules.first?.threshold, 4.5)
    }

    func testConfigurationDocumentRoundTripIncludesDurableAppSettings() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        var settings = ApplicationSettingsBackup(homeFavorites: HomeFavorites())
        settings.homeFavorites = HomeFavorites(left: place.id, right: nil)
        settings.homePlaceID = place.id.uuidString
        settings.cabinPlaceID = ""
        settings.placeSortMode = "manual"
        settings.homeShortcutTitle = "Hjemme"
        settings.cabinShortcutTitle = ""
        settings.textSeparator = WeatherTextSeparator.bullet.rawValue
        settings.watchPlaceSource = WatchPlaceSource.fixed.rawValue
        settings.watchFixedPlaceID = place.id.uuidString
        settings.liveWeatherActivitiesEnabled = false
        let document = WeatherConfigurationDocument(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .bokmal,
            appSettings: settings
        )

        let restored = try WeatherConfigurationDocument(data: document.serializedData()).configuration

        XCTAssertEqual(restored.appSettings, settings)
    }

    func testApplicationSettingsBackupCapturesStandardAndSharedPreferences() {
        let suiteID = "varsel.test.configuration-settings.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteID))
        let sharedDefaults = try! XCTUnwrap(UserDefaults(suiteName: "\(suiteID).shared"))
        defer {
            defaults.removePersistentDomain(forName: suiteID)
            sharedDefaults.removePersistentDomain(forName: "\(suiteID).shared")
        }
        let placeID = UUID()
        defaults.set(placeID.uuidString, forKey: PlaceOrderingSettings.homePlaceIDKey)
        defaults.set("Hjemme", forKey: PlaceOrderingSettings.homeShortcutTitleKey)
        defaults.set("manual", forKey: PlaceOrderingSettings.sortModeKey)
        defaults.set("fixed", forKey: WatchPlaceSettings.sourceKey)
        defaults.set(false, forKey: LiveWeatherActivitySettings.enabledKey)
        sharedDefaults.set(WeatherTextSeparator.comma.rawValue, forKey: WeatherTextSeparator.key)

        let backup = ApplicationSettingsBackup(
            homeFavorites: HomeFavorites(left: placeID, right: nil),
            defaults: defaults,
            sharedDefaults: sharedDefaults
        )
        defaults.set("", forKey: PlaceOrderingSettings.homePlaceIDKey)
        sharedDefaults.set(WeatherTextSeparator.dash.rawValue, forKey: WeatherTextSeparator.key)
        backup.persist(to: defaults, sharedDefaults: sharedDefaults)
        let restored = ApplicationSettingsBackup(
            homeFavorites: HomeFavorites(left: placeID, right: nil),
            defaults: defaults,
            sharedDefaults: sharedDefaults
        )

        XCTAssertEqual(backup.homeFavorites.left, placeID)
        XCTAssertEqual(backup.homePlaceID, placeID.uuidString)
        XCTAssertEqual(backup.homeShortcutTitle, "Hjemme")
        XCTAssertEqual(backup.placeSortMode, "manual")
        XCTAssertEqual(backup.watchPlaceSource, "fixed")
        XCTAssertFalse(backup.liveWeatherActivitiesEnabled)
        XCTAssertEqual(backup.textSeparator, WeatherTextSeparator.comma.rawValue)
        XCTAssertEqual(restored, backup)
    }

    func testConfigurationImportNormalizesAppSettingsAgainstImportedPlaces() {
        let importedPlace = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let omittedPlaceID = UUID()
        var settings = ApplicationSettingsBackup(homeFavorites: HomeFavorites())
        settings.homeFavorites = HomeFavorites(left: importedPlace.id, right: omittedPlaceID)
        settings.homePlaceID = importedPlace.id.uuidString
        settings.cabinPlaceID = omittedPlaceID.uuidString
        settings.placeSortMode = "unknown"
        settings.homeShortcutTitle = String(repeating: "H", count: 140)
        settings.textSeparator = "unknown"
        settings.watchPlaceSource = "unknown"
        settings.watchFixedPlaceID = omittedPlaceID.uuidString
        let configuration = WeatherConfigurationExport(
            places: [importedPlace], selectedPlaceID: importedPlace.id,
            alertLanguageStyle: .bokmal, appSettings: settings
        )

        let plan = ConfigurationImportPlan(
            configuration: configuration, currentPlaces: [], currentSelection: nil,
            currentLanguageStyle: .english, mode: .replace
        )

        XCTAssertEqual(plan.appSettings?.homeFavorites, HomeFavorites(left: importedPlace.id, right: nil))
        XCTAssertEqual(plan.appSettings?.homePlaceID, importedPlace.id.uuidString)
        XCTAssertEqual(plan.appSettings?.cabinPlaceID, "")
        XCTAssertEqual(plan.appSettings?.placeSortMode, "automatic")
        XCTAssertEqual(plan.appSettings?.homeShortcutTitle, String(repeating: "H", count: 120))
        XCTAssertEqual(plan.appSettings?.textSeparator, WeatherTextSeparator.space.rawValue)
        XCTAssertEqual(plan.appSettings?.watchPlaceSource, WatchPlaceSource.position.rawValue)
        XCTAssertEqual(plan.appSettings?.watchFixedPlaceID, "")

        let oldBackup = WeatherConfigurationExport(
            places: [importedPlace], selectedPlaceID: importedPlace.id, alertLanguageStyle: .bokmal
        )
        let oldPlan = ConfigurationImportPlan(
            configuration: oldBackup, currentPlaces: [], currentSelection: nil,
            currentLanguageStyle: .english, mode: .replace
        )
        XCTAssertNil(oldPlan.appSettings)
    }

    @MainActor
    func testConfigurationImportRefreshesWidgetWithImportedTextSeparator() throws {
        let sharedDefaults = try XCTUnwrap(WeatherTextSeparator.defaults)
        let previousSharedDomain = UserDefaults.standard.persistentDomain(forName: WeatherTextSeparator.appGroup)
        let persistenceKey = "varsel.test.configuration-widget-import.\(UUID().uuidString)"
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let hours = [ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 40, dew: 6)]
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousSharedDomain {
                sharedDefaults.setPersistentDomain(previousSharedDomain, forName: WeatherTextSeparator.appGroup)
            } else {
                sharedDefaults.removePersistentDomain(forName: WeatherTextSeparator.appGroup)
            }
        }

        sharedDefaults.set(WeatherTextSeparator.comma.rawValue, forKey: WeatherTextSeparator.key)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: hours], forecastUpdatedAt: [place.id: Date()]
        )), forKey: persistenceKey)
        var settings = ApplicationSettingsBackup(homeFavorites: HomeFavorites())
        settings.textSeparator = WeatherTextSeparator.bullet.rawValue
        let configuration = WeatherConfigurationExport(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .bokmal,
            appSettings: settings
        )
        let plan = ConfigurationImportPlan(
            configuration: configuration, currentPlaces: [place], currentSelection: place.id,
            currentLanguageStyle: .bokmal, mode: .replace
        )
        let store = Store(
            forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey,
            notificationRescheduler: { _, _, _, _, _ in
                NotificationScheduleResult(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil)
            }
        )

        XCTAssertTrue(store.applyConfigurationImport(plan))
        XCTAssertEqual(SharedWidgetData.load()?.textSeparator, .bullet)
    }

    func testConfigurationDocumentFileRoundTripPreservesEmptyPlacesAndLanguage() throws {
        let document = WeatherConfigurationDocument(
            places: [], selectedPlaceID: nil, alertLanguageStyle: .english
        )

        let data = try document.serializedData()
        let imported = try WeatherConfigurationDocument(data: data).configuration

        XCTAssertEqual(imported.places, [])
        XCTAssertNil(imported.selectedPlaceID)
        XCTAssertEqual(imported.alertLanguageStyle, .english)
    }

    func testConfigurationImportRejectsDataAboveSizeLimit() {
        let oversized = Data(
            repeating: 0x20,
            count: WeatherConfigurationDocument.maximumImportSizeBytes + 1
        )

        XCTAssertThrowsError(try WeatherConfigurationDocument(data: oversized)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadTooLarge)
        }
    }

    func testConfigurationImportAcceptsValidJSONAtSizeLimit() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let encoded = try WeatherConfigurationDocument(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .english
        ).serializedData()
        let remainingBytes = WeatherConfigurationDocument.maximumImportSizeBytes - encoded.count
        XCTAssertGreaterThanOrEqual(remainingBytes, 0)
        var atLimit = encoded
        atLimit.append(Data(repeating: 0x20, count: remainingBytes))

        let imported = try WeatherConfigurationDocument(data: atLimit).configuration

        XCTAssertEqual(imported.places.map(\.id), [place.id])
    }

    func testConfigurationDocumentRejectsInvalidJSONFileContents() {
        let file = FileWrapper(regularFileWithContents: Data("this is not JSON".utf8))

        XCTAssertThrowsError(try WeatherConfigurationDocument(file: file))
    }

    func testConfigurationExportFailureIsActionableLocalizedAndHidesSystemDetails() throws {
        let error = NSError(
            domain: "Exporter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "/private/user/Documents/secret.json"]
        )
        let norwegian = try XCTUnwrap(
            ConfigurationExportFailure.message(for: error, languageStyle: .bokmal)
        )
        XCTAssertTrue(norwegian.contains("Prøv eksporten på nytt"))
        XCTAssertFalse(norwegian.contains("secret.json"))

        let english = try XCTUnwrap(
            ConfigurationExportFailure.message(for: error, languageStyle: .english)
        )
        XCTAssertTrue(english.contains("Try exporting again"))
        XCTAssertFalse(english.contains("secret.json"))
        XCTAssertNil(ConfigurationExportFailure.message(
            for: CancellationError(), languageStyle: .bokmal
        ))
        XCTAssertNil(ConfigurationExportFailure.message(
            for: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
            languageStyle: .bokmal
        ))
    }

    func testConfigurationImportPreviewPlansReplaceAndMergeWithoutMutatingCurrentPlaces() {
        let sharedID = UUID()
        let preserved = Place(name: "Namsos", lat: 64.4, lon: 11.4)
        let existing = Place(id: sharedID, name: "Old name", lat: 64.5, lon: 11.5)
        var updated = existing
        updated.name = "New name"
        let added = Place(name: "Åfjord", lat: 64.8, lon: 10.2)
        let configuration = WeatherConfigurationExport(
            places: [updated, added], selectedPlaceID: added.id, alertLanguageStyle: .english
        )

        let merge = ConfigurationImportPlan(
            configuration: configuration,
            currentPlaces: [preserved, existing],
            currentSelection: existing.id,
            currentLanguageStyle: .bokmal,
            mode: .merge
        )
        let replace = ConfigurationImportPlan(
            configuration: configuration,
            currentPlaces: [preserved, existing],
            currentSelection: existing.id,
            currentLanguageStyle: .bokmal,
            mode: .replace
        )

        XCTAssertEqual(merge.places.map(\.id), [preserved.id, existing.id, added.id])
        XCTAssertEqual(merge.places.first(where: { $0.id == existing.id })?.name, "New name")
        XCTAssertEqual(merge.addedPlaceCount, 1)
        XCTAssertEqual(merge.updatedPlaceCount, 1)
        XCTAssertEqual(merge.preservedPlaceCount, 1)
        XCTAssertEqual(merge.selectedPlaceID, added.id)
        XCTAssertEqual(merge.alertLanguageStyle, .english)
        XCTAssertEqual(replace.places.map(\.id), [existing.id, added.id])
        XCTAssertEqual(replace.preservedPlaceCount, 0)
        XCTAssertEqual(replace.selectedPlaceID, added.id)
        XCTAssertEqual([preserved.name, existing.name], ["Namsos", "Old name"])
    }

    func testConfigurationImportPreviewRefusesEmptyBackupAndDoesNotLeakReadErrors() throws {
        let emptyBackup = WeatherConfigurationExport(places: [], selectedPlaceID: nil, alertLanguageStyle: .english)
        let plan = ConfigurationImportPlan(
            configuration: emptyBackup,
            currentPlaces: [Place(name: "Klinga", lat: 64.4, lon: 11.4)],
            currentSelection: nil,
            currentLanguageStyle: .bokmal,
            mode: .replace
        )
        XCTAssertFalse(plan.canApply)
        let mergePlan = ConfigurationImportPlan(
            configuration: emptyBackup,
            currentPlaces: [Place(name: "Klinga", lat: 64.4, lon: 11.4)],
            currentSelection: nil,
            currentLanguageStyle: .bokmal,
            mode: .merge
        )
        XCTAssertFalse(mergePlan.canApply)

        let error = NSError(
            domain: "Importer", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "/private/user/Documents/secret.json"]
        )
        let norwegian = try XCTUnwrap(ConfigurationImportFailure.message(for: error, languageStyle: .bokmal))
        XCTAssertTrue(norwegian.contains("oppsettet er ikke endret"))
        XCTAssertFalse(norwegian.contains("secret.json"))
        let english = try XCTUnwrap(ConfigurationImportFailure.message(for: error, languageStyle: .english))
        XCTAssertTrue(english.contains("current setup has not been changed"))
        XCTAssertFalse(english.contains("secret.json"))
        XCTAssertNil(ConfigurationImportFailure.message(for: CancellationError(), languageStyle: .bokmal))
    }

    func testConfigurationImportReadsAtMostTheConfiguredFileLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: WeatherConfigurationDocument.maximumImportSizeBytes + 1).write(to: url)

        XCTAssertThrowsError(try WeatherConfigurationDocument.readImportData(from: url)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadTooLarge)
        }
    }

    func testConfigurationImportReadsValidFileAtExactSizeLimit() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let document = WeatherConfigurationDocument(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .english
        )
        var atLimit = try document.serializedData()
        let remainingBytes = WeatherConfigurationDocument.maximumImportSizeBytes - atLimit.count
        XCTAssertGreaterThanOrEqual(remainingBytes, 0)
        atLimit.append(Data(repeating: 0x20, count: remainingBytes))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("at-limit.json")
        try atLimit.write(to: url)

        let read = try WeatherConfigurationDocument.readImportData(from: url)
        let imported = try WeatherConfigurationDocument(data: read).configuration

        XCTAssertEqual(read.count, WeatherConfigurationDocument.maximumImportSizeBytes)
        XCTAssertEqual(imported.places.map(\.id), [place.id])
    }

    func testConfigurationDocumentRejectsJSONWithNonObjectTopLevelValue() {
        for json in ["null", "[]", "42", "\"configuration\""] {
            let file = FileWrapper(regularFileWithContents: Data(json.utf8))

            XCTAssertThrowsError(try WeatherConfigurationDocument(file: file), "Expected top-level JSON value to be rejected: \(json)")
        }
    }

    func testConfigurationDocumentRejectsUnsupportedFutureFormatVersion() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let source = WeatherConfigurationExport(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(source)) as? [String: Any])
        object["formatVersion"] = WeatherConfigurationExport.currentFormatVersion + 1
        let file = FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: object))

        XCTAssertThrowsError(try WeatherConfigurationDocument(file: file)) { error in
            guard case let DecodingError.dataCorrupted(context) = error else {
                XCTFail("Expected an unsupported format version to be rejected, got: \(error)")
                return
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "formatVersion")
            XCTAssertTrue(context.debugDescription.contains("Unsupported configuration format version"))
        }
    }

    func testConfigurationDocumentRejectsNonPositiveFormatVersions() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let source = WeatherConfigurationExport(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(source)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for invalidVersion in [0, -1] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object["formatVersion"] = invalidVersion
            let data = try JSONSerialization.data(withJSONObject: object)

            XCTAssertThrowsError(try decoder.decode(WeatherConfigurationExport.self, from: data)) { error in
                guard case let DecodingError.dataCorrupted(context) = error else {
                    XCTFail("Expected format version \(invalidVersion) to be rejected, got: \(error)")
                    return
                }
                XCTAssertEqual(context.codingPath.last?.stringValue, "formatVersion")
                XCTAssertTrue(context.debugDescription.contains("versions 1 through"))
            }
        }
    }

    func testConfigurationImportKeepsFirstPlaceForDuplicateIDsAndPreservesOtherPlaces() throws {
        let duplicateID = UUID()
        let first = Place(id: duplicateID, name: "Første", lat: 64.4, lon: 11.4)
        let duplicate = Place(id: duplicateID, name: "Duplikat", lat: 65.0, lon: 12.0)
        let other = Place(name: "Annet sted", lat: 64.8, lon: 10.2)
        let source = WeatherConfigurationExport(
            places: [first, duplicate, other],
            selectedPlaceID: duplicateID,
            alertLanguageStyle: .bokmal
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let imported = try decoder.decode(WeatherConfigurationExport.self, from: encoder.encode(source))

        XCTAssertEqual(imported.places.map(\.id), [duplicateID, other.id])
        XCTAssertEqual(imported.places.map(\.name), ["Første", "Annet sted"])
        XCTAssertEqual(imported.selectedPlaceID, duplicateID)
        XCTAssertEqual(imported.discardedPlaceCount, 1)
    }

    func testConfigurationImportRejectsMissingOrWrongTypePlacesField() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let source = WeatherConfigurationExport(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .bokmal
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(source)
        var missingPlaces = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        missingPlaces.removeValue(forKey: "places")
        var wrongTypePlaces = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        wrongTypePlaces["places"] = "not an array"

        for object in [missingPlaces, wrongTypePlaces] {
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try WeatherConfigurationDocument(data: data))
        }
    }

    func testConfigurationDocumentRejectsDirectoryInsteadOfJSONFile() {
        let directory = FileWrapper(directoryWithFileWrappers: [:])

        XCTAssertThrowsError(try WeatherConfigurationDocument(file: directory)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile)
        }
    }

    func testConfigurationDocumentRejectsEmptyRegularFile() {
        let emptyFile = FileWrapper(regularFileWithContents: Data())

        XCTAssertThrowsError(try WeatherConfigurationDocument(file: emptyFile))
    }

    func testLegacyConfigurationWithoutOptionalMetadataKeepsPlacesAndSelection() throws {
        let place = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let source = WeatherConfigurationExport(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(source)) as? [String: Any])
        object.removeValue(forKey: "formatVersion")
        object.removeValue(forKey: "exportedAt")
        object.removeValue(forKey: "alertLanguageStyle")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacyFile = FileWrapper(regularFileWithContents: legacyData)
        let importedDocument = try WeatherConfigurationDocument(file: legacyFile)
        let imported = importedDocument.configuration

        XCTAssertEqual(imported.formatVersion, 1)
        XCTAssertEqual(imported.exportedAt, .distantPast)
        XCTAssertNil(imported.alertLanguageStyle)
        XCTAssertEqual(imported.places.map(\.id), [place.id])
        XCTAssertEqual(imported.selectedPlaceID, place.id)

        let reexportedDocument = WeatherConfigurationDocument(
            places: imported.places,
            selectedPlaceID: imported.selectedPlaceID,
            alertLanguageStyle: imported.alertLanguageStyle ?? .bokmal
        )
        let reexportedData = try reexportedDocument.serializedData()
        let reimported = try WeatherConfigurationDocument(data: reexportedData).configuration
        XCTAssertEqual(reimported.places.map(\.id), [place.id])
        XCTAssertEqual(reimported.selectedPlaceID, place.id)
        XCTAssertEqual(reimported.alertLanguageStyle, .bokmal)
    }

    func testMalformedOptionalConfigurationMetadataKeepsValidPlacesAndSelection() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let source = WeatherConfigurationExport(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(source)) as? [String: Any])
        object["formatVersion"] = "version one"
        object["exportedAt"] = "not-an-ISO-8601-date"
        object["alertLanguageStyle"] = 42

        let importedData = try JSONSerialization.data(withJSONObject: object)
        let imported = try decoder.decode(WeatherConfigurationExport.self, from: importedData)

        XCTAssertEqual(imported.formatVersion, 1)
        XCTAssertEqual(imported.exportedAt, .distantPast)
        XCTAssertNil(imported.alertLanguageStyle)
        XCTAssertEqual(imported.places.map(\.id), [place.id])
        XCTAssertEqual(imported.selectedPlaceID, place.id)

        let normalizedExport = WeatherConfigurationExport(
            places: imported.places,
            selectedPlaceID: imported.selectedPlaceID,
            alertLanguageStyle: imported.alertLanguageStyle ?? .bokmal
        )
        let restored = try decoder.decode(WeatherConfigurationExport.self, from: encoder.encode(normalizedExport))
        XCTAssertEqual(restored.places.map(\.id), [place.id])
        XCTAssertEqual(restored.selectedPlaceID, place.id)
        XCTAssertEqual(restored.alertLanguageStyle, .bokmal)
    }

    func testConfigurationImportFallsBackToFirstPlaceForMissingOrUnknownSelection() throws {
        let firstPlace = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let secondPlace = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let source = WeatherConfigurationExport(
            places: [firstPlace, secondPlace], selectedPlaceID: secondPlace.id, alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validData = try encoder.encode(source)

        var invalidSelectionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        invalidSelectionObject["selectedPlaceID"] = UUID().uuidString
        let missingSelectionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        var missingSelection = missingSelectionObject
        missingSelection.removeValue(forKey: "selectedPlaceID")

        for sourceObject in [invalidSelectionObject, missingSelection] {
            let importedData = try JSONSerialization.data(withJSONObject: sourceObject)
            let importedDocument = try WeatherConfigurationDocument(data: importedData)
            let imported = importedDocument.configuration

            XCTAssertEqual(imported.selectedPlaceID, firstPlace.id)
            XCTAssertEqual(imported.places.map(\.id), [firstPlace.id, secondPlace.id])

            let exportedAgain = WeatherConfigurationDocument(
                places: imported.places,
                selectedPlaceID: imported.selectedPlaceID,
                alertLanguageStyle: imported.alertLanguageStyle ?? .bokmal
            )
            let exportedData = try exportedAgain.serializedData()
            let reimportedDocument = try WeatherConfigurationDocument(data: exportedData)
            let reimported = reimportedDocument.configuration
            XCTAssertEqual(reimported.selectedPlaceID, firstPlace.id)
            XCTAssertEqual(reimported.places.map(\.id), [firstPlace.id, secondPlace.id])
        }
    }

    func testConfigurationImportSkipsMalformedPlaceAndUsesFirstValidSelection() throws {
        let malformedPlace = Place(name: "Ugyldig", lat: 64.4, lon: 11.4)
        let firstValidPlace = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let secondValidPlace = Place(name: "Selbu", lat: 63.2, lon: 11.0)
        let source = WeatherConfigurationExport(
            places: [malformedPlace, firstValidPlace, secondValidPlace],
            selectedPlaceID: malformedPlace.id,
            alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var placeObjects = try XCTUnwrap(object["places"] as? [[String: Any]])
        placeObjects[0]["lat"] = "not-a-coordinate"
        object["places"] = placeObjects

        let importedData = try JSONSerialization.data(withJSONObject: object)
        let importedDocument = try WeatherConfigurationDocument(data: importedData)
        let imported = importedDocument.configuration

        XCTAssertEqual(imported.places.map(\.id), [firstValidPlace.id, secondValidPlace.id])
        XCTAssertEqual(imported.selectedPlaceID, firstValidPlace.id)
        XCTAssertEqual(imported.alertLanguageStyle, .english)
        XCTAssertEqual(imported.discardedPlaceCount, 1)

        let directlyReencodedData = try encoder.encode(imported)
        let directDecoder = JSONDecoder()
        directDecoder.dateDecodingStrategy = .iso8601
        let directlyReimported = try directDecoder.decode(
            WeatherConfigurationExport.self,
            from: directlyReencodedData
        )
        XCTAssertEqual(directlyReimported.discardedPlaceCount, 0)

        let reexportedDocument = WeatherConfigurationDocument(
            places: imported.places,
            selectedPlaceID: imported.selectedPlaceID,
            alertLanguageStyle: imported.alertLanguageStyle ?? .bokmal
        )
        let reexportedData = try reexportedDocument.serializedData()
        let reimportedDocument = try WeatherConfigurationDocument(data: reexportedData)
        let reimported = reimportedDocument.configuration
        XCTAssertEqual(reimported.places.map(\.id), [firstValidPlace.id, secondValidPlace.id])
        XCTAssertEqual(reimported.selectedPlaceID, firstValidPlace.id)
        XCTAssertEqual(reimported.discardedPlaceCount, 0, "Import diagnostics must not leak into a new backup")
    }

    func testConfigurationImportWithOnlyMalformedPlacesKeepsLanguageAndNoSelection() throws {
        let place = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let source = WeatherConfigurationExport(
            places: [place], selectedPlaceID: place.id, alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(source)) as? [String: Any])
        object["places"] = ["not a place", 42, NSNull()]

        let importedData = try JSONSerialization.data(withJSONObject: object)
        let imported = try decoder.decode(WeatherConfigurationExport.self, from: importedData)

        XCTAssertTrue(imported.places.isEmpty)
        XCTAssertNil(imported.selectedPlaceID)
        XCTAssertEqual(imported.alertLanguageStyle, .english)

        let reexported = try encoder.encode(WeatherConfigurationExport(
            places: imported.places,
            selectedPlaceID: imported.selectedPlaceID,
            alertLanguageStyle: imported.alertLanguageStyle ?? .bokmal
        ))
        let reimported = try decoder.decode(WeatherConfigurationExport.self, from: reexported)
        XCTAssertTrue(reimported.places.isEmpty)
        XCTAssertNil(reimported.selectedPlaceID)
        XCTAssertEqual(reimported.alertLanguageStyle, .english)
    }

    func testConfigurationImportSkipsMalformedRuleAndPreservesOtherData() throws {
        var malformedRule = Rule(type: .frost)
        malformedRule.templateTitle = "Feilformet regel"
        var retainedRule = Rule(type: .regn)
        retainedRule.templateTitle = "Gyldig regnregel"
        retainedRule.threshold = 3
        let selectedPlace = Place(
            name: "Namsos", lat: 64.5, lon: 11.5,
            rules: [malformedRule, retainedRule]
        )
        let otherPlace = Place(name: "Selbu", lat: 63.2, lon: 11.0)
        let source = WeatherConfigurationExport(
            places: [selectedPlace, otherPlace],
            selectedPlaceID: selectedPlace.id,
            alertLanguageStyle: .english
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var placeObjects = try XCTUnwrap(object["places"] as? [[String: Any]])
        var rules = try XCTUnwrap(placeObjects[0]["rules"] as? [Any])
        rules[0] = "not a rule"
        placeObjects[0]["rules"] = rules
        object["places"] = placeObjects

        let importedData = try JSONSerialization.data(withJSONObject: object)
        let importedDocument = try WeatherConfigurationDocument(data: importedData)
        let imported = importedDocument.configuration
        let importedSelected = try XCTUnwrap(imported.places.first)

        XCTAssertEqual(imported.places.map(\.id), [selectedPlace.id, otherPlace.id])
        XCTAssertEqual(imported.selectedPlaceID, selectedPlace.id)
        XCTAssertEqual(importedSelected.rules.map(\.id), [retainedRule.id])
        XCTAssertEqual(importedSelected.rules.first?.templateTitle, "Gyldig regnregel")
        XCTAssertEqual(importedSelected.rules.first?.threshold, 3)
        XCTAssertEqual(imported.alertLanguageStyle, .english)

        let reexported = WeatherConfigurationDocument(
            places: imported.places,
            selectedPlaceID: imported.selectedPlaceID,
            alertLanguageStyle: imported.alertLanguageStyle ?? .bokmal
        )
        let reexportedData = try reexported.serializedData()
        let reimportedDocument = try WeatherConfigurationDocument(data: reexportedData)
        let reimported = reimportedDocument.configuration
        XCTAssertEqual(reimported.places.map(\.id), [selectedPlace.id, otherPlace.id])
        XCTAssertEqual(reimported.selectedPlaceID, selectedPlace.id)
        XCTAssertEqual(reimported.places.first?.rules.map(\.id), [retainedRule.id])
    }

    @MainActor
    func testCancellingActiveRefreshDoesNotCancelFollowingRefresh() async {
        let queue = ForecastRefreshQueue()
        let started = expectation(description: "Active refresh started")
        let active = queue.enqueue {
            started.fulfill()
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return true
            } catch { return false }
        }
        await fulfillment(of: [started], timeout: 2)
        let following = queue.enqueue { true }
        active.cancel()
        let activeResult = await active.value
        let followingResult = await following.value
        XCTAssertFalse(activeResult)
        XCTAssertTrue(followingResult)
    }

    @MainActor
    func testOverlappingRefreshesRunInOrderAndSkipCancelledWaiter() async {
        let queue = ForecastRefreshQueue()
        let started = expectation(description: "First refresh suspended")
        var resume: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let first = queue.enqueue {
            events.append("background-start")
            await withCheckedContinuation { continuation in
                resume = continuation
                started.fulfill()
            }
            events.append("background-end")
            return false
        }
        await fulfillment(of: [started], timeout: 2)
        let cancelled = queue.enqueue {
            events.append("cancelled")
            return true
        }
        cancelled.cancel()
        let full = queue.enqueue {
            events.append("full-refresh")
            return true
        }
        XCTAssertEqual(events, ["background-start"])
        resume?.resume()
        let firstResult = await first.value
        let cancelledResult = await cancelled.value
        let fullResult = await full.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(cancelledResult)
        XCTAssertTrue(fullResult)
        XCTAssertEqual(events, ["background-start", "background-end", "full-refresh"])
    }

    @MainActor
    func testRefreshQueueSkipsCancelledQueuedOperationBeforeItStarts() async {
        let queue = ForecastRefreshQueue()
        let first = queue.enqueue { true }
        let cancelledMarker = expectation(description: "Cancelled operation is never entered")
        cancelledMarker.isInverted = true
        let cancelled = queue.enqueue {
            cancelledMarker.fulfill()
            return true
        }
        cancelled.cancel()
        _ = await first.value
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        await fulfillment(of: [cancelledMarker], timeout: 0.1)
    }

    @MainActor
    func testWidgetFallbackKeepsActualForecastAgeAndCurrentName() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hours = forecast(values: [(10, 0, 1, 10, 5)])
        let cached = WidgetWeatherSnapshot(place: place, forecast: hours, updatedAt: base, languageStyle: .inntrondersk, textSeparator: .dash)
        var renamed = place
        renamed.customName = "Hjemme"
        let snapshot = try XCTUnwrap(Store.widgetSnapshot(place: renamed, forecast: [], updatedAt: nil, cached: cached))
        XCTAssertEqual(snapshot.updatedAt, base)
        XCTAssertEqual(snapshot.forecast, hours)
        XCTAssertEqual(snapshot.place.customName, "Hjemme")
        XCTAssertEqual(snapshot.languageStyle, .inntrondersk)
        XCTAssertEqual(snapshot.textSeparator, .dash)
        let fresh = Store.widgetSnapshot(place: renamed, forecast: hours, updatedAt: base.addingTimeInterval(60), cached: cached)
        XCTAssertEqual(fresh?.updatedAt, base.addingTimeInterval(60))
    }

    @MainActor
    func testWidgetFreshAndFallbackUseSamePlaceIdentityForPositionSelection() throws {
        let position = Place(name: "Min posisjon", lat: 64.4, lon: 11.5)
        let hours = forecast(values: [(11, 0, 1, 20, 6)])
        let fresh = try XCTUnwrap(Store.widgetSnapshot(
            place: position, forecast: hours, updatedAt: base, cached: nil
        ))
        let cached = WidgetWeatherSnapshot(place: position, forecast: hours, updatedAt: base)
        let fallback = try XCTUnwrap(Store.widgetSnapshot(
            place: position, forecast: [], updatedAt: nil, cached: cached
        ))
        XCTAssertEqual(fresh.place.id, fallback.place.id)
        XCTAssertEqual(fresh.updatedAt, fallback.updatedAt)
        XCTAssertEqual(fresh.forecast, fallback.forecast)
    }

    func testSharedWidgetDataDoesNotOverwriteValidSnapshotWithEmptyForecast() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 20, dew: 5)
        SharedWidgetData.clear()
        defer { SharedWidgetData.clear() }
        SharedWidgetData.save(place: place, forecast: [hour], updatedAt: base)
        SharedWidgetData.save(place: Place(name: "Namsos", lat: 64.5, lon: 11.5), forecast: [], updatedAt: base.addingTimeInterval(60))
        XCTAssertEqual(SharedWidgetData.load()?.place.id, place.id)
        XCTAssertEqual(SharedWidgetData.load()?.forecast, [hour])
    }

    func testUnchangedWeatherBandDoesNotRewriteWidgetSnapshot() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 20, dew: 5)
        SharedWidgetData.clear()
        defer { SharedWidgetData.clear() }

        XCTAssertTrue(SharedWidgetData.save(place: place, forecast: [hour], updatedAt: base))
        XCTAssertFalse(SharedWidgetData.save(place: place, forecast: [hour], updatedAt: base))
    }

    func testIncompleteWidgetRefreshWithoutTimestampKeepsCachedSnapshot() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let cachedHour = ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 20, dew: 5)
        let partialHour = ForecastHour(time: base.addingTimeInterval(3_600), temp: 11, precip: 0, wind: 1, cloud: 20, dew: 6)
        let cached = WidgetWeatherSnapshot(place: place, forecast: [cachedHour], updatedAt: base)

        let result = try XCTUnwrap(Store.widgetSnapshot(
            place: place,
            forecast: [partialHour],
            updatedAt: nil,
            cached: cached,
            now: base.addingTimeInterval(60)
        ))
        XCTAssertEqual(result.forecast, [cachedHour])
        XCTAssertEqual(result.updatedAt, base)
    }

    func testOldForecastIsMarkedStaleWithoutChangingCachedData() {
        XCTAssertFalse(Store.isForecastStale(base, now: base.addingTimeInterval(2 * 3_600)))
        XCTAssertTrue(Store.isForecastStale(base, now: base.addingTimeInterval(2 * 3_600 + 1)))
        XCTAssertTrue(Store.isForecastStale(nil, now: base))
    }

    func testSelectedForecastRefreshSkipsFreshCacheIncludingFreshnessBoundary() async throws {
        let persistenceKey = "varsel.test.active-fresh-forecast.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let updatedAt = Date()
        let cachedForecast = makeForecast(
            through: 5, startingAt: updatedAt, precipitationOffsets: []
        )
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: cachedForecast],
            forecastUpdatedAt: [place.id: updatedAt], lastUpdate: updatedAt
        )), forKey: persistenceKey)
        let counter = ForecastFetchCounter()
        let refreshedForecast = makeForecast(through: 5, startingAt: Date(), precipitationOffsets: [])
        let store = Store(
            forecastFetcher: { _, _ in
                await counter.increment()
                return refreshedForecast
            },
            persistenceKey: persistenceKey,
            notificationRescheduler: { _, _, _, _, _ in
                NotificationScheduleResult(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil)
            }
        )

        let refreshed = await store.refreshSelectedForecastIfNeeded(
            now: updatedAt.addingTimeInterval(WeatherGlance.staleAfter)
        )

        XCTAssertFalse(refreshed)
        let fetchCount = await counter.value()
        XCTAssertEqual(fetchCount, 0, "A still-fresh cached forecast must not cause a network request")
        XCTAssertEqual(store.forecasts[place.id], cachedForecast)
    }

    func testSelectedForecastRefreshesStaleAndMissingCachesOnResume() async throws {
        let staleKey = "varsel.test.active-stale-forecast.\(UUID().uuidString)"
        let missingKey = "varsel.test.active-missing-forecast.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: staleKey)
            UserDefaults.standard.removeObject(forKey: missingKey)
        }
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let agedAt = Date().addingTimeInterval(-WeatherGlance.staleAfter - 1)
        let oldForecast = makeForecast(
            through: 5, startingAt: Date().addingTimeInterval(-3_600), precipitationOffsets: []
        )
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: oldForecast],
            forecastUpdatedAt: [place.id: agedAt], lastUpdate: agedAt
        )), forKey: staleKey)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecastUpdatedAt: [place.id: Date()]
        )), forKey: missingKey)

        let refreshedForecast = makeForecast(through: 5, startingAt: Date(), precipitationOffsets: [])
        func makeStore(key: String, counter: ForecastFetchCounter) -> Store {
            Store(
                forecastFetcher: { _, _ in
                    await counter.increment()
                    return refreshedForecast
                },
                persistenceKey: key,
                notificationRescheduler: { _, _, _, _, _ in
                    NotificationScheduleResult(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil)
                }
            )
        }
        let staleCounter = ForecastFetchCounter()
        let missingCounter = ForecastFetchCounter()
        let staleStore = makeStore(key: staleKey, counter: staleCounter)
        let missingStore = makeStore(key: missingKey, counter: missingCounter)

        let staleRefreshSucceeded = await staleStore.refreshSelectedForecastIfNeeded()
        let missingRefreshSucceeded = await missingStore.refreshSelectedForecastIfNeeded()
        XCTAssertTrue(staleRefreshSucceeded)
        XCTAssertTrue(missingRefreshSucceeded)

        let staleFetches = await staleCounter.value()
        let missingFetches = await missingCounter.value()
        XCTAssertEqual(staleFetches, 1)
        XCTAssertEqual(missingFetches, 1)
        XCTAssertFalse(Store.isForecastStale(staleStore.forecastUpdatedAt(for: place.id)))
        XCTAssertFalse(Store.isForecastStale(missingStore.forecastUpdatedAt(for: place.id)))
    }

    @MainActor
    func testSelectedForecastFailureThrottlesActivationRetryButNotManualRefresh() async throws {
        let persistenceKey = "varsel.test.active-failed-forecast-retry.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let agedAt = Date().addingTimeInterval(-WeatherGlance.staleAfter - 1)
        let oldForecast = makeForecast(
            through: 5, startingAt: Date().addingTimeInterval(-3_600), precipitationOffsets: []
        )
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: oldForecast], forecastUpdatedAt: [place.id: agedAt]
        )), forKey: persistenceKey)
        let counter = ForecastFetchCounter()
        let store = Store(
            forecastFetcher: { _, _ in
                await counter.increment()
                throw URLError(.notConnectedToInternet)
            },
            persistenceKey: persistenceKey,
            notificationRescheduler: { _, _, _, _, _ in
                NotificationScheduleResult(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil)
            }
        )

        let firstActivationRefresh = await store.refreshSelectedForecastIfNeeded()
        let repeatedActivationRefresh = await store.refreshSelectedForecastIfNeeded()
        let activationFetchCount = await counter.value()
        XCTAssertFalse(firstActivationRefresh)
        XCTAssertFalse(repeatedActivationRefresh)
        XCTAssertEqual(activationFetchCount, 1, "Repeated activation should be paused after a network failure")

        let manualRefresh = await store.refreshAll()
        let totalFetchCount = await counter.value()
        XCTAssertFalse(manualRefresh, "The injected fetcher fails even when manually refreshed")
        XCTAssertEqual(totalFetchCount, 2, "Manual refresh remains available during the activation pause")
    }

    func testSelectedForecastRetryPauseExpiresAfterFiveMinutes() {
        let failureAt = base
        XCTAssertTrue(Store.shouldDeferSelectedForecastRetry(
            lastFailureAt: failureAt, now: failureAt.addingTimeInterval(299)
        ))
        XCTAssertFalse(Store.shouldDeferSelectedForecastRetry(
            lastFailureAt: failureAt, now: failureAt.addingTimeInterval(300)
        ))
        XCTAssertFalse(Store.shouldDeferSelectedForecastRetry(lastFailureAt: nil, now: base))
    }

    func testStaleForecastIsExcludedFromPushPlanningButRemainsCached() {
        let stalePlace = Place(name: "Gammel prognose", lat: 64, lon: 11, rules: [Rule(type: .frost)])
        let boundaryPlace = Place(name: "Grense", lat: 65, lon: 11, rules: [Rule(type: .frost)])
        let freshPlace = Place(name: "Ny", lat: 66, lon: 11, rules: [Rule(type: .frost)])
        let hour = ForecastHour(
            time: base.addingTimeInterval(3_600), temp: -5, precip: 0,
            wind: 1, cloud: 10, dew: -7
        )
        let cached = [stalePlace.id: [hour], boundaryPlace.id: [hour], freshPlace.id: [hour]]
        let planning = Store.forecastsForPlanning(
            cached,
            updatedAt: [
                stalePlace.id: base.addingTimeInterval(-2 * 3_600 - 1),
                boundaryPlace.id: base.addingTimeInterval(-2 * 3_600),
                freshPlace.id: base
            ],
            now: base
        )

        XCTAssertEqual(cached[stalePlace.id], [hour], "Offline display cache must remain intact")
        XCTAssertNil(planning[stalePlace.id])
        XCTAssertEqual(Set(planning.keys), [boundaryPlace.id, freshPlace.id])
        let alerts = Planner.planAll(
            places: [stalePlace, boundaryPlace, freshPlace],
            forecasts: planning,
            now: base
        )
        XCTAssertEqual(Set(alerts.map(\.placeID)), [boundaryPlace.id, freshPlace.id])
    }

    func testFutureForecastTimestampIsStaleAfterClockMovesBack() {
        let now = base
        let fiveMinutesAhead = now.addingTimeInterval(Store.forecastFutureTimestampTolerance)
        let sixMinutesAhead = now.addingTimeInterval(Store.forecastFutureTimestampTolerance + 60)

        XCTAssertFalse(Store.isForecastStale(fiveMinutesAhead, now: now))
        XCTAssertTrue(Store.isForecastStale(sixMinutesAhead, now: now))
    }

    func testPersistedFutureForecastTimestampIsConsideredStale() throws {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let future = base.addingTimeInterval(Store.forecastFutureTimestampTolerance + 60)
        let persistenceKey = "test.futureForecastTimestamp.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let cachedHour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 20, dew: 4)
        let state = PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: [cachedHour]], forecastUpdatedAt: [place.id: future]
        )
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: persistenceKey)

        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey, now: base)

        XCTAssertNil(store.forecastUpdatedAt(for: place.id))
        XCTAssertTrue(Store.isForecastStale(store.forecastUpdatedAt(for: place.id), now: base))
        XCTAssertTrue(Store.forecastsForPlanning(
            store.forecasts, updatedAt: [place.id: future], now: base
        ).isEmpty)
        XCTAssertNil(Store.widgetSnapshot(
            place: place, forecast: store.forecasts[place.id] ?? [], updatedAt: nil,
            cached: nil, now: base
        ))

        let repairedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repaired = try JSONDecoder().decode(PersistedStoreState.self, from: repairedData)
        XCTAssertNil(repaired.forecastUpdatedAt[place.id])
    }

    func testStoreRestoreKeepsForecastTimestampAtFutureToleranceBoundary() {
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 20, dew: 4)
        let accepted = base.addingTimeInterval(Store.forecastFutureTimestampTolerance)
        let rejected = accepted.addingTimeInterval(1)

        let restored = Store.restoredForecastTimestamps(
            [place.id: accepted, UUID(): rejected],
            forecasts: [place.id: [hour]], knownPlaceIDs: [place.id], now: base
        )

        XCTAssertEqual(restored, [place.id: accepted])
    }

    func testOlderForecastCannotReplaceNewerCache() {
        XCTAssertFalse(Store.shouldReplaceForecast(existingAt: base, incomingAt: base.addingTimeInterval(-1)))
        XCTAssertTrue(Store.shouldReplaceForecast(existingAt: base, incomingAt: base.addingTimeInterval(1)))
        XCTAssertTrue(Store.shouldReplaceForecast(existingAt: nil, incomingAt: base))
    }

    func testForecastCacheDuplicateTimestampsNormalizeIndependentlyOfInputOrder() {
        let duplicateTime = base.addingTimeInterval(3_600)
        let sparse = ForecastHour(
            time: duplicateTime, temp: 8, precip: 0, wind: 1, cloud: 20, dew: 4
        )
        let firstRich = ForecastHour(
            time: duplicateTime, temp: 9, precip: 0.2, wind: 2, cloud: 25, dew: 5,
            precipProbability: 35, gust: 4,
            radarSamples: [
                PrecipitationSample(time: duplicateTime.addingTimeInterval(600), rate: 0.3),
                PrecipitationSample(time: duplicateTime.addingTimeInterval(300), rate: 0.2)
            ]
        )
        let secondRich = ForecastHour(
            time: duplicateTime, temp: 10, precip: 0.3, wind: 3, cloud: 30, dew: 6,
            precipProbability: 40, gust: 5,
            radarSamples: [
                PrecipitationSample(time: duplicateTime.addingTimeInterval(300), rate: 0.2),
                PrecipitationSample(time: duplicateTime.addingTimeInterval(600), rate: 0.3)
            ]
        )
        let nextHour = ForecastHour(
            time: duplicateTime.addingTimeInterval(3_600), temp: 7, precip: 0, wind: 1, cloud: 15, dew: 3
        )

        let forward = ForecastHour.sanitizedCacheSequence(
            [sparse, firstRich, secondRich, nextHour], fetchedAt: base
        )
        let reversed = ForecastHour.sanitizedCacheSequence(
            [nextHour, secondRich, firstRich, sparse], fetchedAt: base
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.map(\.time), [duplicateTime, nextHour.time])
        XCTAssertNotEqual(forward.first, sparse, "Prefer the duplicate with more usable weather details")
        XCTAssertEqual(forward.first?.radarSamples?.map(\.time), [
            duplicateTime.addingTimeInterval(300), duplicateTime.addingTimeInterval(600)
        ])
    }

    func testForecastWithImplausibleFutureTimestampCanBeReplaced() {
        let now = base
        let future = now.addingTimeInterval(Store.forecastFutureTimestampTolerance + 60)

        XCTAssertTrue(Store.shouldReplaceForecast(existingAt: future, incomingAt: now, now: now))
        XCTAssertFalse(Store.shouldReplaceForecast(
            existingAt: now.addingTimeInterval(60), incomingAt: now, now: now
        ))
    }

    func testWatchTransferPolicyRejectsDuplicateTimestamp() {
        XCTAssertTrue(WatchTransferPolicy.accepts(base.addingTimeInterval(1), after: base))
        XCTAssertFalse(WatchTransferPolicy.accepts(base, after: base))
        XCTAssertFalse(WatchTransferPolicy.accepts(base.addingTimeInterval(-1), after: base))
    }

    func testWatchTransferPolicyBoundsFutureTimestampWithoutPoisoningNextTransfer() {
        let last = base.addingTimeInterval(-60)
        let now = base
        let atTolerance = now.addingTimeInterval(Store.forecastFutureTimestampTolerance)
        let beyondTolerance = atTolerance.addingTimeInterval(1)

        XCTAssertTrue(WatchTransferPolicy.accepts(atTolerance, after: last, now: now))
        XCTAssertFalse(WatchTransferPolicy.accepts(beyondTolerance, after: last, now: now))
        // Rejection is stateless: the caller retains `lastTransferAt`, allowing
        // the next valid transfer to pass instead of inheriting the bad date.
        XCTAssertTrue(WatchTransferPolicy.accepts(now, after: last, now: now))
    }

    func testWatchTransferPolicyRepairsPreviouslyPersistedFutureTimestamp() {
        let now = base
        let corrupted = now.addingTimeInterval(Store.forecastFutureTimestampTolerance + 1)

        XCTAssertEqual(WatchTransferPolicy.restoredTimestamp(corrupted, now: now), .distantPast)
        XCTAssertEqual(WatchTransferPolicy.restoredTimestamp(now, now: now), now)
    }

    func testWatchTransferPolicyRejectsOlderForecastButAllowsNewerAndExplicitClear() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 1, cloud: 20, dew: 4)
        let current = WidgetWeatherSnapshot(place: place, forecast: [hour], updatedAt: base)
        let older = WidgetWeatherSnapshot(
            place: place, forecast: [hour], updatedAt: base.addingTimeInterval(-1)
        )
        let newer = WidgetWeatherSnapshot(
            place: place, forecast: [hour], updatedAt: base.addingTimeInterval(1)
        )

        XCTAssertFalse(WatchTransferPolicy.acceptsSnapshot(older, replacing: current))
        XCTAssertTrue(WatchTransferPolicy.acceptsSnapshot(newer, replacing: current))
        XCTAssertTrue(WatchTransferPolicy.acceptsSnapshot(current, replacing: nil))
        XCTAssertTrue(WatchTransferPolicy.acceptsSnapshot(nil, replacing: current))
    }

    func testWatchRapidTransfersKeepNewestPlaceAndRejectOlderAfterRestart() throws {
        let oldPlace = Place(name: "Klinga", lat: 64, lon: 11)
        let newPlace = Place(name: "Hornburu", lat: 64.1, lon: 11.1)
        let old = WatchWeatherTransfer(
            snapshot: WidgetWeatherSnapshot(place: oldPlace, forecast: forecast(values: [(8, 0, 1, 20, 4)]), updatedAt: base),
            sentAt: base
        )
        let newest = WatchWeatherTransfer(
            snapshot: WidgetWeatherSnapshot(place: newPlace, forecast: forecast(values: [(9, 0, 1, 20, 5)]), updatedAt: base.addingTimeInterval(1)),
            sentAt: base.addingTimeInterval(1)
        )

        let restoredNewest = try JSONDecoder().decode(
            WatchWeatherTransfer.self,
            from: JSONEncoder().encode(newest)
        )
        XCTAssertEqual(restoredNewest.snapshot?.place.id, newPlace.id)
        XCTAssertTrue(WatchTransferPolicy.accepts(restoredNewest.sentAt, after: old.sentAt))
        XCTAssertFalse(WatchTransferPolicy.accepts(old.sentAt, after: restoredNewest.sentAt))
    }

    func testWidgetHourLabelsUseLocalTimeAcrossOsloMidnightAndDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 0)))
        XCTAssertEqual(localHourComponent(midnight, calendar: calendar), 0)
        let beforeJump = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 1)))
        XCTAssertEqual(localHourComponent(beforeJump.addingTimeInterval(3_600), calendar: calendar), 3)
    }

    @MainActor
    func testWidgetFallbackRejectsOtherOrMovedPlaces() {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let cached = WidgetWeatherSnapshot(place: place, forecast: forecast(values: [(10, 0, 1, 10, 5)]), updatedAt: base)
        var moved = place
        moved.lat = 63
        XCTAssertNil(Store.widgetSnapshot(place: moved, forecast: [], updatedAt: nil, cached: cached))
        XCTAssertNil(Store.widgetSnapshot(place: Place(name: "Namsos", lat: 64, lon: 11), forecast: [], updatedAt: nil, cached: cached))
        XCTAssertNil(Store.widgetSnapshot(place: nil, forecast: [], updatedAt: nil, cached: cached))
        XCTAssertNil(Store.widgetSnapshot(place: place, forecast: [], updatedAt: nil, cached: cached, now: base.addingTimeInterval(7 * 3_600)))
        XCTAssertNil(Store.widgetSnapshot(place: place, forecast: cached.forecast, updatedAt: base, cached: cached, now: base.addingTimeInterval(7 * 3_600)))
    }

    @MainActor
    func testPlaceSwitchWithEmptyForecastCannotReusePreviousPlaceSnapshot() {
        let previous = Place(name: "Klinga", lat: 64, lon: 11)
        let next = Place(name: "Namsos", lat: 64.5, lon: 11.5)
        let cached = WidgetWeatherSnapshot(
            place: previous,
            forecast: forecast(values: [(12, 0, 1, 20, 6)]),
            updatedAt: base
        )

        XCTAssertNil(Store.widgetSnapshot(place: next, forecast: [], updatedAt: nil, cached: cached))
    }

    @MainActor
    func testPositionPlaceSwitchWithSameCoordinatesStillRequiresMatchingPlaceID() {
        let saved = Place(name: "Klinga", lat: 64.4, lon: 11.5)
        let currentPosition = Place(name: "Min posisjon", lat: 64.4, lon: 11.5)
        let cached = WidgetWeatherSnapshot(
            place: saved,
            forecast: forecast(values: [(12, 0, 1, 20, 6)]),
            updatedAt: base
        )

        XCTAssertNil(Store.widgetSnapshot(place: currentPosition, forecast: [], updatedAt: nil, cached: cached))
    }

    @MainActor
    func testFreshPositionSnapshotUsesUpdatedPlaceName() throws {
        let position = Place(name: "Min posisjon", lat: 64.4, lon: 11.5)
        let renamed = Place(id: position.id, name: "Klinga", lat: 64.4, lon: 11.5)
        let hours = forecast(values: [(12, 0, 1, 20, 6)])
        let snapshot = try XCTUnwrap(Store.widgetSnapshot(
            place: renamed,
            forecast: hours,
            updatedAt: base.addingTimeInterval(60),
            cached: nil
        ))

        XCTAssertEqual(snapshot.place.displayName, "Klinga")
        XCTAssertEqual(snapshot.place.id, position.id)
    }

    @MainActor
    func testPositionSnapshotPreservesUserDefinedPlaceName() throws {
        var place = Place(name: "Klinga", lat: 64.4, lon: 11.5)
        place.customName = "Hytta"
        let snapshot = try XCTUnwrap(Store.widgetSnapshot(
            place: place,
            forecast: forecast(values: [(12, 0, 1, 20, 6)]),
            updatedAt: base,
            cached: nil
        ))

        XCTAssertEqual(snapshot.place.displayName, "Hytta")
        XCTAssertEqual(snapshot.place.customName, "Hytta")
    }

    @MainActor
    func testWidgetFreshnessUsesElapsedTimeAcrossOsloDSTChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let fetched = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 0, minute: 30))!
        let afterFourElapsedHours = fetched.addingTimeInterval(4 * 3_600)
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let cached = WidgetWeatherSnapshot(place: place, forecast: forecast(values: [(10, 0, 1, 10, 5)]), updatedAt: fetched)

        // The spring-forward hour is not an extra hour of snapshot age.
        XCTAssertNotNil(Store.widgetSnapshot(place: place, forecast: [], updatedAt: nil, cached: cached, now: afterFourElapsedHours))
        XCTAssertNil(Store.widgetSnapshot(place: place, forecast: [], updatedAt: nil, cached: cached, now: fetched.addingTimeInterval(6 * 3_600 + 1)))
    }

    @MainActor
    func testForecastCacheInvalidatesRemovedAndMovedPlaces() {
        let old = Place(name: "Klinga", lat: 64, lon: 11)
        var moved = old
        moved.lon = 12
        XCTAssertEqual(Store.invalidatedForecastIDs(previous: [old], current: [moved]), [old.id])
        XCTAssertEqual(Store.invalidatedForecastIDs(previous: [old], current: []), [old.id])
    }

    @MainActor
    func testForecastCacheSurvivesRenamingReorderingAndRuleEdits() {
        let first = Place(name: "Klinga", lat: 64.409401, lon: 11)
        let second = Place(name: "Namsos", lat: 64.46, lon: 11.49)
        var edited = first
        edited.customName = "Hjemme"
        edited.lat = 64.409402
        edited.rules = [Rule(type: .regn)]
        XCTAssertTrue(Store.invalidatedForecastIDs(previous: [first, second], current: [second, edited]).isEmpty)
    }

    @MainActor
    func testLaunchPlaceMigrationKeepsCustomForecastAndDropsRemovedPlaceCache() throws {
        let persistenceKey = "varsel.test.launch-place-migration-cache.\(UUID().uuidString)"
        let migrationVersionKey = "varsel.launchPlacesVersion"
        let previousVersion = UserDefaults.standard.object(forKey: migrationVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousVersion {
                UserDefaults.standard.set(previousVersion, forKey: migrationVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: migrationVersionKey)
            }
        }

        UserDefaults.standard.set(8, forKey: migrationVersionKey)
        let customPlace = Place(name: "Hytte", lat: 64.2, lon: 11.2, preposition: .pa)
        let removedStandardPlace = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let hour = ForecastHour(time: base, temp: 7, precip: 0, wind: 1, cloud: 40, dew: 3)
        let fetchedAt = base.addingTimeInterval(-1_800)
        let savedState = PersistedStoreState(
            places: [customPlace], selectedID: customPlace.id, log: [],
            forecasts: [customPlace.id: [hour], removedStandardPlace.id: [hour]],
            forecastUpdatedAt: [customPlace.id: fetchedAt, removedStandardPlace.id: fetchedAt]
        )
        UserDefaults.standard.set(try JSONEncoder().encode(savedState), forKey: persistenceKey)

        let migrated = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

        XCTAssertTrue(migrated.places.contains(where: { $0.id == customPlace.id }))
        XCTAssertTrue(migrated.places.contains(where: { $0.name == "Klinga" }))
        XCTAssertEqual(migrated.forecasts[customPlace.id], [hour])
        XCTAssertEqual(migrated.forecastUpdatedAt(for: customPlace.id), fetchedAt)
        XCTAssertNil(migrated.forecasts[removedStandardPlace.id])
        XCTAssertNil(migrated.forecastUpdatedAt(for: removedStandardPlace.id))

        let persistedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repairedState = try JSONDecoder().decode(PersistedStoreState.self, from: persistedData)
        XCTAssertEqual(repairedState.forecasts.keys.sorted(by: { $0.uuidString < $1.uuidString }), [customPlace.id])
        XCTAssertEqual(repairedState.forecastUpdatedAt.keys.sorted(by: { $0.uuidString < $1.uuidString }), [customPlace.id])
    }

    @MainActor
    func testLaunchPlaceMigrationMatchesCaseAndDiacriticVariantWithoutDuplicatingOrLosingCache() throws {
        let persistenceKey = "varsel.test.launch-place-migration-normalized-name.\(UUID().uuidString)"
        let migrationVersionKey = "varsel.launchPlacesVersion"
        let previousVersion = UserDefaults.standard.object(forKey: migrationVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousVersion {
                UserDefaults.standard.set(previousVersion, forKey: migrationVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: migrationVersionKey)
            }
        }

        UserDefaults.standard.set(8, forKey: migrationVersionKey)
        let klinga = Place(name: "KLÍNGA", lat: 64.4094, lon: 11.47786, preposition: .oppa)
        let cabin = Place(name: "Hytte", lat: 64.2, lon: 11.2, preposition: .pa)
        let hour = ForecastHour(time: base, temp: 7, precip: 0, wind: 1, cloud: 40, dew: 3)
        let fetchedAt = base.addingTimeInterval(-1_800)
        let savedState = PersistedStoreState(
            places: [cabin, klinga], selectedID: klinga.id, log: [],
            forecasts: [cabin.id: [hour], klinga.id: [hour]],
            forecastUpdatedAt: [cabin.id: fetchedAt, klinga.id: fetchedAt]
        )
        UserDefaults.standard.set(try JSONEncoder().encode(savedState), forKey: persistenceKey)

        let migrated = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        let matchedPlaces = migrated.places.filter {
            $0.name.compare("Klinga", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }

        XCTAssertEqual(matchedPlaces.count, 1)
        XCTAssertEqual(matchedPlaces.first?.id, klinga.id)
        XCTAssertEqual(migrated.selectedID, klinga.id)
        XCTAssertEqual(migrated.forecasts[klinga.id], [hour])
        XCTAssertEqual(migrated.forecastUpdatedAt(for: klinga.id), fetchedAt)
        XCTAssertEqual(migrated.forecasts[cabin.id], [hour])
        XCTAssertEqual(migrated.forecastUpdatedAt(for: cabin.id), fetchedAt)

        let restarted = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restarted.places.filter {
            $0.name.compare("Klinga", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.map(\.id), [klinga.id])
        XCTAssertEqual(restarted.selectedID, klinga.id)
        XCTAssertEqual(restarted.forecasts[klinga.id], [hour])
        XCTAssertEqual(restarted.forecastUpdatedAt(for: klinga.id), fetchedAt)
    }

    @MainActor
    func testLaunchPlaceMigrationMergesNormalizedDuplicatesAndRepairsSelectionAndCache() throws {
        let persistenceKey = "varsel.test.launch-place-migration-duplicate-name.\(UUID().uuidString)"
        let migrationVersionKey = "varsel.launchPlacesVersion"
        let previousVersion = UserDefaults.standard.object(forKey: migrationVersionKey)
        defer {
            UserDefaults.standard.removeObject(forKey: persistenceKey)
            if let previousVersion {
                UserDefaults.standard.set(previousVersion, forKey: migrationVersionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: migrationVersionKey)
            }
        }

        UserDefaults.standard.set(8, forKey: migrationVersionKey)
        let survivingKlinga = Place(name: "KLÍNGA", lat: 64.4094, lon: 11.47786, preposition: .oppa)
        let mergedKlinga = Place(name: "Klinga", lat: 64.4094, lon: 11.47786, preposition: .pa)
        let cabin = Place(name: "Hytte", lat: 64.2, lon: 11.2, preposition: .pa)
        let survivingHour = ForecastHour(time: base, temp: 7, precip: 0, wind: 1, cloud: 40, dew: 3)
        let mergedHour = ForecastHour(time: base, temp: 2, precip: 0, wind: 2, cloud: 80, dew: 1)
        let cabinHour = ForecastHour(time: base, temp: 9, precip: 0, wind: 0, cloud: 10, dew: 5)
        let fetchedAt = base.addingTimeInterval(-1_800)
        let savedState = PersistedStoreState(
            places: [survivingKlinga, mergedKlinga, cabin], selectedID: mergedKlinga.id, log: [],
            forecasts: [
                survivingKlinga.id: [survivingHour],
                mergedKlinga.id: [mergedHour],
                cabin.id: [cabinHour]
            ],
            forecastUpdatedAt: [
                survivingKlinga.id: fetchedAt,
                mergedKlinga.id: fetchedAt,
                cabin.id: fetchedAt
            ]
        )
        UserDefaults.standard.set(try JSONEncoder().encode(savedState), forKey: persistenceKey)

        let migrated = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        let klingaPlaces = migrated.places.filter {
            $0.name.compare("Klinga", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }

        XCTAssertEqual(klingaPlaces.map(\.id), [survivingKlinga.id])
        XCTAssertEqual(migrated.selectedID, survivingKlinga.id)
        XCTAssertEqual(migrated.forecasts[survivingKlinga.id], [survivingHour])
        XCTAssertEqual(migrated.forecastUpdatedAt(for: survivingKlinga.id), fetchedAt)
        XCTAssertNil(migrated.forecasts[mergedKlinga.id])
        XCTAssertNil(migrated.forecastUpdatedAt(for: mergedKlinga.id))
        XCTAssertEqual(migrated.forecasts[cabin.id], [cabinHour])
        XCTAssertEqual(migrated.forecastUpdatedAt(for: cabin.id), fetchedAt)

        let persistedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repairedState = try JSONDecoder().decode(PersistedStoreState.self, from: persistedData)
        XCTAssertEqual(repairedState.selectedID, survivingKlinga.id)
        XCTAssertEqual(Set(repairedState.forecasts.keys), [survivingKlinga.id, cabin.id])
        XCTAssertEqual(Set(repairedState.forecastUpdatedAt.keys), [survivingKlinga.id, cabin.id])

        let restarted = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restarted.selectedID, survivingKlinga.id)
        XCTAssertNil(restarted.forecasts[mergedKlinga.id])
        XCTAssertEqual(restarted.forecasts[cabin.id], [cabinHour])
    }

    @MainActor
    func testPreservedAndNewNotificationsShareChronologicalCapacity() {
        let dates = (0..<80).reversed().map { (id: "request-\($0)", date: base.addingTimeInterval(Double($0))) }
        let ids = NotificationScheduler.nearestRequestIDs(dates)
        XCTAssertEqual(ids.count, 64)
        XCTAssertTrue(ids.contains("request-0"))
        XCTAssertTrue(ids.contains("request-63"))
        XCTAssertFalse(ids.contains("request-64"))
    }

    func testNotificationCapacityBreaksEqualTimesByStableID() {
        let sameTime = base.addingTimeInterval(3_600)
        let dates = (0..<70).map { index in
            (id: String(format: "place-%02d", index), date: sameTime)
        }.reversed()
        let ids = NotificationScheduler.nearestRequestIDs(Array(dates))
        XCTAssertEqual(ids.count, 64)
        XCTAssertTrue(ids.contains("place-00"))
        XCTAssertTrue(ids.contains("place-63"))
        XCTAssertFalse(ids.contains("place-64"))
    }

    func testFailedNotificationReplacementKeepsExistingRequest() {
        let stale = NotificationScheduler.stalePendingRequestIDs(
            pendingIDs: ["old", "replace", "preserved"],
            preservedIDs: ["preserved"], successfulIDs: ["new"], failedIDs: ["replace"]
        )
        XCTAssertEqual(stale, ["old"])
    }

    func testStaleCleanupKeepsFutureNotificationRequests() {
        let past = UNNotificationRequest(identifier: "past", content: UNMutableNotificationContent(), trigger: nil)
        let future = UNNotificationRequest(identifier: "future", content: UNMutableNotificationContent(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3_600, repeats: false))
        let stale = NotificationScheduler.stalePendingRequestIDs(
            pendingIDs: [past.identifier, future.identifier], preservedIDs: [],
            successfulIDs: [future.identifier], failedIDs: []
        )
        XCTAssertEqual(stale, [past.identifier])
    }

    @MainActor
    func testFailedReplacementFallbackRequiresMatchingPlanContext() throws {
        let rule = Rule(type: .regn)
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let context = try JSONEncoder().encode(NotificationPlanContext(place: place, rule: rule, languageStyle: .bokmal))
        let content = UNMutableNotificationContent()
        content.userInfo[NotificationScheduler.planContextKey] = context
        let request = UNNotificationRequest(identifier: "same", content: content, trigger: nil)

        XCTAssertEqual(
            NotificationScheduler.failedReplacementFallbackIDs(
                pending: [request], failedIDs: ["same"], replacementContexts: ["same": context]
            ), ["same"]
        )
        XCTAssertTrue(NotificationScheduler.failedReplacementFallbackIDs(
            pending: [request], failedIDs: ["same"], replacementContexts: ["same": Data("other".utf8)]
        ).isEmpty)
    }

    @MainActor
    func testInjectedNotificationCenterKeepsFailedReplacement() async {
        let rule = Rule(type: .regn)
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let fireAt = Date().addingTimeInterval(3_600)
        let alert = PlannedAlert(
            rule: rule, placeID: place.id, placeName: place.nameWithPreposition,
            eventAt: fireAt, fireAt: fireAt, index: 1, total: 1,
            quiet: false, possible: false, eventDetail: nil
        )
        let old = UNNotificationRequest(
            identifier: alert.id, content: UNMutableNotificationContent(),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3_600, repeats: false)
        )
        let center = FakeNotificationCenter(pending: [old])
        center.failedIDs = [alert.id]

        let result = await NotificationScheduler.replacePendingAlerts(
            [alert], languageStyle: .bokmal, places: [place],
            missingForecastPlaceIDs: [], nearbyPlaceIDs: [], center: center
        )

        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(center.pending.map(\.identifier), [alert.id])
    }

    @MainActor
    func testCancelledNotificationReplacementRetainsOnlyUnattemptedCurrentRequest() async throws {
        let firstRule = Rule(type: .regn)
        let secondRule = Rule(type: .vind)
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [firstRule, secondRule])
        let firstFireAt = Date().addingTimeInterval(3_600)
        let secondFireAt = Date().addingTimeInterval(7_200)
        let alerts = [
            PlannedAlert(rule: firstRule, placeID: place.id, placeName: place.nameWithPreposition,
                         eventAt: firstFireAt, fireAt: firstFireAt, index: 1, total: 1,
                         quiet: false, possible: false, eventDetail: nil),
            PlannedAlert(rule: secondRule, placeID: place.id, placeName: place.nameWithPreposition,
                         eventAt: secondFireAt, fireAt: secondFireAt, index: 1, total: 1,
                         quiet: false, possible: false, eventDetail: nil)
        ]
        func existingRequest(for alert: PlannedAlert) throws -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.userInfo[NotificationScheduler.planContextKey] = try JSONEncoder().encode(
                NotificationPlanContext(place: place, rule: alert.rule, languageStyle: .bokmal)
            )
            return UNNotificationRequest(
                identifier: alert.id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3_600, repeats: false)
            )
        }
        let firstOld = try existingRequest(for: alerts[0])
        let secondOld = try existingRequest(for: alerts[1])
        let obsolete = UNNotificationRequest(
            identifier: "obsolete", content: UNMutableNotificationContent(),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5_400, repeats: false)
        )
        let center = FakeNotificationCenter(pending: [firstOld, secondOld, obsolete])
        var schedulingTask: Task<NotificationScheduleResult, Never>?
        center.afterAdd = { schedulingTask?.cancel() }

        schedulingTask = Task {
            await NotificationScheduler.replacePendingAlerts(
                alerts, languageStyle: .bokmal, places: [place],
                missingForecastPlaceIDs: [], nearbyPlaceIDs: [], center: center
            )
        }
        let task = try XCTUnwrap(schedulingTask)
        let result = await task.value

        XCTAssertEqual(result.scheduledCount, 1)
        XCTAssertEqual(Set(center.pending.map(\.identifier)), Set([alerts[0].id, alerts[1].id]))
        XCTAssertFalse(center.pending.contains { $0.identifier == "obsolete" })
    }

    @MainActor
    func testOfflineNotificationPreservationRequiresUnchangedActiveRule() throws {
        let rule = Rule(type: .regn)
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let content = UNMutableNotificationContent()
        content.userInfo[NotificationScheduler.planContextKey] = try JSONEncoder().encode(
            NotificationPlanContext(place: place, rule: rule, languageStyle: .bokmal)
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: base), repeats: false
        )
        let request = UNNotificationRequest(identifier: "offline", content: content, trigger: trigger)
        func preserved(_ current: Place, missing: Set<UUID>? = nil, nearby: Set<UUID> = []) -> [UNNotificationRequest] {
            NotificationScheduler.requestsToPreserve(
                [request], places: [current], missingForecastPlaceIDs: missing ?? [place.id],
                nearbyPlaceIDs: nearby, languageStyle: .bokmal, now: base.addingTimeInterval(-3600)
            )
        }
        XCTAssertEqual(preserved(place).map(\.identifier), ["offline"])
        XCTAssertTrue(preserved(place, missing: []).isEmpty)
        var changed = place
        changed.rules[0].threshold += 1
        XCTAssertTrue(preserved(changed).isEmpty)
        changed = place
        changed.notificationsEnabled = false
        XCTAssertTrue(preserved(changed).isEmpty)
        changed = place
        changed.rules[0].enabled = false
        XCTAssertTrue(preserved(changed).isEmpty)
        changed = place
        changed.lat += 1
        XCTAssertTrue(preserved(changed).isEmpty)
        XCTAssertTrue(NotificationScheduler.requestsToPreserve(
            [request], places: [], missingForecastPlaceIDs: [place.id], nearbyPlaceIDs: [],
            languageStyle: .bokmal, now: base.addingTimeInterval(-3600)
        ).isEmpty)
        XCTAssertTrue(NotificationScheduler.requestsToPreserve(
            [request], places: [place], missingForecastPlaceIDs: [place.id], nearbyPlaceIDs: [],
            languageStyle: .inntrondersk, now: base.addingTimeInterval(-3600)
        ).isEmpty)
        XCTAssertTrue(NotificationScheduler.requestsToPreserve(
            [request], places: [place], missingForecastPlaceIDs: [place.id], nearbyPlaceIDs: [],
            languageStyle: .bokmal, now: base.addingTimeInterval(3600)
        ).isEmpty)
    }

    @MainActor
    func testOfflineNotificationPreservationUsesDeterministicFireDates() throws {
        let rule = Rule(type: .regn)
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        func request(_ identifier: String) throws -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.userInfo[NotificationScheduler.planContextKey] = try JSONEncoder().encode(
                NotificationPlanContext(place: place, rule: rule, languageStyle: .bokmal)
            )
            return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        }
        let future = try request("future")
        let expired = try request("expired")
        let expected = base.addingTimeInterval(900)

        let preserved = NotificationScheduler.requestsToPreserve(
            [expired, future], places: [place], missingForecastPlaceIDs: [place.id],
            nearbyPlaceIDs: [], languageStyle: .bokmal, now: base,
            resolveFireDate: { $0.identifier == "future" ? expected : base }
        )

        XCTAssertEqual(preserved.map(\.identifier), ["future"])
    }

    @MainActor
    func testOfflineNotificationPreservationKeepsNearest64Requests() throws {
        let rule = Rule(type: .regn)
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let context = try JSONEncoder().encode(
            NotificationPlanContext(place: place, rule: rule, languageStyle: .bokmal)
        )
        var fireDates: [String: Date] = [:]
        let requests = (0..<70).map { index -> UNNotificationRequest in
            let identifier = String(format: "offline-%02d", index)
            fireDates[identifier] = base.addingTimeInterval(Double(index + 1) * 60)
            let content = UNMutableNotificationContent()
            content.userInfo[NotificationScheduler.planContextKey] = context
            return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        }

        let preserved = NotificationScheduler.requestsToPreserve(
            Array(requests.reversed()), places: [place], missingForecastPlaceIDs: [place.id],
            nearbyPlaceIDs: [], languageStyle: .bokmal, now: base,
            resolveFireDate: { fireDates[$0.identifier] }
        )

        XCTAssertEqual(preserved.count, 64)
        XCTAssertEqual(preserved.map(\.identifier), (0..<64).map { String(format: "offline-%02d", $0) })
    }

    @MainActor
    func testReplanAppliesNotificationLimitAcrossPreservedAndNewRequests() async throws {
        let rule = Rule(type: .regn)
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let context = try JSONEncoder().encode(
            NotificationPlanContext(place: place, rule: rule, languageStyle: .bokmal)
        )
        let now = Date()
        let preservedRequests = (0..<10).map { index in
            let content = UNMutableNotificationContent()
            content.userInfo[NotificationScheduler.planContextKey] = context
            return UNNotificationRequest(
                identifier: String(format: "offline-%02d", index), content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(index + 1) * 60, repeats: false)
            )
        }
        let newAlerts = (0..<70).map { index in
            let fireAt = now.addingTimeInterval(Double(index + 2) * 60)
            return PlannedAlert(
                rule: rule, placeID: place.id, placeName: place.nameWithPreposition,
                eventAt: fireAt, fireAt: fireAt, index: index, total: 70,
                quiet: false, possible: false, eventDetail: nil
            )
        }
        let expectedIDs = Set((0..<10).map { String(format: "offline-%02d", $0) }
            + newAlerts.prefix(54).map(\.id))

        func scheduledIDs(pending: [UNNotificationRequest], alerts: [PlannedAlert]) async -> Set<String> {
            let center = FakeNotificationCenter(pending: pending)
            let result = await NotificationScheduler.replacePendingAlerts(
                alerts, languageStyle: .bokmal, places: [place],
                missingForecastPlaceIDs: [place.id], nearbyPlaceIDs: [], center: center
            )
            XCTAssertEqual(result.requestedCount, 64)
            XCTAssertEqual(result.scheduledCount, 64)
            XCTAssertEqual(result.failedCount, 0)
            return Set(center.pending.map(\.identifier))
        }

        let forward = await scheduledIDs(pending: preservedRequests, alerts: newAlerts)
        let reversed = await scheduledIDs(pending: Array(preservedRequests.reversed()), alerts: Array(newAlerts.reversed()))

        XCTAssertEqual(forward, expectedIDs)
        XCTAssertEqual(reversed, expectedIDs)
    }

    @MainActor
    func testOfflinePreservationRetainsRouteWhenPlacesAreReordered() throws {
        let rule = Rule(type: .regn)
        let target = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let other = Place(name: "Namsos", lat: 64.46, lon: 11.49)
        let content = UNMutableNotificationContent()
        content.userInfo[NotificationRoute.placeIDKey] = target.id.uuidString
        content.userInfo[NotificationScheduler.planContextKey] = try JSONEncoder().encode(
            NotificationPlanContext(place: target, rule: rule, languageStyle: .bokmal)
        )
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3_600, repeats: false)
        let request = UNNotificationRequest(identifier: "offline-route", content: content, trigger: trigger)

        let preserved = NotificationScheduler.requestsToPreserve(
            [request], places: [other, target], missingForecastPlaceIDs: [target.id],
            nearbyPlaceIDs: [], languageStyle: .bokmal, now: base
        )

        XCTAssertEqual(preserved.first?.content.userInfo[NotificationRoute.placeIDKey] as? String, target.id.uuidString)
    }

    @MainActor
    func testOfflineNotificationPreservationRejectsUnverifiableRequests() {
        let request = UNNotificationRequest(identifier: "legacy", content: UNMutableNotificationContent(), trigger: nil)
        XCTAssertTrue(NotificationScheduler.requestsToPreserve(
            [request], places: [], missingForecastPlaceIDs: [], nearbyPlaceIDs: [],
            languageStyle: .bokmal, now: base
        ).isEmpty)
    }

    @MainActor
    func testTotalForecastFailureDoesNotFinalizeRefresh() {
        XCTAssertFalse(Store.shouldFinalizeRefresh(successfulPlaceCount: 0, failedPlaceCount: 1))
        XCTAssertFalse(Store.shouldFinalizeRefresh(successfulPlaceCount: 0, failedPlaceCount: 5))
    }

    func testForecastUsabilityRequiresThreeDistinctHoursOfRemainingCoverage() {
        let minimum = makeForecast(through: 2, precipitationOffsets: [])
        let truncated = Array(minimum.prefix(2))
        let duplicates = [minimum[0], minimum[0], minimum[2]]
        let interrupted = [minimum[0], minimum[1], ForecastHour(
            time: minimum[2].time.addingTimeInterval(12 * 3_600), temp: 8,
            precip: 0, wind: 1, cloud: 60, dew: 7
        )]
        let startsTooLate = makeForecast(through: 2, startingAt: base.addingTimeInterval(7 * 3_600), precipitationOffsets: [])
        let expired = makeForecast(through: 2, startingAt: base.addingTimeInterval(-3 * 3_600), precipitationOffsets: [])

        XCTAssertFalse(Store.isUsableForecast([], now: base))
        XCTAssertFalse(Store.isUsableForecast(truncated, now: base))
        XCTAssertFalse(Store.isUsableForecast(duplicates, now: base))
        XCTAssertFalse(Store.isUsableForecast(interrupted, now: base))
        XCTAssertFalse(Store.isUsableForecast(startsTooLate, now: base))
        XCTAssertFalse(Store.isUsableForecast(expired, now: base))
        XCTAssertTrue(Store.isUsableForecast(minimum, now: base))
        XCTAssertTrue(Store.isUsableForecast(makeForecast(through: 8, precipitationOffsets: []), now: base))
    }

    func testManualPlaceRefreshRejectsEmptyYrResponseBeforeCaching() {
        XCTAssertFalse(Store.isUsableForecast([]), "Tomt Yr-svar skal ikke bli ny cache")
    }

    @MainActor
    func testShortForecastRefreshPreservesLastValidSnapshot() async throws {
        let persistenceKey = "varsel.test.short-forecast-refresh.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let place = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let oldForecast = makeForecast(through: 5, startingAt: Date().addingTimeInterval(-12 * 3_600), precipitationOffsets: [])
        let oldUpdatedAt = Date().addingTimeInterval(-3 * 3_600)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [place], selectedID: place.id, log: [],
            forecasts: [place.id: oldForecast],
            forecastUpdatedAt: [place.id: oldUpdatedAt], lastUpdate: oldUpdatedAt
        )), forKey: persistenceKey)
        let now = Date()
        let truncated = makeForecast(through: 1, startingAt: now, precipitationOffsets: [])
        let store = Store(
            forecastFetcher: { _, _ in truncated },
            persistenceKey: persistenceKey
        )

        let refreshSucceeded = await store.refreshAll()
        XCTAssertFalse(refreshSucceeded)
        XCTAssertEqual(store.forecasts[place.id], oldForecast)
        XCTAssertEqual(store.forecastUpdatedAt(for: place.id), oldUpdatedAt)
    }

    @MainActor
    func testAddingPlacePersistsSelectionBeforeOfflineForecastFailure() async throws {
        let persistenceKey = "varsel.test.add-offline-place.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let store = Store(
            forecastFetcher: { _, _ in throw URLError(.notConnectedToInternet) },
            persistenceKey: persistenceKey
        )
        let place = Place(name: "Hytte", lat: 64.0, lon: 11.0, preposition: .pa)

        await store.add(place)

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: data)
        XCTAssertEqual(persisted.places.map(\.id), [place.id])
        XCTAssertEqual(persisted.selectedID, place.id)
        XCTAssertNotNil(store.forecastErrors[place.id])

        let restored = Store(
            forecastFetcher: { _, _ in throw URLError(.notConnectedToInternet) },
            persistenceKey: persistenceKey
        )
        XCTAssertTrue(restored.places.contains(where: { $0.id == place.id }))
        XCTAssertEqual(restored.selectedID, place.id)
    }

    @MainActor
    func testCorruptedStoreBytesAreReplacedWithStableLaunchPlaces() throws {
        let persistenceKey = "varsel.test.corrupted-store-bytes.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let recoveryPrefix = Store.unreadableStoreStateRecoveryKeyPrefix(for: persistenceKey)
        let originalData = Data([0xFF, 0x00, 0x7B, 0xC3])
        defer {
            defaults.removeObject(forKey: persistenceKey)
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(recoveryPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(originalData, forKey: persistenceKey)

        let recovered = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        let recoveredIDs = recovered.places.map(\.id)
        XCTAssertFalse(recovered.places.isEmpty)
        XCTAssertEqual(recovered.selectedID, recovered.places.first?.id)

        let repairedData = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let repairedState = try JSONDecoder().decode(PersistedStoreState.self, from: repairedData)
        XCTAssertEqual(repairedState.places.map(\.id), recoveredIDs)
        XCTAssertEqual(repairedState.selectedID, recovered.selectedID)
        let recoveryKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(recoveryPrefix) }
        XCTAssertEqual(recoveryKeys.count, 1)
        XCTAssertEqual(defaults.data(forKey: try XCTUnwrap(recoveryKeys.first)), originalData)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.places.map(\.id), recoveredIDs)
        XCTAssertEqual(restored.selectedID, recovered.selectedID)
    }

    @MainActor
    func testEmptyPersistedStorePlacesArePreservedBeforeLaunchFallback() throws {
        let persistenceKey = "varsel.test.empty-store-places.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let recoveryPrefix = Store.unreadableStoreStateRecoveryKeyPrefix(for: persistenceKey)
        let originalData = try JSONEncoder().encode(PersistedStoreState(places: [], selectedID: nil, log: []))
        defer {
            defaults.removeObject(forKey: persistenceKey)
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(recoveryPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(originalData, forKey: persistenceKey)

        let recovered = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)

        XCTAssertFalse(recovered.places.isEmpty)
        let recoveryKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(recoveryPrefix) }
        XCTAssertEqual(recoveryKeys.count, 1)
        XCTAssertEqual(defaults.data(forKey: try XCTUnwrap(recoveryKeys.first)), originalData)
        let repairedData = try XCTUnwrap(defaults.data(forKey: persistenceKey))
        XCTAssertFalse(try JSONDecoder().decode(PersistedStoreState.self, from: repairedData).places.isEmpty)
    }

    @MainActor
    func testCancelledAddingPlaceKeepsPersistedSelectionWithoutForecastOrNetworkError() async throws {
        let persistenceKey = "varsel.test.add-cancelled-place.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let fetchStarted = expectation(description: "First forecast fetch started")
        let place = Place(name: "Hytte", lat: 64.0, lon: 11.0, preposition: .pa)
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 40, dew: 4)
        let store = Store(
            forecastFetcher: { _, _ in
                fetchStarted.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return [hour]
            },
            persistenceKey: persistenceKey
        )
        let addTask = Task { @MainActor in await store.add(place) }
        await fulfillment(of: [fetchStarted], timeout: 5)

        addTask.cancel()
        await addTask.value

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: data)
        XCTAssertTrue(persisted.places.contains(where: { $0.id == place.id }))
        XCTAssertEqual(persisted.selectedID, place.id)
        XCTAssertTrue(persisted.forecasts[place.id, default: []].isEmpty)
        XCTAssertNil(persisted.forecastUpdatedAt[place.id])
        XCTAssertNil(store.forecastErrors[place.id], "Cancellation must not be shown as a network failure")

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertTrue(restored.places.contains(where: { $0.id == place.id }))
        XCTAssertEqual(restored.selectedID, place.id)
        XCTAssertTrue(restored.forecasts[place.id, default: []].isEmpty)
        XCTAssertNil(restored.forecastErrors[place.id])
    }

    @MainActor
    func testAddingPlacePersistsSelectionWhenFirstForecastIsEmpty() async throws {
        let persistenceKey = "varsel.test.add-empty-forecast-place.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let store = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        let place = Place(name: "Hytte", lat: 64.0, lon: 11.0, preposition: .pa)

        await store.add(place)

        XCTAssertTrue(store.places.contains(where: { $0.id == place.id }))
        XCTAssertEqual(store.selectedID, place.id)
        XCTAssertTrue(store.forecasts[place.id, default: []].isEmpty)

        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertTrue(restored.places.contains(where: { $0.id == place.id }))
        XCTAssertEqual(restored.selectedID, place.id)
        XCTAssertTrue(restored.forecasts[place.id, default: []].isEmpty)
    }

    @MainActor
    func testAddingPlacePersistsSuccessfulFirstForecastAndTimestamp() async throws {
        let persistenceKey = "varsel.test.add-successful-forecast-place.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let hours = makeForecast(through: 2, precipitationOffsets: [])
        let store = Store(forecastFetcher: { _, _ in hours }, persistenceKey: persistenceKey)
        let place = Place(name: "Hytte", lat: 64.0, lon: 11.0, preposition: .pa)

        await store.add(place)

        XCTAssertEqual(store.forecasts[place.id], hours)
        XCTAssertNotNil(store.forecastUpdatedAt(for: place.id))
        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.forecasts[place.id], hours)
        XCTAssertNotNil(restored.forecastUpdatedAt(for: place.id))
        XCTAssertEqual(restored.selectedID, place.id)
    }

    @MainActor
    func testAddingPlaceDoesNotRestoreSelectionAfterUserChangesItDuringFetch() async throws {
        let persistenceKey = "varsel.test.add-place-selection-race.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        var resumeFetch: CheckedContinuation<[ForecastHour], Error>?
        let fetchStarted = expectation(description: "New place forecast fetch started")
        let hour = ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 40, dew: 4)
        let store = Store(
            forecastFetcher: { _, _ in
                try await withCheckedThrowingContinuation { continuation in
                    resumeFetch = continuation
                    fetchStarted.fulfill()
                }
            },
            persistenceKey: persistenceKey
        )
        let newPlace = Place(name: "Hytte", lat: 64.0, lon: 11.0, preposition: .pa)
        let task = Task { @MainActor in await store.add(newPlace) }
        await fulfillment(of: [fetchStarted], timeout: 5)

        let otherPlace = try XCTUnwrap(store.places.first(where: { $0.id != newPlace.id }))
        store.select(otherPlace)
        resumeFetch?.resume(returning: [hour])
        await task.value

        XCTAssertEqual(store.selectedID, otherPlace.id)
        XCTAssertEqual(store.forecasts[newPlace.id], [hour])
    }

    @MainActor
    func testAddingPlacePreservesOtherPlacesForecastCache() async throws {
        let persistenceKey = "varsel.test.add-place-preserves-other-cache.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let existing = Place(name: "Klinga", lat: 64.4, lon: 11.4)
        let oldHour = ForecastHour(time: base, temp: 3, precip: 0, wind: 1, cloud: 80, dew: 1)
        let oldUpdatedAt = base.addingTimeInterval(-3_600)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [existing], selectedID: existing.id, log: [],
            forecasts: [existing.id: [oldHour]],
            forecastUpdatedAt: [existing.id: oldUpdatedAt], lastUpdate: oldUpdatedAt
        )), forKey: persistenceKey)
        let newForecast = makeForecast(through: 2, startingAt: base.addingTimeInterval(3_600), precipitationOffsets: [])
        let store = Store(forecastFetcher: { _, _ in newForecast }, persistenceKey: persistenceKey)
        let added = Place(name: "Hytte", lat: 64.0, lon: 11.0, preposition: .pa)

        await store.add(added)

        XCTAssertEqual(store.forecasts[existing.id], [oldHour])
        XCTAssertEqual(store.forecasts[added.id], newForecast)
        XCTAssertEqual(store.forecastUpdatedAt(for: existing.id), oldUpdatedAt)
        XCTAssertNotNil(store.forecastUpdatedAt(for: added.id))
        let restored = Store(forecastFetcher: { _, _ in [] }, persistenceKey: persistenceKey)
        XCTAssertEqual(restored.forecasts[existing.id], [oldHour])
        XCTAssertEqual(restored.forecasts[added.id], newForecast)
        XCTAssertEqual(restored.forecastUpdatedAt(for: existing.id), oldUpdatedAt)
        XCTAssertNotNil(restored.forecastUpdatedAt(for: added.id))
    }

    func testEmptyForecastCreatesNoSnowAlert() {
        let rule = Rule(type: .sno)
        let result = Planner.plan(rule: rule, forecast: [], placeName: "Klinga", now: base)
        XCTAssertTrue(result.alerts.isEmpty)
        XCTAssertNil(result.eventAt)
    }

    @MainActor
    func testSuccessfulAndIntentionallyEmptyRefreshCanFinalize() {
        XCTAssertTrue(Store.shouldFinalizeRefresh(successfulPlaceCount: 3, failedPlaceCount: 0))
        XCTAssertTrue(Store.shouldFinalizeRefresh(successfulPlaceCount: 1, failedPlaceCount: 2))
        XCTAssertTrue(Store.shouldFinalizeRefresh(successfulPlaceCount: 0, failedPlaceCount: 0))
    }

    func testPartialMultiPlaceRefreshFinalizesWithoutTreatingFailuresAsEmptyData() {
        // At least one successful place allows the new cache entries to be
        // saved; failed places retain their prior forecasts instead of being
        // replaced with an empty response.
        XCTAssertTrue(Store.shouldFinalizeRefresh(successfulPlaceCount: 1, failedPlaceCount: 1))
        XCTAssertFalse(Store.shouldFinalizeRefresh(successfulPlaceCount: 0, failedPlaceCount: 1))
    }

    @MainActor
    func testPartialRefreshPersistsSuccessfulForecastBeforeReplanningCompletes() async throws {
        let persistenceKey = "varsel.test.partial-refresh.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }

        let successful = Place(name: "Svarer", lat: 64.0, lon: 11.0)
        let failing = Place(name: "Feiler", lat: 65.0, lon: 11.0)
        let fetchedForecast = makeForecast(through: 2, precipitationOffsets: [])
        let oldHour = ForecastHour(time: base, temp: 2, precip: 0, wind: 1, cloud: 90, dew: 0)
        let oldUpdate = Date().addingTimeInterval(-3 * 3_600)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [successful, failing], selectedID: successful.id, log: [],
            forecasts: [failing.id: [oldHour]],
            forecastUpdatedAt: [failing.id: oldUpdate], lastUpdate: oldUpdate
        )), forKey: persistenceKey)
        let store = Store(
            forecastFetcher: { latitude, _ in
                if latitude < 64.5 { return fetchedForecast }
                throw URLError(.notConnectedToInternet)
            },
            persistenceKey: persistenceKey
        )
        store.places = [successful, failing]
        store.selectedID = successful.id

        // A failed sibling still makes the overall result false, but the
        // successful cache must survive the subsequent notification replan.
        let refreshSucceeded = await store.refreshAll()
        XCTAssertFalse(refreshSucceeded)
        XCTAssertEqual(store.forecasts[successful.id], fetchedForecast)
        XCTAssertEqual(store.forecasts[failing.id], [oldHour])
        XCTAssertEqual(store.forecastUpdatedAt(for: failing.id), oldUpdate)
        XCTAssertTrue(Store.isForecastStale(store.forecastUpdatedAt(for: failing.id)))
        XCTAssertFalse(Store.isForecastStale(store.forecastUpdatedAt(for: successful.id)))

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: data)
        XCTAssertEqual(persisted.forecasts[successful.id], fetchedForecast)
        XCTAssertEqual(persisted.forecasts[failing.id], [oldHour])
        XCTAssertEqual(persisted.forecastUpdatedAt[failing.id], oldUpdate)
    }

    func testReplanDebounceRequiresSameStateAndShortInterval() {
        XCTAssertTrue(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 7, lastAt: base, now: base.addingTimeInterval(4)))
        XCTAssertFalse(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 8, lastAt: base, now: base.addingTimeInterval(1)))
        XCTAssertFalse(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 7, lastAt: base, now: base.addingTimeInterval(5)))
    }

    @MainActor
    func testChangingCachedPlaceTemperatureOffsetReplansWithoutFetchingOrMutatingOtherPlace() async throws {
        let persistenceKey = "varsel.test.cached-place-temperature-offset." + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let now = Date()
        let fetchCounter = ForecastFetchCounter()
        var targetRule = Rule(type: .temperatur)
        targetRule.temperatureDirection = .above
        targetRule.threshold = 10
        var otherRule = Rule(type: .temperatur)
        otherRule.temperatureDirection = .above
        otherRule.threshold = 10
        let target = Place(name: "Målsted", lat: 64, lon: 11, rules: [targetRule])
        let other = Place(name: "Annet sted", lat: 63, lon: 10, rules: [otherRule])
        let targetForecast = makeForecast(
            through: 5, startingAt: now.addingTimeInterval(4 * 3_600), precipitationOffsets: []
        )
        let otherForecast = targetForecast
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [target, other], selectedID: target.id, log: [],
            forecasts: [target.id: targetForecast, other.id: otherForecast],
            forecastUpdatedAt: [target.id: now, other.id: now], lastUpdate: now
        )), forKey: persistenceKey)

        var scheduledAlerts: [PlannedAlert] = []
        let store = Store(
            forecastFetcher: { _, _ in
                await fetchCounter.increment()
                return []
            },
            persistenceKey: persistenceKey,
            notificationRescheduler: { alerts, _, _, _, _ in
                scheduledAlerts = alerts
                return NotificationScheduleResult(
                    requestedCount: alerts.count, scheduledCount: alerts.count,
                    failedCount: 0, firstScheduledAt: alerts.first?.fireAt
                )
            }
        )

        var calibratedTarget = try XCTUnwrap(store.places.first { $0.id == target.id })
        calibratedTarget.temperatureOffset = 3
        store.update(calibratedTarget)
        await store.replan()

        XCTAssertNotNil(scheduledAlerts.first { $0.placeID == target.id })
        XCTAssertFalse(scheduledAlerts.contains { $0.placeID == other.id })
        XCTAssertEqual(store.forecasts[target.id]?.first?.temp, 11)
        XCTAssertEqual(store.forecasts[target.id]?.first?.yrTemperature, 8)
        XCTAssertEqual(store.forecasts[other.id]?.first?.temp, 8)
        XCTAssertNil(store.forecasts[other.id]?.first?.yrTemperature)
        let fetchCount = await fetchCounter.value()
        XCTAssertEqual(fetchCount, 0, "Replanning cached data must not fetch from Yr")
    }

    @MainActor
    func testFailedReplanCanRetrySamePlanAndSuccessfulRetryIsDebounced() async {
        var schedulingAttempts = 0
        let store = Store(
            forecastFetcher: { _, _ in [] },
            persistenceKey: "varsel.test.replan-retry.\(UUID().uuidString)",
            notificationRescheduler: { _, _, _, _, _ in
                schedulingAttempts += 1
                return schedulingAttempts == 1
                    ? NotificationScheduleResult(requestedCount: 2, scheduledCount: 1, failedCount: 1, firstScheduledAt: self.base)
                    : NotificationScheduleResult(requestedCount: 1, scheduledCount: 1, failedCount: 0, firstScheduledAt: self.base)
            }
        )

        await store.replan()
        await store.replan()
        XCTAssertEqual(schedulingAttempts, 2, "A failed replacement must not debounce an unchanged retry")

        await store.replan()
        XCTAssertEqual(schedulingAttempts, 2, "A successful retry should restore normal debounce")
    }

    @MainActor
    func testCancelledReplanDuringSchedulingDoesNotLogAndCanRetry() async {
        let schedulingStarted = expectation(description: "Notification scheduling started")
        var schedulingAttempts = 0
        let store = Store(
            forecastFetcher: { _, _ in [] },
            persistenceKey: "varsel.test.replan-cancel.\(UUID().uuidString)",
            notificationRescheduler: { _, _, _, _, _ in
                schedulingAttempts += 1
                if schedulingAttempts == 1 {
                    schedulingStarted.fulfill()
                    try? await Task.sleep(for: .seconds(60))
                }
                return NotificationScheduleResult(
                    requestedCount: 1, scheduledCount: 1, failedCount: 0,
                    firstScheduledAt: self.base
                )
            }
        )

        let replanTask = Task { await store.replan() }
        await fulfillment(of: [schedulingStarted], timeout: 5)
        replanTask.cancel()
        await replanTask.value

        XCTAssertTrue(store.log.isEmpty, "A cancelled replan must not report completion")
        await store.replan()
        XCTAssertEqual(schedulingAttempts, 2, "Cancellation must release this replan's debounce guard")
    }

    func testNotificationPermissionRequestDistinguishesDenialFromFailure() async {
        let denied = await NotificationScheduler.requestPermission { false }
        let failed = await NotificationScheduler.requestPermission {
            throw URLError(.timedOut)
        }

        XCTAssertEqual(denied, Optional(false))
        XCTAssertNil(failed, "A system error is unknown, not an explicit denial")
    }

    func testRotatingHomeHorizonStopsAtEighteenHours() {
        XCTAssertTrue(Planner.isWithinRotatingHomeHorizon(base.addingTimeInterval(18 * 60 * 60), now: base))
        XCTAssertFalse(Planner.isWithinRotatingHomeHorizon(base.addingTimeInterval(18 * 60 * 60 + 1), now: base))
    }

    func testMorningBandsKeepThreeCalendarDaysWithoutRotatingHorizon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 5, day: 10, hour: 6)))
        let hours = [
            ForecastHour(time: now.addingTimeInterval(-7 * 3_600), temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4),
            ForecastHour(time: now, temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4),
            ForecastHour(time: now.addingTimeInterval(24 * 3_600), temp: 9, precip: 0, wind: 1, cloud: 30, dew: 4),
            ForecastHour(time: now.addingTimeInterval(48 * 3_600), temp: 10, precip: 0, wind: 1, cloud: 30, dew: 4),
            ForecastHour(time: now.addingTimeInterval(72 * 3_600), temp: 11, precip: 0, wind: 1, cloud: 30, dew: 4),
        ]
        let visible = ForecastDaySelection.visibleDays(
            from: ForecastDay.make(from: hours, calendar: calendar), now: now, calendar: calendar
        )
        XCTAssertEqual(visible.map(\.date), [
            calendar.startOfDay(for: now),
            calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
            calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)),
        ])
    }

    func testForecastDayRemovesExactTimestampDuplicatesBeforeTimeCardSampling() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 5, day: 10)))
        let atEight = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day))
        let atNine = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day))
        let atTen = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day))
        let firstEight = ForecastHour(time: atEight, temp: 6, precip: 0, wind: 1, cloud: 20, dew: 2)
        let conflictingEight = ForecastHour(time: atEight, temp: 99, precip: 4, wind: 9, cloud: 90, dew: 8)
        let nine = ForecastHour(time: atNine, temp: 9, precip: 0, wind: 1, cloud: 30, dew: 3)
        let ten = ForecastHour(time: atTen, temp: 10, precip: 0, wind: 1, cloud: 40, dew: 4)

        let days = ForecastDay.make(
            from: [nine, firstEight, conflictingEight, ten], calendar: calendar
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].hours.map(\.time), [atEight, atNine, atTen])
        XCTAssertEqual(days[0].hours.map(\.temp), [6, 9, 10])
    }

    func testForecastDayKeepsRepeatedLocalHourButRemovesItsExactDuplicate() throws {
        var oslo = Calendar(identifier: .gregorian)
        oslo.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstLocal0230 = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2024, month: 10, day: 27, hour: 0, minute: 30
        )))
        let secondLocal0230 = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2024, month: 10, day: 27, hour: 1, minute: 30
        )))
        XCTAssertEqual(oslo.component(.hour, from: firstLocal0230), 2)
        XCTAssertEqual(oslo.component(.hour, from: secondLocal0230), 2)
        XCTAssertEqual(oslo.startOfDay(for: firstLocal0230), oslo.startOfDay(for: secondLocal0230))

        let laterInstant = ForecastHour(
            time: secondLocal0230, temp: 7, precip: 0, wind: 1, cloud: 30, dew: 3
        )
        let firstInstant = ForecastHour(
            time: firstLocal0230, temp: 6, precip: 0, wind: 1, cloud: 20, dew: 2
        )
        let exactDuplicate = ForecastHour(
            time: firstLocal0230, temp: 99, precip: 0, wind: 1, cloud: 20, dew: 2
        )

        let days = ForecastDay.make(
            from: [laterInstant, firstInstant, exactDuplicate], calendar: oslo
        )

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].hours.map(\.time), [firstLocal0230, secondLocal0230])
        XCTAssertEqual(days[0].hours.map(\.temp), [6, 7])
        XCTAssertEqual(secondLocal0230.timeIntervalSince(firstLocal0230), 3_600)

        let firstLabel = ForecastHourLabel.make(
            for: firstLocal0230,
            among: [firstLocal0230, secondLocal0230, exactDuplicate.time],
            calendar: oslo
        )
        let secondLabel = ForecastHourLabel.make(
            for: secondLocal0230,
            among: [firstLocal0230, secondLocal0230, exactDuplicate.time],
            calendar: oslo
        )
        XCTAssertEqual(firstLabel.display, "02a")
        XCTAssertEqual(secondLabel.display, "02b")
        XCTAssertEqual(firstLabel.accessibility, "Klokken 02, første forekomst")
        XCTAssertEqual(secondLabel.accessibility, "Klokken 02, andre forekomst")
    }

    func testVisibleForecastSkipsOlderCacheDayAndKeepsThreeFutureDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 5, day: 10, hour: 6)))
        let cacheStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 5, day: 9)))
        let cached = (0..<120).map { offset in
            ForecastHour(
                time: calendar.date(byAdding: .hour, value: offset, to: cacheStart)!,
                temp: 8, precip: 0, wind: 1, cloud: 30, dew: 4
            )
        }

        let visible = ForecastDaySelection.hoursForVisibleDays(from: cached, now: now, calendar: calendar)
        let visibleDates = Set(visible.map { calendar.startOfDay(for: $0.time) })
        XCTAssertEqual(visibleDates, Set((0..<3).map {
            calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: now))!
        }))
        XCTAssertTrue(visible.allSatisfy { $0.time >= calendar.startOfDay(for: now) })
    }

    func testVisibleForecastKeepsSameThreeDaysAfterRefreshAddsFourthDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 5, day: 10, hour: 12)))
        let firstDay = calendar.startOfDay(for: now)

        func forecast(days: Int, temperature: Double) -> [ForecastHour] {
            (0..<(days * 24)).map { offset in
                ForecastHour(
                    time: calendar.date(byAdding: .hour, value: offset, to: firstDay)!,
                    temp: temperature, precip: 0, wind: 1, cloud: 30, dew: 4
                )
            }
        }

        let beforeRefresh = ForecastDaySelection.hoursForVisibleDays(
            from: forecast(days: 3, temperature: 8), now: now, calendar: calendar
        )
        let afterRefresh = ForecastDaySelection.hoursForVisibleDays(
            from: forecast(days: 4, temperature: 12), now: now, calendar: calendar
        )
        let expectedDays = Set((0..<3).map {
            calendar.date(byAdding: .day, value: $0, to: firstDay)!
        })
        let refreshedDays = Set(afterRefresh.map { calendar.startOfDay(for: $0.time) })

        XCTAssertEqual(Set(beforeRefresh.map { calendar.startOfDay(for: $0.time) }), expectedDays)
        XCTAssertEqual(refreshedDays, expectedDays)
        XCTAssertEqual(afterRefresh.count, 72)
        XCTAssertTrue(afterRefresh.allSatisfy { $0.temp == 12 })
    }

    func testWeatherBandIncludesFollowingMorningInIts23To07Cell() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        let times = [6, 7, 23, 1, 5, 6, 7].enumerated().map { index, hour in
            let date = index < 3
                ? calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
                : calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: day)!)!
            return ForecastHour(time: date, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7)
        }

        let band = WeatherBandHours.make(for: day, from: times, calendar: calendar)
        XCTAssertEqual(band.map(\.time), [times[1].time, times[2].time, times[3].time, times[4].time, times[5].time])
        XCTAssertTrue(band.contains { calendar.component(.hour, from: $0.time) == 5 })
        XCTAssertFalse(band.contains { $0.time == times[0].time || $0.time == times[6].time })
    }

    func testWeatherBandDeduplicatesTimestampsKeepingFirstForecastSample() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        let duplicateTime = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day))
        let first = ForecastHour(time: duplicateTime, temp: 6, precip: 0, wind: 1, cloud: 20, dew: 2)
        let duplicate = ForecastHour(time: duplicateTime, temp: 9, precip: 1, wind: 4, cloud: 80, dew: 7)
        let later = ForecastHour(
            time: duplicateTime.addingTimeInterval(3_600), temp: 7, precip: 0, wind: 2, cloud: 30, dew: 3
        )

        let band = WeatherBandHours.make(for: day, from: [first, duplicate, later], calendar: calendar)

        XCTAssertEqual(band.map(\.time), [first.time, later.time])
        XCTAssertEqual(band.first, first)
    }

    func testWeatherBandSortsUnorderedSamplesAfterDeduplicating() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        let atEight = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day))
        let atNine = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day))
        let atTen = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day))
        let eight = ForecastHour(time: atEight, temp: 8, precip: 0, wind: 1, cloud: 20, dew: 2)
        let nine = ForecastHour(time: atNine, temp: 9, precip: 0, wind: 1, cloud: 30, dew: 3)
        let duplicateNine = ForecastHour(time: atNine, temp: 99, precip: 0, wind: 1, cloud: 30, dew: 3)
        let ten = ForecastHour(time: atTen, temp: 10, precip: 0, wind: 1, cloud: 40, dew: 4)

        let band = WeatherBandHours.make(
            for: day, from: [ten, nine, eight, duplicateNine], calendar: calendar
        )

        XCTAssertEqual(band.map(\.time), [atEight, atNine, atTen])
        XCTAssertEqual(band.map(\.temp), [8, 9, 10])
    }

    func testWeatherBandKeepsBothInstantsOfRepeatedLocalHour() throws {
        var oslo = Calendar(identifier: .gregorian)
        oslo.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let visualDay = try XCTUnwrap(utc.date(from: DateComponents(year: 2024, month: 10, day: 26)))
        let firstLocal0230 = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2024, month: 10, day: 27, hour: 0, minute: 30
        )))
        let secondLocal0230 = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2024, month: 10, day: 27, hour: 1, minute: 30
        )))
        XCTAssertEqual(oslo.component(.hour, from: firstLocal0230), 2)
        XCTAssertEqual(oslo.component(.hour, from: secondLocal0230), 2)
        XCTAssertEqual(oslo.component(.minute, from: firstLocal0230), 30)
        XCTAssertEqual(oslo.component(.minute, from: secondLocal0230), 30)

        let laterInstant = ForecastHour(
            time: secondLocal0230, temp: 7, precip: 0, wind: 1, cloud: 30, dew: 3
        )
        let firstInstant = ForecastHour(
            time: firstLocal0230, temp: 6, precip: 0, wind: 1, cloud: 20, dew: 2
        )
        let exactDuplicate = ForecastHour(
            time: firstLocal0230, temp: 99, precip: 0, wind: 1, cloud: 20, dew: 2
        )

        let band = WeatherBandHours.make(
            for: visualDay, from: [laterInstant, firstInstant, exactDuplicate], calendar: oslo
        )

        XCTAssertEqual(band.map(\.time), [firstLocal0230, secondLocal0230])
        XCTAssertEqual(band.map(\.temp), [6, 7])
        XCTAssertEqual(secondLocal0230.timeIntervalSince(firstLocal0230), 3_600)
    }

    func testWeatherBandIgnoresOutsideSampleWithSameWallClockHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let outsideAtSix = try XCTUnwrap(calendar.date(bySettingHour: 6, minute: 0, second: 0, of: day))
        let insideAtSix = try XCTUnwrap(calendar.date(bySettingHour: 6, minute: 0, second: 0, of: nextDay))
        let outside = ForecastHour(time: outsideAtSix, temp: 99, precip: 0, wind: 1, cloud: 0, dew: 0)
        let inside = ForecastHour(time: insideAtSix, temp: 6, precip: 0, wind: 1, cloud: 0, dew: 0)
        let insideDuplicate = ForecastHour(time: insideAtSix, temp: 99, precip: 0, wind: 1, cloud: 0, dew: 0)

        let band = WeatherBandHours.make(
            for: day, from: [outside, inside, insideDuplicate], calendar: calendar
        )

        XCTAssertEqual(band.map(\.time), [insideAtSix])
        XCTAssertEqual(band.first?.temp, 6)
    }

    func testWeatherBandWallClockIntervalsHandleBothDaylightSavingTransitions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))

        let transitions = [
            (year: 2030, month: 3, day: 30, expectedNightHours: 7, missingHour: 4, expectedOffset: 5),
            (year: 2030, month: 10, day: 26, expectedNightHours: 9, missingHour: 2, expectedOffset: 3),
        ]
        for transition in transitions {
            let day = try XCTUnwrap(calendar.date(from: DateComponents(
                year: transition.year, month: transition.month, day: transition.day
            )))
            let interval = try XCTUnwrap(ForecastHourSelection.bandInterval(
                on: day, startingAt: 23, slotCount: 8, calendar: calendar
            ))
            let elapsedHours = Int(interval.upperBound.timeIntervalSince(interval.lowerBound) / 3_600)
            XCTAssertEqual(elapsedHours, transition.expectedNightHours)

            for startHour in [7, 15] {
                let daytimeInterval = try XCTUnwrap(ForecastHourSelection.bandInterval(
                    on: day, startingAt: startHour, slotCount: 8, calendar: calendar
                ))
                XCTAssertEqual(
                    Int(daytimeInterval.upperBound.timeIntervalSince(daytimeInterval.lowerBound) / 3_600),
                    8
                )
            }

            var forecast: [ForecastHour] = []
            var time = interval.lowerBound
            while time < interval.upperBound {
                forecast.append(ForecastHour(
                    time: time, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7
                ))
                time = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: time))
            }
            XCTAssertTrue(ForecastHourSelection.missingHourOffsets(
                in: interval, startingAt: 23, slotCount: 8, forecast: forecast, calendar: calendar
            ).isEmpty)
            let missingTime = try XCTUnwrap(forecast.first {
                calendar.component(.hour, from: $0.time) == transition.missingHour
            }?.time)
            let incompleteForecast = forecast.filter { $0.time != missingTime }
            XCTAssertEqual(
                ForecastHourSelection.missingHourOffsets(
                    in: interval, startingAt: 23, slotCount: 8,
                    forecast: incompleteForecast, calendar: calendar
                ),
                [transition.expectedOffset]
            )
        }
    }

    func testWeatherBandHatchLegendDistinguishesPartialSunFromForecastGapsNotAlerts() {
        let norwegian = WeatherBandHatchLegend.texts(for: .bokmal)
        XCTAssertEqual(norwegian.partialSun, "Gul skravur: delvis sol")
        XCTAssertEqual(norwegian.missingForecast, "Grå skravur: Yr mangler timer")
        XCTAssertTrue(norwegian.accessibility.contains("ikke manglende varsling"))

        let english = WeatherBandHatchLegend.texts(for: .english)
        XCTAssertEqual(english.partialSun, "Yellow hatch: partial sun")
        XCTAssertEqual(english.missingForecast, "Gray hatch: missing Yr hours")
        XCTAssertTrue(english.accessibility.contains("does not mean an alert is missing"))
    }

    func testWeatherBandHatchLegendHidesPartialSunKeyWithoutSolarRow() {
        let norwegian = WeatherBandHatchLegend.texts(for: .bokmal, includesPartialSun: false)
        XCTAssertNil(norwegian.partialSun)
        XCTAssertEqual(norwegian.missingForecast, "Grå skravur: Yr mangler timer")
        XCTAssertFalse(norwegian.accessibility.contains("Gul skravur"))
        XCTAssertTrue(norwegian.accessibility.contains("Grå skravur"))

        let english = WeatherBandHatchLegend.texts(for: .english, includesPartialSun: false)
        XCTAssertNil(english.partialSun)
        XCTAssertEqual(english.missingForecast, "Gray hatch: missing Yr hours")
        XCTAssertFalse(english.accessibility.contains("Yellow hatch"))
        XCTAssertTrue(english.accessibility.contains("Gray hatch"))
    }

    func testRepeatedAutumnHourProducesOneMissingVisualCell() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 26)))
        let interval = try XCTUnwrap(ForecastHourSelection.bandInterval(
            on: day, startingAt: 23, slotCount: 8, calendar: calendar
        ))

        var forecast: [ForecastHour] = []
        var time = interval.lowerBound
        while time < interval.upperBound {
            forecast.append(ForecastHour(
                time: time, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7
            ))
            time = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: time))
        }
        let repeatedHour = forecast.filter { calendar.component(.hour, from: $0.time) == 2 }
        guard repeatedHour.count == 2 else {
            XCTFail("The autumn transition must contain both local 02:00 samples")
            return
        }
        XCTAssertTrue(ForecastHourSelection.missingHourOffsets(
            in: interval, startingAt: 23, slotCount: 8, forecast: forecast, calendar: calendar
        ).isEmpty)

        let missingOne = forecast.filter { $0.time != repeatedHour[0].time }
        XCTAssertEqual(ForecastHourSelection.missingHourOffsets(
            in: interval, startingAt: 23, slotCount: 8, forecast: missingOne, calendar: calendar
        ), [3])

        let repeatedTimes = Set(repeatedHour.map(\.time))
        let missingBoth = forecast.filter { !repeatedTimes.contains($0.time) }
        XCTAssertEqual(ForecastHourSelection.missingHourOffsets(
            in: interval, startingAt: 23, slotCount: 8, forecast: missingBoth, calendar: calendar
        ), [3])
    }

    func testRepeatedAutumnForecastSamplesShareOneCellAndKeepStrongerEvent() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 26)))
        let interval = try XCTUnwrap(ForecastHourSelection.bandInterval(
            on: day, startingAt: 23, slotCount: 8, calendar: calendar
        ))

        var forecast: [ForecastHour] = []
        var time = interval.lowerBound
        while time < interval.upperBound {
            forecast.append(ForecastHour(
                time: time, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7
            ))
            time = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: time))
        }
        let repeatedHours = forecast.filter { calendar.component(.hour, from: $0.time) == 2 }
        guard repeatedHours.count == 2 else {
            XCTFail("The autumn transition must contain both local 02:00 samples")
            return
        }

        let quieter = ForecastHour(
            time: repeatedHours[0].time, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7
        )
        let stronger = ForecastHour(
            time: repeatedHours[1].time, temp: 8, precip: 2, wind: 1, cloud: 60, dew: 7
        )
        let selected = ForecastHourSelection.strongestPerBandCell(
            from: [quieter, stronger], startingAt: 23, slotCount: 8, calendar: calendar,
            priority: { $0.precipitationRate }
        )

        XCTAssertEqual(selected.count, 1, "Both samples must map to one fixed 02:00 cell.")
        XCTAssertEqual(selected.first?.time, stronger.time, "The stronger precipitation event must represent the cell.")
    }

    func testRepeatedAutumnForecastSamplesUseEarlierSampleForEqualPriority() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 10, day: 26)))
        let interval = try XCTUnwrap(ForecastHourSelection.bandInterval(
            on: day, startingAt: 23, slotCount: 8, calendar: calendar
        ))

        var forecast: [ForecastHour] = []
        var time = interval.lowerBound
        while time < interval.upperBound {
            forecast.append(ForecastHour(
                time: time, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7
            ))
            time = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: time))
        }
        let repeatedHours = forecast.filter { calendar.component(.hour, from: $0.time) == 2 }
        guard repeatedHours.count == 2 else {
            XCTFail("The autumn transition must contain both local 02:00 samples")
            return
        }

        let selected = ForecastHourSelection.strongestPerBandCell(
            from: repeatedHours, startingAt: 23, slotCount: 8, calendar: calendar,
            priority: { _ in 1 }
        )

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.time, repeatedHours[0].time,
                       "Equal-priority duplicate hours must consistently choose the earlier instant.")
    }

    func testStrongestPerBandCellRejectsInvalidStartHoursAndSlotCounts() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let sample = ForecastHour(
            time: try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22, hour: 5))),
            temp: 8, precip: 1, wind: 1, cloud: 60, dew: 7
        )

        for startHour in [-1, 24] {
            XCTAssertTrue(ForecastHourSelection.strongestPerBandCell(
                from: [sample], startingAt: startHour, slotCount: 8, calendar: calendar,
                priority: { $0.precipitationRate }
            ).isEmpty, "Invalid start hour \(startHour) must not yield a cell.")
        }
        for slotCount in [0, 25] {
            XCTAssertTrue(ForecastHourSelection.strongestPerBandCell(
                from: [sample], startingAt: 5, slotCount: slotCount, calendar: calendar,
                priority: { $0.precipitationRate }
            ).isEmpty, "Invalid slot count \(slotCount) must not yield a cell.")
        }
    }

    func testStrongestPerBandCellUsesSuppliedCalendarForTimezoneAndDST() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let instant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2030, month: 1, day: 1, hour: 7
        )))
        let sample = ForecastHour(
            time: instant, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7
        )

        XCTAssertEqual(ForecastHourSelection.strongestPerBandCell(
            from: [sample], startingAt: 7, slotCount: 1, calendar: utc,
            priority: { $0.precipitationRate }
        ).count, 1, "07:00 UTC belongs in the UTC 07:00 cell.")
        XCTAssertTrue(ForecastHourSelection.strongestPerBandCell(
            from: [sample], startingAt: 7, slotCount: 1, calendar: losAngeles,
            priority: { $0.precipitationRate }
        ).isEmpty, "The same instant is 23:00 locally in Los Angeles, not 07:00.")
        XCTAssertEqual(ForecastHourSelection.strongestPerBandCell(
            from: [sample], startingAt: 23, slotCount: 1, calendar: losAngeles,
            priority: { $0.precipitationRate }
        ).count, 1)

        var oslo = Calendar(identifier: .gregorian)
        oslo.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let transitions: [(month: Int, day: Int, expectedLocalHours: [Int])] = [
            (3, 31, [1, 3, 4]),
            (10, 27, [1, 2, 3, 4]),
        ]
        for transition in transitions {
            let day = try XCTUnwrap(oslo.date(from: DateComponents(
                year: 2030, month: transition.month, day: transition.day
            )))
            let interval = try XCTUnwrap(ForecastHourSelection.bandInterval(
                on: day, startingAt: 1, slotCount: 4, calendar: oslo
            ))
            var forecast: [ForecastHour] = []
            var time = interval.lowerBound
            while time < interval.upperBound {
                forecast.append(ForecastHour(
                    time: time, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7
                ))
                time = try XCTUnwrap(oslo.date(byAdding: .hour, value: 1, to: time))
            }
            let selected = ForecastHourSelection.strongestPerBandCell(
                from: forecast, startingAt: 1, slotCount: 4, calendar: oslo,
                priority: { _ in 1 }
            )

            XCTAssertEqual(
                selected.map { oslo.component(.hour, from: $0.time) },
                transition.expectedLocalHours,
                "The band should represent each existing wall-clock cell once across DST."
            )
        }
    }

    func testStrongestPerBandCellIsIndependentOfInputOrderAndSortsOffsets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        func sample(hour: Int, minute: Int = 0, precipitation: Double) throws -> ForecastHour {
            ForecastHour(
                time: try XCTUnwrap(calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: day
                )),
                temp: 8, precip: precipitation, wind: 1, cloud: 60, dew: 7
            )
        }
        let weakerSameCell = try sample(hour: 7, minute: 5, precipitation: 0.2)
        let strongerSameCell = try sample(hour: 7, minute: 45, precipitation: 0.8)
        let nextCell = try sample(hour: 8, precipitation: 0.4)
        let laterCell = try sample(hour: 10, precipitation: 1.0)
        let forecast = [weakerSameCell, nextCell, laterCell, strongerSameCell]
        let inputOrders = [
            forecast,
            Array(forecast.reversed()),
            [forecast[2], forecast[0], forecast[3], forecast[1]],
        ]

        let selectedByOrder = inputOrders.map { input in
            ForecastHourSelection.strongestPerBandCell(
                from: input, startingAt: 7, slotCount: 8, calendar: calendar,
                priority: { $0.precipitationRate }
            ).map(\.time)
        }
        let expected = [strongerSameCell.time, nextCell.time, laterCell.time]

        XCTAssertEqual(selectedByOrder[0], expected)
        XCTAssertEqual(selectedByOrder[1], expected)
        XCTAssertEqual(selectedByOrder[2], expected)
    }

    func testStrongestPerBandCellHandlesNonFinitePrioritiesDeterministically() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        func sample(minute: Int) throws -> ForecastHour {
            ForecastHour(
                time: try XCTUnwrap(calendar.date(
                    bySettingHour: 7, minute: minute, second: 0, of: day
                )),
                temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7
            )
        }
        let nanScore = try sample(minute: 5)
        let positiveInfinityScore = try sample(minute: 15)
        let negativeInfinityScore = try sample(minute: 25)
        let finiteScore = try sample(minute: 35)
        let nonFiniteCandidates = [nanScore, positiveInfinityScore, negativeInfinityScore]

        for candidates in [nonFiniteCandidates, Array(nonFiniteCandidates.reversed())] {
            let selected = ForecastHourSelection.strongestPerBandCell(
                from: candidates, startingAt: 7, slotCount: 1, calendar: calendar,
                priority: { hour in
                    if hour.time == nanScore.time { return .nan }
                    if hour.time == positiveInfinityScore.time { return .infinity }
                    return -.infinity
                }
            )
            XCTAssertEqual(selected.map(\.time), [nanScore.time],
                           "When all scores are non-finite, the earliest sample is the deterministic fallback.")
        }

        let finiteWins = ForecastHourSelection.strongestPerBandCell(
            from: [positiveInfinityScore, finiteScore], startingAt: 7, slotCount: 1,
            calendar: calendar,
            priority: { $0.time == finiteScore.time ? -100 : .infinity }
        )
        XCTAssertEqual(finiteWins.map(\.time), [finiteScore.time],
                       "A finite score wins over a non-finite score, even when it is negative.")
    }

    func testStrongestPerBandCellBreaksExactTiesByWeatherContentNotInputOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let sameTime = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2030, month: 9, day: 22, hour: 7
        )))
        let lighter = ForecastHour(
            time: sameTime, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7
        )
        let heavier = ForecastHour(
            time: sameTime, temp: 8, precip: 0.8, wind: 1, cloud: 60, dew: 7
        )

        for candidates in [[lighter, heavier], [heavier, lighter]] {
            let selected = ForecastHourSelection.strongestPerBandCell(
                from: candidates, startingAt: 7, slotCount: 1, calendar: calendar,
                priority: { _ in 42 }
            )
            XCTAssertEqual(selected.count, 1)
            XCTAssertEqual(selected.first?.precipitationRate, 0.8,
                           "Exact time/priority ties use the deterministic weather-content key.")
        }
    }

    func testForecastBandSignalPriorityRanksPrecipitationAboveDew() {
        let dew = ForecastBandSignalPriority.score(for: .dew, strength: 0.8)
        let possible = ForecastBandSignalPriority.score(for: .possiblePrecipitation, strength: 0.2)
        let observed = ForecastBandSignalPriority.score(for: .observedPrecipitation, strength: 0.2)
        let certain = ForecastBandSignalPriority.score(for: .certainPrecipitation, strength: 0.2)

        XCTAssertGreaterThan(possible, dew)
        XCTAssertGreaterThan(observed, possible)
        XCTAssertGreaterThan(certain, observed)
    }

    func testForecastBandSignalStrengthCannotCrossSignalClassBoundaries() {
        let dew = ForecastBandSignalPriority.score(for: .dew, strength: 10_000)
        let possible = ForecastBandSignalPriority.score(for: .possiblePrecipitation, strength: 10_000)
        let observed = ForecastBandSignalPriority.score(for: .observedPrecipitation, strength: 10_000)
        let certain = ForecastBandSignalPriority.score(for: .certainPrecipitation, strength: 10_000)

        XCTAssertLessThan(dew, possible)
        XCTAssertLessThan(possible, observed)
        XCTAssertLessThan(observed, certain)
        XCTAssertEqual(dew, 1_999)
        XCTAssertEqual(ForecastBandSignalPriority.score(for: .dew, strength: -10_000), 1_000)
        XCTAssertEqual(ForecastBandSignalPriority.score(for: .dew, strength: .nan), 1_000)
        XCTAssertEqual(ForecastBandSignalPriority.score(for: .dew, strength: .infinity), 1_000)
        XCTAssertEqual(ForecastBandSignalPriority.score(for: .none, strength: 10_000), 0)
    }

    func testEmptyAndNeutralForecastSamplesDoNotCreateBandSignals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        var emptyPriorityEvaluations = 0
        let emptySelection = ForecastHourSelection.strongestPerBandCell(
            from: [], startingAt: 7, slotCount: 8, calendar: calendar,
            priority: { _ in
                emptyPriorityEvaluations += 1
                return ForecastBandSignalPriority.score(for: .observedPrecipitation)
            }
        )
        XCTAssertTrue(emptySelection.isEmpty)
        XCTAssertEqual(emptyPriorityEvaluations, 0, "An empty forecast must not evaluate or create a signal.")

        func sample(hour: Int, precipitation: Double) throws -> ForecastHour {
            ForecastHour(
                time: try XCTUnwrap(calendar.date(
                    bySettingHour: hour, minute: 0, second: 0, of: day
                )),
                temp: 8, precip: precipitation, wind: 1, cloud: 60, dew: 7
            )
        }
        let neutral = try sample(hour: 7, precipitation: 0)
        let observed = try sample(hour: 10, precipitation: 0.5)
        let candidates = [observed, neutral]
        func signalPriority(_ hour: ForecastHour) -> Double {
            hour.precipitationRate >= 0.1
                ? ForecastBandSignalPriority.score(for: .observedPrecipitation, strength: hour.precipitationRate)
                : ForecastBandSignalPriority.score(for: .none)
        }
        let selected = ForecastHourSelection.strongestPerBandCell(
            from: candidates, startingAt: 7, slotCount: 8, calendar: calendar,
            priority: signalPriority
        )

        XCTAssertEqual(selected.map { calendar.component(.hour, from: $0.time) }, [7, 10])
        XCTAssertEqual(selected.map(signalPriority), [0, 3_000.5],
                       "Neutral samples remain unmarked while a valid signal keeps its stable cell order.")
    }

    func testRecentPrecipitationSuppressesDewForThreeHours() throws {
        let wetTime = try XCTUnwrap(Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2030, month: 9, day: 22, hour: 7)
        ))
        let dewTime = wetTime.addingTimeInterval(2 * 3_600)
        let wetHour = ForecastHour(
            time: wetTime, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7
        )
        let dewHour = ForecastHour(
            time: dewTime, temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7
        )
        let dryHour = ForecastHour(
            time: dewTime.addingTimeInterval(3_601), temp: 8, precip: 0, wind: 1, cloud: 60, dew: 7
        )

        XCTAssertTrue(ForecastBandSignalPriority.hasRecentPrecipitation(
            before: dewHour, among: [wetHour]
        ))
        XCTAssertFalse(ForecastBandSignalPriority.hasRecentPrecipitation(
            before: dryHour, among: [wetHour]
        ))
    }

    func testNowCardTracksTheWeatherBandHourAcrossAnHourBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Oslo"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        let eleven = try XCTUnwrap(calendar.date(bySettingHour: 11, minute: 0, second: 0, of: day))
        let noon = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day))
        let hours = [
            ForecastHour(time: eleven, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7),
            ForecastHour(time: noon, temp: 9, precip: 0, wind: 1, cloud: 60, dew: 7),
        ]
        let band = WeatherBandHours.make(for: day, from: hours, calendar: calendar)
        let before = try XCTUnwrap(ForecastHourSelection.current(in: hours, at: noon.addingTimeInterval(-1)))
        let after = try XCTUnwrap(ForecastHourSelection.current(in: hours, at: noon.addingTimeInterval(1)))

        XCTAssertEqual(before.time, eleven)
        XCTAssertEqual(after.time, noon)
        XCTAssertTrue(band.contains(before))
        XCTAssertTrue(band.contains(after))
        XCTAssertEqual(before.precip, 0.2)
        XCTAssertEqual(after.precip, 0)
    }

    func testCurrentForecastSelectionHandlesUnsortedAndFutureOnlyInput() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2030, month: 9, day: 22)))
        func sample(hour: Int) throws -> ForecastHour {
            ForecastHour(
                time: try XCTUnwrap(calendar.date(
                    bySettingHour: hour, minute: 0, second: 0, of: day
                )),
                temp: Double(hour), precip: 0, wind: 1, cloud: 60, dew: 7
            )
        }
        let nine = try sample(hour: 9)
        let ten = try sample(hour: 10)
        let noon = try sample(hour: 12)
        let unsorted = [noon, nine, ten]

        XCTAssertEqual(ForecastHourSelection.current(
            in: unsorted, at: ten.time.addingTimeInterval(1)
        )?.time, ten.time, "Choose the latest sample at or before now, regardless of input order.")
        XCTAssertEqual(ForecastHourSelection.current(
            in: [noon, ten], at: nine.time
        )?.time, ten.time, "When every sample is future-dated, fall back to the earliest one.")
    }

    func testCurrentForecastSelectionIncludesSampleExactlyAtNow() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let previous = ForecastHour(
            time: now.addingTimeInterval(-60 * 60), temp: 8, precip: 0.2,
            wind: 1, cloud: 60, dew: 7
        )
        let exact = ForecastHour(
            time: now, temp: 9, precip: 0.7, wind: 1, cloud: 60, dew: 7
        )
        let future = ForecastHour(
            time: now.addingTimeInterval(60 * 60), temp: 10, precip: 0,
            wind: 1, cloud: 60, dew: 7
        )

        let selected = try XCTUnwrap(ForecastHourSelection.current(
            in: [future, previous, exact], at: now
        ))

        XCTAssertEqual(selected.time, now)
        XCTAssertEqual(selected.precipitationRate, 0.7)
    }

    func testCurrentForecastSelectionBreaksExactNowTiesIndependentlyOfInputOrder() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let lighter = ForecastHour(
            time: now, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7
        )
        let heavier = ForecastHour(
            time: now, temp: 8, precip: 0.8, wind: 1, cloud: 60, dew: 7
        )

        for input in [[lighter, heavier], [heavier, lighter]] {
            let selected = ForecastHourSelection.current(in: input, at: now)
            XCTAssertEqual(selected?.time, now)
            XCTAssertEqual(selected?.precipitationRate, 0.8)
        }
    }

    func testCurrentForecastSelectionReturnsNilForEmptyForecast() {
        XCTAssertNil(ForecastHourSelection.current(in: [], at: Date()))
    }

    func testCurrentForecastSelectionBreaksIdenticalTimestampTiesIndependentlyOfInputOrder() {
        let time = Date(timeIntervalSince1970: 1_900_000_000)
        let lighter = ForecastHour(time: time, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7)
        let heavier = ForecastHour(time: time, temp: 8, precip: 0.8, wind: 1, cloud: 60, dew: 7)

        for input in [[lighter, heavier], [heavier, lighter]] {
            let selected = ForecastHourSelection.current(in: input, at: time.addingTimeInterval(1))
            XCTAssertEqual(selected?.precipitationRate, 0.8)
        }
    }

    func testCurrentForecastSelectionBreaksFutureFallbackTiesIndependentlyOfOrder() {
        let time = Date(timeIntervalSince1970: 1_900_000_000)
        let earlierButStillFuture = time.addingTimeInterval(60 * 60)
        let lighter = ForecastHour(
            time: earlierButStillFuture, temp: 8, precip: 0.2, wind: 1, cloud: 60, dew: 7
        )
        let heavier = ForecastHour(
            time: earlierButStillFuture, temp: 8, precip: 0.8, wind: 1, cloud: 60, dew: 7
        )

        for input in [[lighter, heavier], [heavier, lighter]] {
            let selected = ForecastHourSelection.current(in: input, at: time)
            XCTAssertEqual(selected?.precipitationRate, 0.8)
        }
    }

    func testCurrentForecastSelectionBreaksTiesUsingUnsortedRadarContent() throws {
        let time = Date(timeIntervalSince1970: 1_900_000_000)
        let earlyRadarTime = time.addingTimeInterval(5 * 60)
        let lateRadarTime = time.addingTimeInterval(10 * 60)
        let lowerRadarContent = ForecastHour(
            time: time, temp: 8, precip: 0.1, wind: 1, cloud: 60, dew: 7,
            radarSamples: [
                PrecipitationSample(time: lateRadarTime, rate: 0.8),
                PrecipitationSample(time: earlyRadarTime, rate: 0.2),
            ]
        )
        let higherRadarContent = ForecastHour(
            time: time, temp: 8, precip: 0.1, wind: 1, cloud: 60, dew: 7,
            radarSamples: [
                PrecipitationSample(time: earlyRadarTime, rate: 0.5),
                PrecipitationSample(time: lateRadarTime, rate: 0.8),
            ]
        )

        for input in [[lowerRadarContent, higherRadarContent], [higherRadarContent, lowerRadarContent]] {
            let selected = try XCTUnwrap(ForecastHourSelection.current(
                in: input, at: time.addingTimeInterval(1)
            ))
            let earlyRate = try XCTUnwrap(selected.radarSamples?.first { $0.time == earlyRadarTime }?.rate)
            XCTAssertEqual(earlyRate, 0.5)
        }
    }

    @MainActor
    func testForecastRecipientsExcludeRemovedAndRelocatedPlaces() {
        let removed = Place(name: "Slettet", lat: 64, lon: 11)
        let moved = Place(name: "Flyttet", lat: 64, lon: 11)
        var relocated = moved
        relocated.lat = 63
        let replacement = Place(name: "Slettet", lat: 64, lon: 11)
        XCTAssertTrue(Store.currentRecipients(
            for: [removed, moved], in: [relocated, replacement]
        ).isEmpty)
    }

    @MainActor
    func testForecastRecipientsKeepLatestNamesAndRulesAtSameLocation() {
        let original = Place(name: "Klinga", lat: 64.409401, lon: 11.477861)
        var updated = original
        updated.customName = "Hjemme"
        updated.lat = 64.409402 // Same precision as the actual forecast request.
        updated.rules = [Rule(type: .vind)]
        let recipients = Store.currentRecipients(for: [original], in: [updated])
        XCTAssertEqual(recipients.count, 1)
        XCTAssertEqual(recipients.first?.customName, "Hjemme")
        XCTAssertEqual(recipients.first?.rules.first?.type, .vind)
    }

    @MainActor
    func testSameDisplayNamesRemainSeparateForecastLocations() {
        let first = Place(name: "Hytte", lat: 64, lon: 11)
        let second = Place(name: "Hytte", lat: 63, lon: 11)
        let groups = Store.groupedByForecastLocation([first, second])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.values.map(\.count).reduce(0, +), 2)
    }

    @MainActor
    func testCancelledRefreshDoesNotUpdateTimestampOrLog() async {
        let store = Store.shared
        let lastUpdate = store.lastUpdate
        let logIDs = store.log.map(\.id)
        let result = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.refreshAll(backgroundOnly: true)
        }.value

        XCTAssertFalse(result)
        XCTAssertEqual(store.lastUpdate, lastUpdate)
        XCTAssertEqual(store.log.map(\.id), logIDs)
    }

    @MainActor
    func testCancelledReplanDoesNotReplaceNotificationPlan() async {
        let store = Store.shared
        let logIDs = store.log.map(\.id)
        await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await store.replan()
        }.value
        XCTAssertEqual(store.log.map(\.id), logIDs)
    }

    @MainActor
    func testStoreRemainsSharedAcrossTaskBoundaries() async {
        let foregroundStore = Store.shared
        let backgroundStore = await Task { @MainActor in Store.shared }.value
        XCTAssertTrue(foregroundStore === backgroundStore)

        let originalAuthorization = foregroundStore.notificationsAuthorized
        defer { foregroundStore.notificationsAuthorized = originalAuthorization }
        foregroundStore.notificationsAuthorized = false
        XCTAssertEqual(backgroundStore.notificationsAuthorized, false)
        backgroundStore.notificationsAuthorized = true
        XCTAssertEqual(foregroundStore.notificationsAuthorized, true)
    }

    func testNotificationAuthorizationStatusReflectsCurrentSettings() async {
        let denied = await NotificationScheduler.authorizationStatus { .denied }
        let authorized = await NotificationScheduler.authorizationStatus { .authorized }
        let provisional = await NotificationScheduler.authorizationStatus { .provisional }
        let ephemeral = await NotificationScheduler.authorizationStatus { .ephemeral }
        let undetermined = await NotificationScheduler.authorizationStatus { .notDetermined }

        XCTAssertEqual(denied, false)
        XCTAssertEqual(authorized, true)
        XCTAssertEqual(provisional, true)
        XCTAssertEqual(ephemeral, true)
        XCTAssertNil(undetermined)
    }

    @MainActor
    func testChangedNotificationAuthorizationReplansExactlyOncePerChange() async {
        let persistenceKey = "varsel.test.notification-authorization-change.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        var replanCount = 0
        let store = Store(
            forecastFetcher: { _, _ in [] },
            persistenceKey: persistenceKey,
            notificationRescheduler: { _, _, _, _, _ in
                replanCount += 1
                return NotificationScheduleResult(
                    requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil
                )
            }
        )

        await store.updateNotificationAuthorization(false)
        XCTAssertEqual(replanCount, 1)
        await store.updateNotificationAuthorization(false)
        XCTAssertEqual(replanCount, 1)
        await store.updateNotificationAuthorization(true)
        XCTAssertEqual(replanCount, 2)
    }

    @MainActor
    func testBackgroundRefreshIncludesSelectedAndNotificationPlacesOnly() {
        var enabledRule = Rule(type: .regn)
        enabledRule.enabled = true
        var disabledRule = Rule(type: .vind)
        disabledRule.enabled = false
        let selected = Place(name: "Valgt uten varsler", lat: 1, lon: 1)
        let alerting = Place(name: "Aktivt varsel", lat: 2, lon: 2, rules: [enabledRule])
        let inactive = Place(name: "Avslått regel", lat: 3, lon: 3, rules: [disabledRule])
        var pushOff = Place(name: "Push av", lat: 4, lon: 4, rules: [enabledRule])
        pushOff.notificationsEnabled = false

        let result = Store.placesNeededForBackgroundRefresh(
            [selected, alerting, inactive, pushOff],
            selectedID: selected.id
        )

        XCTAssertEqual(Set(result.map(\.id)), [selected.id, alerting.id])
    }

    @MainActor
    func testBackgroundRefreshKeepsCurrentPositionPlaceEvenWithoutRules() {
        let position = Place(name: "Min posisjon", lat: 64.4, lon: 11.5)
        let other = Place(name: "Annet sted", lat: 63, lon: 11)

        let result = Store.placesNeededForBackgroundRefresh(
            [position, other], selectedID: position.id
        )

        XCTAssertEqual(result.map(\.id), [position.id])
    }

    func testPlaceEnabledRuleCountTracksInlineDeactivation() {
        var first = Rule(type: .regn)
        first.enabled = true
        var second = Rule(type: .vind)
        second.enabled = true
        var place = Place(name: "Teststed", lat: 64, lon: 11, rules: [first, second])
        XCTAssertEqual(place.enabledRuleCount, 2)
        place.rules[0].enabled = false
        XCTAssertEqual(place.enabledRuleCount, 1)
        place.rules[1].enabled = false
        XCTAssertEqual(place.enabledRuleCount, 0)
    }

    func testRuleFilterKeepsAllRulesOfSelectedType() {
        let rainA = Rule(type: .regn)
        let rainB = Rule(type: .regn)
        let wind = Rule(type: .vind)
        XCTAssertEqual(Rule.filtered([rainA, rainB, wind], by: .regn).map(\.id), [rainA.id, rainB.id])
        XCTAssertEqual(Rule.filtered([rainA, rainB, wind], by: nil).count, 3)
    }

    func testVisualAlertVisibilityIsIndependentFromPushRules() {
        var rule = Rule(type: .regn)
        rule.enabled = true
        var place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        XCTAssertTrue(place.isAlertTypeVisible(.regn))
        place.hiddenAlertTypes = [.regn]
        XCTAssertFalse(place.isAlertTypeVisible(.regn))
        XCTAssertTrue(place.rules[0].enabled)
        XCTAssertEqual(place.enabledRuleCount, 1)
    }

    func testHomeSwipeOrderRemovesDuplicateCurrentFavorite() {
        let current = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let favorite = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        XCTAssertEqual(
            HomeSwipeSelection.orderedIDs(leftID: current, currentID: current, rightID: favorite),
            [current, favorite]
        )
    }

    func testQuickNavigationDestinationsMergeRolesAndKeepGPSAffordance() {
        let position = UUID(), cabin = UUID()
        let destinations = HomeSwipeSelection.navigationDestinations(
            positionID: position,
            homeID: position,
            cabinID: cabin,
            availableIDs: [position, cabin]
        )

        XCTAssertEqual(destinations.map(\.placeID), [position, cabin])
        XCTAssertEqual(destinations.map(\.title), ["Her! · Hjem", "Hytta"])
        XCTAssertEqual(destinations.map(\.representsCurrentPosition), [true, false])
        XCTAssertEqual(destinations.first?.systemImage, "location.fill")
        XCTAssertEqual(
            destinations.map { $0.accessibilityLabel(languageStyle: .bokmal) },
            ["Her! · Hjem, GPS-posisjon, live", "Hytta"]
        )

        let englishDestinations = HomeSwipeSelection.navigationDestinations(
            positionID: position,
            homeID: position,
            cabinID: cabin,
            availableIDs: [position, cabin],
            languageStyle: .english
        )
        XCTAssertEqual(englishDestinations.map(\.title), ["Here! · Home", "Cabin"])
        XCTAssertEqual(
            englishDestinations.map { $0.accessibilityLabel(languageStyle: .english) },
            ["Here! · Home, live GPS location", "Cabin"]
        )
    }

    func testHomeAndCabinShortcutLabelsCanBeCustomizedIndependently() {
        let home = UUID(), cabin = UUID()
        let destinations = HomeSwipeSelection.navigationDestinations(
            positionID: nil,
            homeID: home,
            cabinID: cabin,
            availableIDs: [home, cabin],
            homeShortcutTitle: "  Bosted  ",
            cabinShortcutTitle: "Fjellhytte"
        )

        XCTAssertEqual(destinations.map(\.title), ["Bosted", "Fjellhytte"])
        XCTAssertEqual(
            PlaceOrderingSettings.shortcutTitle(" \n ", fallback: "Hytta"),
            "Hytta"
        )
    }

    func testFixedNavigationLabelsFollowSelectedLanguageStyle() {
        XCTAssertEqual(
            FixedNavigationDestination.allCases.map { $0.title(languageStyle: .bokmal) },
            ["Steder", "Innstillinger"]
        )
        XCTAssertEqual(
            FixedNavigationDestination.allCases.map { $0.title(languageStyle: .inntrondersk) },
            ["Steder", "Innstillinger"]
        )
        XCTAssertEqual(
            FixedNavigationDestination.allCases.map { $0.title(languageStyle: .english) },
            ["Places", "Settings"]
        )
    }

    func testAlertEditingAccessibilityLabelFollowsSelectedLanguageStyle() {
        XCTAssertEqual(
            AlertEditingAccessibilityCopy.label(placeName: "Klinga", languageStyle: .bokmal),
            "Rediger varsler for Klinga"
        )
        XCTAssertEqual(
            AlertEditingAccessibilityCopy.label(placeName: "Klinga", languageStyle: .inntrondersk),
            "Rediger varsler for Klinga"
        )
        XCTAssertEqual(
            AlertEditingAccessibilityCopy.label(placeName: "Klinga", languageStyle: .english),
            "Edit alerts for Klinga"
        )
    }

    func testPlaceRoleAccessibilityLabelsFollowSelectedLanguageStyle() {
        XCTAssertEqual(
            PlaceRoleAccessibilityCopy.label(for: .selected, languageStyle: .bokmal),
            "Valgt sted"
        )
        XCTAssertEqual(
            PlaceRoleAccessibilityCopy.label(for: .home, languageStyle: .bokmal),
            "Hjemsted"
        )
        XCTAssertEqual(
            PlaceRoleAccessibilityCopy.label(for: .selected, languageStyle: .inntrondersk),
            "Valgt sted"
        )
        XCTAssertEqual(
            PlaceRoleAccessibilityCopy.label(for: .home, languageStyle: .inntrondersk),
            "Hjemsted"
        )
        XCTAssertEqual(
            PlaceRoleAccessibilityCopy.label(for: .selected, languageStyle: .english),
            "Selected place"
        )
        XCTAssertEqual(
            PlaceRoleAccessibilityCopy.label(for: .home, languageStyle: .english),
            "Home location"
        )
    }

    func testHomeRowVisibilityAccessibilityLabelsFollowSelectedLanguageStyle() {
        let expected: [(AlertType, String, String, String)] = [
            (.regn, "Vis Regn på Hjem", "Vis Regn på Hjem", "Show rain on Home"),
            (.frost, "Vis Frost på Hjem", "Vis Frost på Hjem", "Show frost on Home"),
            (.temperatur, "Vis Temperatur på Hjem", "Vis Temperatur på Hjem", "Show temperature on Home"),
            (.sno, "Vis Snø på Hjem", "Vis Snø på Hjem", "Show snow on Home"),
            (.vind, "Vis Vindkast på Hjem", "Vis Vindkast på Hjem", "Show wind on Home"),
            (.dugg, "Vis Duggpunkt på Hjem", "Vis Doggpunkt på Hjem", "Show dew point on Home"),
            (.sol, "Vis Sollys / skydekke på Hjem", "Vis Sollys / skydekke på Hjem", "Show sunlight / cloud cover on Home")
        ]

        for (type, bokmal, inntrondersk, english) in expected {
            XCTAssertEqual(
                HomeRowVisibilityAccessibilityCopy.label(for: type, languageStyle: .bokmal),
                bokmal
            )
            XCTAssertEqual(
                HomeRowVisibilityAccessibilityCopy.label(for: type, languageStyle: .inntrondersk),
                inntrondersk
            )
            XCTAssertEqual(
                HomeRowVisibilityAccessibilityCopy.label(for: type, languageStyle: .english),
                english
            )
        }
    }

    func testPlaceForecastExpansionAccessibilityCopyFollowsSelectedLanguageStyle() {
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.value(isExpanded: true, languageStyle: .bokmal),
            "Tredagersvarsel åpent"
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.value(isExpanded: false, languageStyle: .inntrondersk),
            "Tredagersvarsel lukket"
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.hint(isExpanded: false, languageStyle: .bokmal),
            "Dobbeltrykk for å åpne tredagersvarselet."
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.hint(isExpanded: true, languageStyle: .inntrondersk),
            "Dobbeltrykk for å lukke tredagersvarselet."
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.value(isExpanded: true, languageStyle: .english),
            "Three-day forecast expanded"
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.value(isExpanded: false, languageStyle: .english),
            "Three-day forecast collapsed"
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.hint(isExpanded: false, languageStyle: .english),
            "Double-tap to open the three-day forecast."
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.hint(isExpanded: true, languageStyle: .english),
            "Double-tap to collapse the three-day forecast."
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.compactRowHint(isExpanded: false, languageStyle: .bokmal),
            "Trykk for å vise værdetaljer"
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.compactRowHint(isExpanded: true, languageStyle: .bokmal),
            "Trykk for å lukke værdetaljene"
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.compactRowHint(isExpanded: false, languageStyle: .inntrondersk),
            WeatherLanguage.text("Trykk for å vise værdetaljer", style: .inntrondersk)
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.compactRowHint(isExpanded: true, languageStyle: .inntrondersk),
            WeatherLanguage.text("Trykk for å lukke værdetaljene", style: .inntrondersk)
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.compactRowHint(isExpanded: false, languageStyle: .english),
            "Tap to show weather details."
        )
        XCTAssertEqual(
            PlaceForecastExpansionAccessibilityCopy.compactRowHint(isExpanded: true, languageStyle: .english),
            "Tap to hide weather details."
        )
    }

    func testHomePageAccessibilityLabelFollowsSelectedLanguageStyle() {
        XCTAssertEqual(
            HomeSwipeSelection.pageAccessibilityLabel(index: 2, count: 5, languageStyle: .bokmal),
            "Stedside 2 av 5"
        )
        XCTAssertEqual(
            HomeSwipeSelection.pageAccessibilityLabel(index: 2, count: 5, languageStyle: .inntrondersk),
            "Stedside 2 av 5"
        )
        XCTAssertEqual(
            HomeSwipeSelection.pageAccessibilityLabel(index: 2, count: 5, languageStyle: .english),
            "Place 2 of 5"
        )
    }

    func testQuickNavigationDropsMissingRolesAndDeduplicatesCabinOverlap() {
        let position = UUID(), cabin = UUID(), deletedHome = UUID()
        let destinations = HomeSwipeSelection.navigationDestinations(
            positionID: position,
            homeID: deletedHome,
            cabinID: position,
            availableIDs: [position, cabin]
        )

        XCTAssertEqual(destinations.map(\.placeID), [position])
        XCTAssertEqual(destinations.map(\.title), ["Her! · Hytta"])
        XCTAssertTrue(destinations[0].representsCurrentPosition)
        XCTAssertEqual(destinations[0].accessibilityLabel(languageStyle: .bokmal), "Her! · Hytta, GPS-posisjon, live")

        let afterDeletedPosition = HomeSwipeSelection.navigationDestinations(
            positionID: UUID(),
            homeID: deletedHome,
            cabinID: cabin,
            availableIDs: [cabin]
        )
        XCTAssertEqual(afterDeletedPosition.map(\.placeID), [cabin])
        XCTAssertEqual(afterDeletedPosition.map(\.title), ["Hytta"])
        XCTAssertEqual(afterDeletedPosition.map { $0.accessibilityLabel(languageStyle: .bokmal) }, ["Hytta"])
    }

    func testQuickNavigationSelectionTracksSwipedPlaceAndFallsBackAfterDeletion() {
        let position = UUID(), home = UUID(), cabin = UUID(), deleted = UUID()
        let destinations = HomeSwipeSelection.navigationDestinations(
            positionID: position,
            homeID: home,
            cabinID: cabin,
            availableIDs: [position, home, cabin]
        )

        for swipedID in [position, home, cabin] {
            XCTAssertEqual(
                HomeSwipeSelection.selectedNavigationID(
                    selectedID: swipedID,
                    selectionIsCurrentLocation: swipedID == position,
                    positionID: position,
                    homeID: home,
                    destinations: destinations
                ),
                swipedID
            )
        }
        XCTAssertEqual(
            HomeSwipeSelection.selectedNavigationID(
                selectedID: deleted,
                selectionIsCurrentLocation: true,
                positionID: position,
                homeID: home,
                destinations: destinations
            ),
            position
        )
        XCTAssertEqual(
            HomeSwipeSelection.selectedNavigationID(
                selectedID: deleted,
                selectionIsCurrentLocation: false,
                positionID: deleted,
                homeID: deleted,
                destinations: [destinations[2]]
            ),
            cabin
        )
    }

    @MainActor
    func testManualSelectionDoesNotCarryPositionStyle() {
        let store = Store.shared
        guard let place = store.places.first else { return }
        store.select(place, fromCurrentLocation: true)
        store.select(place)
        XCTAssertFalse(store.selectionIsCurrentLocation)
    }

    func testDeletedHomeFavoriteResolvesToEmptySlot() {
        let left = UUID()
        let missing = UUID()
        let resolved = HomeFavorites(left: left, right: missing).resolved(availableIDs: Set([left]))
        XCTAssertEqual(resolved.left, left)
        XCTAssertNil(resolved.right)
    }

    func testHomeSwipeHintHiddenForSinglePlace() {
        XCTAssertFalse(HomeSwipeSelection.shouldShowHint(placeCount: 0))
        XCTAssertFalse(HomeSwipeSelection.shouldShowHint(placeCount: 1))
        XCTAssertTrue(HomeSwipeSelection.shouldShowHint(placeCount: 2))
    }

    func testRuleFilterReturnsEmptyForTypeWithoutRules() {
        let rain = Rule(type: .regn)
        XCTAssertTrue(Rule.filtered([rain], by: .sno).isEmpty)
        XCTAssertEqual(Rule.filtered([rain], by: nil).count, 1)
    }

    func testWatchNextEventsWithMissingForecastRemainEmpty() {
        XCTAssertTrue(WeatherGlance.nextEvents([], now: base).isEmpty)
    }

    func testWatchNextEventsOrderIsStableForEqualTimes() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let rain = WeatherStatus(ruleID: firstID, type: .regn, text: "Regn", eventAt: base.addingTimeInterval(3600), isNow: false)
        let wind = WeatherStatus(ruleID: secondID, type: .vind, text: "Vind", eventAt: base.addingTimeInterval(3600), isNow: false)
        let expected = [wind, rain].map(\.ruleID)
        XCTAssertEqual(WeatherGlance.nextEvents([rain, wind], now: base).map(\.ruleID), expected)
        XCTAssertEqual(WeatherGlance.nextEvents([wind, rain], now: base).map(\.ruleID), expected)
    }

    func testBackgroundRefreshSchedulesNextAttemptAfterThirtyMinutes() {
        XCTAssertEqual(
            BackgroundRefresh.earliestBeginDate(now: base),
            base.addingTimeInterval(30 * 60)
        )
    }

    func testBackgroundRefreshCompletionGateCompletesOnlyOnce() {
        let expirationFirst = BackgroundRefreshCompletionGate()
        var expirationFirstResults: [Bool] = []
        expirationFirst.finish(success: false) { expirationFirstResults.append($0) }
        expirationFirst.finish(success: true) { expirationFirstResults.append($0) }
        XCTAssertEqual(expirationFirstResults, [false])

        let workFirst = BackgroundRefreshCompletionGate()
        var workFirstResults: [Bool] = []
        workFirst.finish(success: true) { workFirstResults.append($0) }
        workFirst.finish(success: false) { workFirstResults.append($0) }
        XCTAssertEqual(workFirstResults, [true])
    }

    func testBackgroundRefreshCoordinatorExpirationCancelsAndFailsOnlyOnce() {
        var results: [Bool] = []
        var canceled = false
        let coordinator = BackgroundRefreshCoordinator { results.append($0) }

        coordinator.expire {
            canceled = true
            coordinator.finish(success: true) // Cancellation can race with a late success.
        }
        coordinator.finish(success: true) // Nor can work finish successfully afterward.

        XCTAssertTrue(canceled)
        XCTAssertEqual(results, [false])
    }

    func testBackgroundRefreshCoordinatorPreservesNormalWorkResult() {
        for result in [false, true] {
            var completions: [Bool] = []
            let coordinator = BackgroundRefreshCoordinator { completions.append($0) }
            coordinator.finish(success: result)
            XCTAssertEqual(completions, [result])
        }
    }

    func testBackgroundRefreshCompletionGateCompletesOnlyOnceUnderConcurrency() {
        let gate = BackgroundRefreshCompletionGate()
        let resultsLock = NSLock()
        var results: [Bool] = []

        DispatchQueue.concurrentPerform(iterations: 64) { index in
            gate.finish(success: index.isMultiple(of: 2)) { result in
                resultsLock.lock()
                results.append(result)
                resultsLock.unlock()
            }
        }

        resultsLock.lock()
        let completedResults = results
        resultsLock.unlock()
        XCTAssertEqual(completedResults.count, 1)
    }

    func testBackgroundRefreshReportsSuccessfulSubmission() {
        var submittedIdentifier: String?
        var submittedDate: Date?
        var reportedError: Error?

        BackgroundRefresh.schedule(
            now: base,
            submit: {
                submittedIdentifier = $0.identifier
                submittedDate = $0.earliestBeginDate
            },
            onFailure: { reportedError = $0 }
        )

        XCTAssertNil(reportedError)
        XCTAssertEqual(submittedIdentifier, BackgroundRefresh.id)
        XCTAssertEqual(submittedDate, base.addingTimeInterval(30 * 60))
    }

    func testBackgroundRefreshReportsRejectedSubmission() {
        let expectedError = NSError(domain: "BackgroundRefreshTests", code: 17)
        var reportedError: Error?

        BackgroundRefresh.schedule(
            now: base,
            submit: { _ in throw expectedError },
            onFailure: { reportedError = $0 }
        )

        XCTAssertEqual((reportedError as NSError?)?.code, expectedError.code)
    }

    func testBackgroundRefreshRetriesSchedulingWhenSceneBecomesActive() {
        var schedules = 0
        BackgroundRefresh.scheduleWhenActive(isActive: false) { schedules += 1 }
        XCTAssertEqual(schedules, 0)

        BackgroundRefresh.scheduleWhenActive(isActive: true) { schedules += 1 }
        XCTAssertEqual(schedules, 1)
    }

    @MainActor
    func testForecastRequestsDeduplicateCoordinatesAtApiPrecision() {
        let first = Place(name: "Namsos", lat: 64.466241, lon: 11.495719)
        let alias = Place(name: "Sentrum", lat: 64.466239, lon: 11.495721)
        let other = Place(name: "Klinga", lat: 64.4094, lon: 11.47786)

        let groups = Store.groupedByForecastLocation([first, alias, other])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[ForecastLocation(place: first)]?.count, 2)
        XCTAssertEqual(
            Store.forecastLocations(in: [first, alias, other]),
            [ForecastLocation(place: other), ForecastLocation(place: first)]
        )
        XCTAssertFalse(Store.isUsableForecast([]))
        XCTAssertTrue(Store.isUsableForecast(makeForecast(through: 2, precipitationOffsets: []), now: base))
    }

    @MainActor
    func testRefreshLimitsConcurrentRequestsAndEventuallyFetchesEveryUniqueLocation() async {
        let persistenceKey = "varsel.test.refresh-concurrency-limit.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }

        let places = (0..<11).map { index in
            Place(name: "Sted \(index)", lat: 60 + Double(index), lon: 5 + Double(index))
        }
        let locations = Store.forecastLocations(in: places)
        let concurrencyLimit = Store.forecastRequestConcurrencyLimit
        let probe = ForecastRefreshConcurrencyProbe(concurrencyLimit: concurrencyLimit)
        let store = Store(
            forecastFetcher: { latitude, longitude in
                await probe.recordAndWait(latitude: latitude, longitude: longitude)
                return (1...6).map { offset in
                    ForecastHour(
                        time: Date().addingTimeInterval(TimeInterval(offset * 3_600)),
                        temp: 8, precip: 0, wind: 2, cloud: 40, dew: 4
                    )
                }
            },
            persistenceKey: persistenceKey,
            notificationRescheduler: { _, _, _, _, _ in
                NotificationScheduleResult(requestedCount: 0, scheduledCount: 0, failedCount: 0, firstScheduledAt: nil)
            }
        )
        store.places = places

        let refresh = Task { @MainActor in await store.refreshAll() }
        let reachedConcurrencyLimit = await probe.waitForLimitOrTimeout()
        await probe.releaseAll()
        let refreshSucceeded = await refresh.value
        let snapshot = await probe.snapshot()
        let expectedLocations = Set(locations.map {
            "\($0.latitudeE4):\($0.longitudeE4)"
        })

        XCTAssertTrue(reachedConcurrencyLimit, "The first batch should exercise the configured request limit")
        XCTAssertEqual(snapshot.maximumConcurrentRequests, concurrencyLimit)
        XCTAssertEqual(snapshot.startedLocations, expectedLocations)
        XCTAssertEqual(snapshot.startedLocations.count, locations.count)
        XCTAssertTrue(refreshSucceeded)
    }

    @MainActor
    func testBackgroundRefreshUsesOneRequestForFavoriteAndPositionAlias() {
        let favorite = Place(name: "Klinga", lat: 64.409401, lon: 11.477861)
        let position = Place(name: "Min posisjon", lat: 64.409402, lon: 11.477862)
        XCTAssertEqual(Store.forecastLocations(in: [favorite, position]).count, 1)
        XCTAssertEqual(Store.groupedByForecastLocation([favorite, position]).values.first?.count, 2)
    }

    @MainActor
    func testLaunchPlacesUseRequestedNamesAndPrepositions() {
        XCTAssertEqual(Store.launchPlaces.map(\.nameWithPreposition), [
            "på Klinga", "nerri Namsos", "oppå Hornburu", "oppi Selbu", "inni Bangdalen"
        ])
    }

    @MainActor
    func testLaunchPlacesSmokeDataIsUsableForPlanning() {
        let places = Store.launchPlaces
        XCTAssertEqual(places.count, 5)
        XCTAssertEqual(Set(places.map { $0.name.lowercased() }).count, places.count)
        let hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 2, cloud: 20, dew: 4, gust: 4)
        for place in places {
            XCTAssertNoThrow(_ = Planner.planAll(places: [place], forecasts: [place.id: [hour]]))
        }
    }

    @MainActor
    func testPlaceSearchPublishesOnlyNewestOverlappingRequest() async {
        var pending: [String: CheckedContinuation<[PlaceSearchResult], Error>] = [:]
        let oldStarted = expectation(description: "Older place search started")
        let newStarted = expectation(description: "Newer place search started")
        let model = PlaceSearchModel { query, _ in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[PlaceSearchResult], Error>) in
                pending[query] = continuation
                (query == "old" ? oldStarted : newStarted).fulfill()
            }
        }

        model.query = "old"
        let oldSearch = Task { await model.search() }
        await fulfillment(of: [oldStarted], timeout: 5)

        model.query = "new"
        let newSearch = Task { await model.search() }
        await fulfillment(of: [newStarted], timeout: 5)

        let newestResult = PlaceSearchResult(
            id: "new", name: "Ny", subtitle: "", latitude: 64.4, longitude: 11.4
        )
        pending["new"]?.resume(returning: [newestResult])
        await newSearch.value
        XCTAssertEqual(model.results.map(\.id), ["new"])

        let olderResult = PlaceSearchResult(
            id: "old", name: "Gammel", subtitle: "", latitude: 64.5, longitude: 11.5
        )
        pending["old"]?.resume(returning: [olderResult])
        await oldSearch.value
        XCTAssertEqual(model.results.map(\.id), ["new"])
    }

    @MainActor
    func testPlaceSearchInvalidatesDisplayedResultsImmediatelyWhenInputsChange() {
        let model = PlaceSearchModel { _, _ in [] }
        let stale = PlaceSearchResult(id: "old", name: "Gammel", subtitle: "", latitude: 64.5, longitude: 11.5)
        model.results = [stale]
        model.message = "Old search message"
        model.isSearching = true

        model.query = "New place"

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isSearching)

        model.results = [stale]
        model.message = "Old search message"
        model.scope = .world

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isSearching)
    }

    @MainActor
    func testPlaceSearchCancellationCancelsTheUnderlyingOperation() async {
        let cancelled = expectation(description: "The active MapKit operation is cancelled")
        let search = Task {
            try await PlaceSearchCancellation.run(
                operation: {
                    try await Task.sleep(for: .seconds(60))
                    return [PlaceSearchResult(id: "stale", name: "Old", subtitle: "", latitude: 0, longitude: 0)]
                },
                cancel: { cancelled.fulfill() }
            )
        }

        search.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        do {
            _ = try await search.value
            XCTFail("A cancelled place search must not return a result")
        } catch is CancellationError {
            // Expected: cancelling the Swift task also cancels its operation.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }

    func testPlaceSearchCopyUsesSelectedLanguageForControlsAndMessages() {
        XCTAssertEqual(PlaceSearchCopy.searchPlaceholder(.english), "Search for a city or place")
        XCTAssertEqual(PlaceSearchCopy.addPlaceTitle(.english), "Add place")
        XCTAssertEqual(PlaceSearchCopy.close(.english), "Close")
        XCTAssertEqual(PlaceSearchCopy.searchAreaTitle(.english), "Search area")
        XCTAssertEqual(PlaceSearchCopy.searchArea(.norway, style: .english), "Norway")
        XCTAssertEqual(PlaceSearchCopy.searchArea(.world, style: .english), "Worldwide")
        XCTAssertEqual(PlaceSearchCopy.prepositionHeading(.english), "Write the place with")
        XCTAssertEqual(PlaceSearchCopy.prepositionAccessibilityLabel(.english), "Preposition")
        XCTAssertEqual(
            PlacePreposition.allCases.map { PlaceSearchCopy.preposition($0, style: .english) },
            ["on", "in", "inside", "in", "near", "on", "on", "in", "on", "near", "on", "in", "on", "at", "near"]
        )
        XCTAssertEqual(PlaceSearchCopy.noNorwayResults(.english), "No places found in Norway. Try “Worldwide” or a nearby place name.")
        XCTAssertEqual(PlaceSearchCopy.noResults(.english), "No matching places found.")
        XCTAssertEqual(PlaceSearchCopy.networkError(.english), "The search could not be completed. Check your connection and try again.")
        XCTAssertEqual(PlaceSearchCopy.searchPlaceholder(.bokmal), "Søk etter by eller sted")
        XCTAssertEqual(PlaceSearchCopy.searchArea(.world, style: .inntrondersk), WeatherLanguage.text("Hele verden", style: .inntrondersk))
    }

    func testPlaceSearchPrepositionTraitsExposeTheSelectedChoice() {
        let selected = PlaceSearchCopy.prepositionAccessibilityTraits(.pa, selectedValue: .pa)
        let unselected = PlaceSearchCopy.prepositionAccessibilityTraits(.i, selectedValue: .pa)

        XCTAssertTrue(selected.contains(.isSelected))
        XCTAssertFalse(unselected.contains(.isSelected))
    }

    func testPlaceSearchClearSearchCopyUsesSelectedLanguage() {
        XCTAssertEqual(PlaceSearchCopy.clearSearch(.english), "Clear search")
        XCTAssertEqual(PlaceSearchCopy.clearSearch(.bokmal), "Tøm søk")
    }

    @MainActor
    func testPlaceSearchEmptyAndFailureMessagesUseRequestedLanguage() async {
        let noNorwayResults = PlaceSearchModel { _, _ in [] }
        noNorwayResults.query = "zz"
        await noNorwayResults.search(languageStyle: .english)
        XCTAssertEqual(noNorwayResults.message, PlaceSearchCopy.noNorwayResults(.english))

        noNorwayResults.scope = .world
        await noNorwayResults.search(languageStyle: .english)
        XCTAssertEqual(noNorwayResults.message, PlaceSearchCopy.noResults(.english))

        let failedSearch = PlaceSearchModel { _, _ in throw NSError(domain: "PlaceSearch", code: 1) }
        failedSearch.query = "zz"
        await failedSearch.search(languageStyle: .english)
        XCTAssertEqual(failedSearch.message, PlaceSearchCopy.networkError(.english))
    }

    private static let locationForecastFixture = Data("""
    {"properties":{"timeseries":[
      {"time":"2033-05-18T10:00:00Z","data":{"instant":{"details":{"air_temperature":7,"relative_humidity":75,"wind_speed":3,"wind_speed_of_gust":7,"cloud_area_fraction":85}},"next_6_hours":{"details":{"precipitation_amount":6,"precipitation_amount_min":0,"precipitation_amount_max":12,"probability_of_precipitation":50}}}},
      {"time":"2033-05-18T12:00:00Z","data":{"instant":{"details":{"air_temperature":2,"dew_point_temperature":1,"wind_speed":5,"wind_speed_of_gust":11,"cloud_area_fraction":95}},"next_1_hours":{"details":{"precipitation_amount":0.8,"precipitation_amount_min":0.3,"precipitation_amount_max":1.2,"probability_of_precipitation":60}}}}
    ]}}
    """.utf8)

    private static let dryLocationForecastFixture = locationFixture(precipitation: 0)
    private static let rainyLocationForecastFixture = locationFixture(precipitation: 0.7)

    private static func locationFixture(precipitation: Double) -> Data {
        Data("""
        {"properties":{"timeseries":[
          {"time":"2033-05-18T10:00:00Z","data":{"instant":{"details":{"air_temperature":7,"relative_humidity":70,"wind_speed":2,"wind_speed_of_gust":5,"cloud_area_fraction":90}},"next_1_hours":{"details":{"precipitation_amount":\(precipitation),"precipitation_amount_min":0,"precipitation_amount_max":\(precipitation),"probability_of_precipitation":80}}}}
        ]}}
        """.utf8)
    }

    private static func nowcastFixture(rateAtFiveMinutes: Double) -> Data {
        Data("""
        {"properties":{"meta":{"radar_coverage":"ok"},"timeseries":[
          {"time":"2033-05-18T11:35:00Z","data":{"instant":{"details":{"precipitation_rate":8}}}},
          {"time":"2033-05-18T10:05:00Z","data":{"instant":{"details":{"precipitation_rate":\(rateAtFiveMinutes)}}}},
          {"time":"2033-05-18T10:00:00Z","data":{"instant":{"details":{"precipitation_rate":0,"air_temperature":8,"relative_humidity":80,"wind_speed":4,"wind_speed_of_gust":9}}}}
        ]}}
        """.utf8)
    }
}

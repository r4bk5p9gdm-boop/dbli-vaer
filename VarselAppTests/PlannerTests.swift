import XCTest
import UserNotifications
import CoreLocation
@testable import VarselApp

private final class FakeNotificationCenter: NotificationCenterClient {
    enum Failure: Error { case rejected }
    var pending: [UNNotificationRequest]
    var failedIDs: Set<String> = []

    init(pending: [UNNotificationRequest] = []) { self.pending = pending }

    func pendingNotificationRequests() async -> [UNNotificationRequest] { pending }

    func add(_ request: UNNotificationRequest) async throws {
        if failedIDs.contains(request.identifier) { throw Failure.rejected }
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

@MainActor
final class PlannerTests: XCTestCase {
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
        XCTAssertEqual(place.resolvedDisplaySunThreshold2, 50)
        place.displaySunThreshold2 = nil
        XCTAssertEqual(place.resolvedDisplaySunThreshold2, 20)
    }

    func testMalformedPlaceSnapshotUsesSafeDefaults() throws {
        let data = Data(#"{"name":" ","lat":"bad","lon":null,"rules":[{"type":"vind","threshold":"bad"}]}"#.utf8)
        let place = try JSONDecoder().decode(Place.self, from: data)
        XCTAssertEqual(place.name, "Ukjent sted")
        XCTAssertEqual(place.lat, 0)
        XCTAssertEqual(place.lon, 0)
        XCTAssertTrue(place.rules.isEmpty)
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

    func testWatchAndCarPlaySharePlaceAndThreeUpcomingEventTypes() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let forecast = [ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 40, dew: 4)]
        let statuses = [
            WeatherStatus(ruleID: UUID(), type: .regn, text: "Regn", eventAt: base.addingTimeInterval(30 * 60), isNow: false),
            WeatherStatus(ruleID: UUID(), type: .vind, text: "Vind", eventAt: base.addingTimeInterval(60 * 60), isNow: false),
            WeatherStatus(ruleID: UUID(), type: .dugg, text: "Duggfall", eventAt: base.addingTimeInterval(2 * 60 * 60), isNow: false),
            WeatherStatus(ruleID: UUID(), type: .sol, text: "Sol", eventAt: base.addingTimeInterval(3 * 60 * 60), isNow: false),
        ]
        XCTAssertEqual(WeatherGlance.nextEvents(statuses, now: base).prefix(3).map(\.type), [.regn, .vind, .dugg])

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

    func testSnowAmountConvertsWaterEquivalentUsingTemperature() {
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: 0), 4.179, accuracy: 0.01)
        XCTAssertEqual(estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: -2), 9.9, accuracy: 0.1)
        XCTAssertGreaterThan(estimatedFreshSnowMillimeters(waterEquivalent: 1, temperature: -5), 12)
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
        let dry = ForecastHour(time: base, temp: 8, wind: 1, cloud: 90, dew: 5)
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
        let dry = ForecastHour(time: base, temp: 8, wind: 1, cloud: 90, dew: 5)
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
        let dry = ForecastHour(time: base, temp: 8, wind: 1, cloud: 90, dew: 5)
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

    func testNotificationQueueSortsEqualTimesByWeatherSeverity() {
        let fireAt = base.addingTimeInterval(3_600)
        let rain = PlannedAlert(rule: Rule(type: .regn), placeID: UUID(), placeName: "Klinga",
                                eventAt: fireAt, fireAt: fireAt, index: 1, total: 1,
                                quiet: false, possible: false, eventDetail: nil)
        let frost = PlannedAlert(rule: Rule(type: .frost), placeID: UUID(), placeName: "Namsos",
                                 eventAt: fireAt, fireAt: fireAt, index: 1, total: 1,
                                 quiet: false, possible: false, eventDetail: nil)
        XCTAssertEqual(NotificationScheduler.alertsToSchedule([rain, frost], now: base, limit: 1).first?.rule.type, .frost)
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

    func testNotificationLogRetainsOnlyRecentEntries() {
        let old = LogEntry(time: base.addingTimeInterval(-73 * 3_600), text: "gammel")
        let recent = LogEntry(time: base.addingTimeInterval(-1 * 3_600), text: "ny")
        XCTAssertEqual(Store.retainedLog([recent, old], now: base).map(\.text), ["ny"])
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
        XCTAssertEqual(restored.selectedPlaceID, place.id)
        XCTAssertEqual(restored.places.first?.nameWithPreposition, "nerri Namsos")
        XCTAssertEqual(restored.places.first?.localTemperatureOffset, -1.5)
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

    func testOlderForecastCannotReplaceNewerCache() {
        XCTAssertFalse(Store.shouldReplaceForecast(existingAt: base, incomingAt: base.addingTimeInterval(-1)))
        XCTAssertTrue(Store.shouldReplaceForecast(existingAt: base, incomingAt: base.addingTimeInterval(1)))
        XCTAssertTrue(Store.shouldReplaceForecast(existingAt: nil, incomingAt: base))
    }

    func testWatchTransferPolicyRejectsDuplicateTimestamp() {
        XCTAssertTrue(WatchTransferPolicy.accepts(base.addingTimeInterval(1), after: base))
        XCTAssertFalse(WatchTransferPolicy.accepts(base, after: base))
        XCTAssertFalse(WatchTransferPolicy.accepts(base.addingTimeInterval(-1), after: base))
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

    func testEmptyForecastCannotReplaceLastValidSnapshot() {
        XCTAssertFalse(Store.isUsableForecast([]))
        XCTAssertTrue(Store.isUsableForecast(forecast(values: [(8, 0, 1, 40, 3)])))
    }

    func testManualPlaceRefreshRejectsEmptyYrResponseBeforeCaching() {
        XCTAssertFalse(Store.isUsableForecast([]), "Tomt Yr-svar skal ikke bli ny cache")
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
        let fetchedHour = ForecastHour(time: base, temp: 8, precip: 0, wind: 2, cloud: 40, dew: 4)
        let oldHour = ForecastHour(time: base, temp: 2, precip: 0, wind: 1, cloud: 90, dew: 0)
        let oldUpdate = Date().addingTimeInterval(-3 * 3_600)
        UserDefaults.standard.set(try JSONEncoder().encode(PersistedStoreState(
            places: [successful, failing], selectedID: successful.id, log: [],
            forecasts: [failing.id: [oldHour]],
            forecastUpdatedAt: [failing.id: oldUpdate], lastUpdate: oldUpdate
        )), forKey: persistenceKey)
        let store = Store(
            forecastFetcher: { latitude, _ in
                if latitude < 64.5 { return [fetchedHour] }
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
        XCTAssertEqual(store.forecasts[successful.id], [fetchedHour])
        XCTAssertEqual(store.forecasts[failing.id], [oldHour])
        XCTAssertEqual(store.forecastUpdatedAt(for: failing.id), oldUpdate)
        XCTAssertTrue(Store.isForecastStale(store.forecastUpdatedAt(for: failing.id)))
        XCTAssertFalse(Store.isForecastStale(store.forecastUpdatedAt(for: successful.id)))

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: persistenceKey))
        let persisted = try JSONDecoder().decode(PersistedStoreState.self, from: data)
        XCTAssertEqual(persisted.forecasts[successful.id], [fetchedHour])
        XCTAssertEqual(persisted.forecasts[failing.id], [oldHour])
        XCTAssertEqual(persisted.forecastUpdatedAt[failing.id], oldUpdate)
    }

    func testReplanDebounceRequiresSameStateAndShortInterval() {
        XCTAssertTrue(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 7, lastAt: base, now: base.addingTimeInterval(4)))
        XCTAssertFalse(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 8, lastAt: base, now: base.addingTimeInterval(1)))
        XCTAssertFalse(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 7, lastAt: base, now: base.addingTimeInterval(5)))
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
        XCTAssertTrue(Store.isUsableForecast([ForecastHour(time: base, temp: 10, precip: 0, wind: 1, cloud: 0, dew: 5)]))
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

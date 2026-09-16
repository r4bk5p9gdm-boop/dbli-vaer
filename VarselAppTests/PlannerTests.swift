import XCTest
import UserNotifications
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

final class PlannerTests: XCTestCase {
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
        var place = Place(name: "Klinga", lat: 64, lon: 11)
        place.displayDewThreshold = 2
        place.displaySunThreshold = 35
        place.displayGustThreshold = 11
        let copy = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(place))
        XCTAssertTrue(copy.rules.isEmpty)
        XCTAssertEqual(copy.rulesForDisplay.first { $0.type == .vind }?.threshold, 11)
        XCTAssertEqual(copy.rulesForDisplay.first { $0.type == .dugg }?.threshold, 2)
        XCTAssertEqual(copy.rulesForDisplay.first { $0.type == .sol }?.threshold, 35)
        XCTAssertEqual(WeatherLanguage.text("Under 10° nå", style: .inntrondersk, separator: .dash), "Under 10 no")
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

    func testDisabledRuleNeverCreatesPushAlert() {
        var rule = Rule(type: .regn)
        rule.enabled = false
        let place = Place(name: "Klinga", lat: 64, lon: 11, rules: [rule])
        let hours = forecast(values: [(6, 1, 1, 100, 4), (6, 1, 1, 100, 4)])
        XCTAssertTrue(Planner.planAll(places: [place], forecasts: [place.id: hours]).isEmpty)
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
        XCTAssertEqual(Planner.notificationEventDetail(rule: rule, hours: [hour], possible: false), "Vindkast opptil 9 m/s. Periode med vindkast: 1 time.")
        hour.gust = nil
        XCTAssertEqual(Planner.notificationEventDetail(rule: rule, hours: [hour], possible: false), "Vindkast ikke oppgitt. Varighet 1 time.")
        var strong = hour
        strong.gust = 20
        let text = try XCTUnwrap(Planner.notificationEventDetail(rule: rule, hours: [hour, strong], possible: false))
        XCTAssertTrue(text.contains("Kast mangler for deler av perioden."))
        XCTAssertTrue(text.contains(WindGustLevel.powerful.guidance))
    }

    func testWindStatusSeparatesWindAndGust() throws {
        var rule = Rule(type: .vind)
        rule.threshold = 9
        let place = Place(name: "Test", lat: 64, lon: 11)
        let status = WeatherStatus(ruleID: rule.id, type: .vind, text: "", eventAt: base, isNow: false)
        var hour = ForecastHour(time: base, temp: 10, precip: 0, wind: 3, cloud: 20, dew: 4)
        hour.gust = 9
        XCTAssertEqual(Planner.statusDetail(for: status, place: place, forecast: [hour]), "Vindkast 9 m/s")
        hour.gust = nil
        XCTAssertEqual(Planner.statusDetail(for: status, place: place, forecast: [hour]), "Vindkast ikke oppgitt")
        XCTAssertTrue(weatherAlertText(for: rule, eventAt: base.addingTimeInterval(3600), referenceAt: base).hasPrefix("Vindkast "))
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
        XCTAssertEqual(WeatherLanguage.text(source, style: .inntrondersk), "Regn i mårrå kl. 07, sjer d ut som.")
        XCTAssertEqual(WeatherLanguage.text("I overmorgen kl. 09.", style: .inntrondersk), "I overmårrå kl. 09.")
        XCTAssertEqual(WeatherLanguage.text("Fra 2 til 4 mm", style: .inntrondersk), "Fra 2 te 4 mm")
        XCTAssertEqual(WeatherLanguage.text("Duggfall i natt kl. 02.", style: .inntrondersk), "Doggfall i natt kl. 02.")
    }

    func testDialectUsesNoEOnlyForCurrentDewStatus() {
        XCTAssertEqual(WeatherLanguage.text("Fare for dugg nå.", style: .inntrondersk), "No e d doggfall.")
        XCTAssertEqual(WeatherLanguage.text("Fare for dugg i natt kl. 01.", style: .inntrondersk), "Doggfall i natt kl. 01.")
        XCTAssertEqual(WeatherLanguage.text("Duggfall i morgen kl. 07.", style: .inntrondersk), "Doggfall i mårrå kl. 07.")
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
            XCTAssertFalse(detail?.contains("kl.") == true, "Gjentar klokkeslett for \(type): \(detail ?? "")")
            XCTAssertFalse(detail?.contains("Neste hendelse") == true, "Gjentar hendelsen for \(type): \(detail ?? "")")
        }

        let dew = WeatherStatus(ruleID: UUID(), type: .dugg, text: "Duggfall i dag kl. 20.", eventAt: base, isNow: false)
        XCTAssertEqual(
            Planner.statusDetail(for: dew, place: place, forecast: [hour]),
            "Duggpunkt 2,9° · 0,4° forskjell fra lufttemperaturen"
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
        XCTAssertEqual(NotificationCopy.title(for: powerful), "D bli Kraftige vindkast!")
        XCTAssertEqual(NotificationCopy.title(for: extreme), "D bli Ekstreme vindkast!")
        XCTAssertEqual(WindGustLevel.forSpeed(31), .veryPowerful)
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
        XCTAssertEqual(NotificationCopy.title(for: Rule(type: .regn), possible: true), "D kan bli Regn!")
        XCTAssertEqual(NotificationCopy.title(for: Rule(type: .regn), placeName: "nerri Namsos", possible: true), "D kan bli Regn! nerri Namsos")
        XCTAssertEqual(
            NotificationCopy.title(
                for: Rule(type: .regn),
                placeName: "nerri Namsos",
                possible: true,
                languageStyle: .inntrondersk
            ),
            "D bli Regn! nerri Namsos, sjer d ut som"
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

    func testNotificationCopyKeepsDetailSeparateFromTimingAndMemo() {
        var rule = Rule(type: .regn)
        rule.customName = "Vann plantene"
        let body = NotificationCopy.message(
            for: rule,
            eventAt: base.addingTimeInterval(2 * 3_600),
            referenceAt: base,
            eventDetail: "Opptil 0,9 mm over 1 time."
        )

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], "Opptil 0,9 mm over 1 time.")
        XCTAssertEqual(lines[2], "Vann plantene")
        XCTAssertFalse(lines[1].contains("om to timer"))
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
        XCTAssertEqual(result.alerts.first?.eventDetail, "Ned mot 7° i 2 timer.")
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
        let place = Place(name: "Namsos", lat: 64.5, lon: 11.5, preposition: .nerri)
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
    func testWidgetFallbackKeepsActualForecastAgeAndCurrentName() throws {
        let place = Place(name: "Klinga", lat: 64, lon: 11)
        let hours = forecast(values: [(10, 0, 1, 10, 5)])
        let cached = WidgetWeatherSnapshot(place: place, forecast: hours, updatedAt: base)
        var renamed = place
        renamed.customName = "Hjemme"
        let snapshot = try XCTUnwrap(Store.widgetSnapshot(place: renamed, forecast: [], updatedAt: nil, cached: cached))
        XCTAssertEqual(snapshot.updatedAt, base)
        XCTAssertEqual(snapshot.forecast, hours)
        XCTAssertEqual(snapshot.place.customName, "Hjemme")
        let fresh = Store.widgetSnapshot(place: renamed, forecast: hours, updatedAt: base.addingTimeInterval(60), cached: cached)
        XCTAssertEqual(fresh?.updatedAt, base.addingTimeInterval(60))
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
        XCTAssertNil(Store.widgetSnapshot(place: place, forecast: hours, updatedAt: base, cached: cached, now: base.addingTimeInterval(7 * 3_600)))
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

    func testReplanDebounceRequiresSameStateAndShortInterval() {
        XCTAssertTrue(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 7, lastAt: base, now: base.addingTimeInterval(4)))
        XCTAssertFalse(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 8, lastAt: base, now: base.addingTimeInterval(1)))
        XCTAssertFalse(Store.shouldDebounceReplan(lastSignature: 7, currentSignature: 7, lastAt: base, now: base.addingTimeInterval(5)))
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

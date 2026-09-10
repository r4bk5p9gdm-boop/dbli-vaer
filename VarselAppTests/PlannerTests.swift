import XCTest
@testable import VarselApp

final class PlannerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 2_000_000_000)

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
        let hours = forecast(values: [(5, 0, 12, 80, 2)])

        let result = Planner.plan(rule: rule, forecast: hours, placeName: "Oslo", now: base)

        XCTAssertEqual(result.eventAt, base)
        XCTAssertTrue(result.alerts.isEmpty)
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

    func testWindGustLevelsProduceDifferentNotificationTitles() {
        var standard = Rule(type: .vind)
        standard.threshold = 12
        var powerful = standard
        powerful.threshold = 20
        var extreme = standard
        extreme.threshold = 40

        XCTAssertEqual(NotificationCopy.title(for: standard), "D bli Vind!")
        XCTAssertEqual(NotificationCopy.title(for: powerful), "D bli Kraftige vindkast!")
        XCTAssertEqual(NotificationCopy.title(for: extreme), "D bli Ekstreme vindkast!")
        XCTAssertEqual(WindGustLevel.forSpeed(31), .veryPowerful)
    }

    func testDewPointIsCalculatedFromTemperatureAndHumidity() {
        XCTAssertEqual(YrService.calculatedDewPoint(temperature: 20, relativeHumidity: 50), 9.3, accuracy: 0.2)
        XCTAssertEqual(YrService.calculatedDewPoint(temperature: 5, relativeHumidity: 100), 5, accuracy: 0.01)
    }

    func testNorwegianNotificationCopy() {
        let reference = base
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

    func testNearbyRainRulesDoNotCreateDuplicateNotifications() {
        var first = Rule(type: .regn)
        first.leadMinutes = 60
        var second = Rule(type: .regn)
        second.leadMinutes = 60
        let place = Place(name: "Namsos", lat: 64.5, lon: 11.5, rules: [first, second])
        let event = Date().addingTimeInterval(3 * 3_600)
        let hours = [ForecastHour(time: event, temp: 5, precip: 1, wind: 2, cloud: 100, dew: 4)]

        let alerts = Planner.planAll(places: [place], forecasts: [place.id: hours])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.placeID, place.id)
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

    @MainActor
    func testLaunchPlacesUseRequestedNamesAndPrepositions() {
        XCTAssertEqual(Store.launchPlaces.map(\.nameWithPreposition), [
            "på Klinga", "nerri Namsos", "oppå Hornburu", "oppi Selbu", "inni Bangdalen"
        ])
    }
}

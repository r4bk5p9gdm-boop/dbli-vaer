import XCTest
import UserNotifications
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
        XCTAssertFalse(LiveWeatherActivityPolicy.canContinue(movedAway, now: base))
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
            "Duggpunkt 2,9° · 0,4° fra lufta"
        )
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

    @MainActor
    func testPreservedAndNewNotificationsShareChronologicalCapacity() {
        let dates = (0..<80).reversed().map { (id: "request-\($0)", date: base.addingTimeInterval(Double($0))) }
        let ids = NotificationScheduler.nearestRequestIDs(dates)
        XCTAssertEqual(ids.count, 64)
        XCTAssertTrue(ids.contains("request-0"))
        XCTAssertTrue(ids.contains("request-63"))
        XCTAssertFalse(ids.contains("request-64"))
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

    @MainActor
    func testSuccessfulAndIntentionallyEmptyRefreshCanFinalize() {
        XCTAssertTrue(Store.shouldFinalizeRefresh(successfulPlaceCount: 3, failedPlaceCount: 0))
        XCTAssertTrue(Store.shouldFinalizeRefresh(successfulPlaceCount: 1, failedPlaceCount: 2))
        XCTAssertTrue(Store.shouldFinalizeRefresh(successfulPlaceCount: 0, failedPlaceCount: 0))
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
    func testForecastRequestsDeduplicateCoordinatesAtApiPrecision() {
        let first = Place(name: "Namsos", lat: 64.466241, lon: 11.495719)
        let alias = Place(name: "Sentrum", lat: 64.466239, lon: 11.495721)
        let other = Place(name: "Klinga", lat: 64.4094, lon: 11.47786)

        let groups = Store.groupedByForecastLocation([first, alias, other])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[ForecastLocation(place: first)]?.count, 2)
    }

    @MainActor
    func testLaunchPlacesUseRequestedNamesAndPrepositions() {
        XCTAssertEqual(Store.launchPlaces.map(\.nameWithPreposition), [
            "på Klinga", "nerri Namsos", "oppå Hornburu", "oppi Selbu", "inni Bangdalen"
        ])
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

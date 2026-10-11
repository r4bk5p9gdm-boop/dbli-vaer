import Foundation

enum YrForecastPayloadError: Error, Equatable {
    case tooLarge
    case tooManyTimeSteps
}

enum YrService {
    static let maximumLocationForecastPayloadBytes = 2_000_000
    static let maximumLocationForecastTimeSteps = 500

    // Deliberately broad physical limits: these reject corrupted payloads, not
    // rare but credible weather. MET publishes temperatures in °C, wind in
    // m/s, fractions/probabilities in %, and precipitation in mm or mm/h.
    private enum NumericRange {
        static let temperature = -100.0...70.0
        static let wind = 0.0...150.0
        static let percentage = 0.0...100.0
        static let precipitation = 0.0...1_000.0
    }

    private static func isPlausible(_ value: Double?, in range: ClosedRange<Double>) -> Bool {
        guard let value else { return true }
        return value.isFinite && range.contains(value)
    }

    // MET krever en identifiserende User-Agent.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let identifier = Bundle.main.bundleIdentifier ?? "no.mathias.VarselApp"
        return "VarselApp/\(version) (\(identifier))"
    }

    struct Response: Decodable {
        struct Properties: Decodable { let timeseries: [Series] }
        struct Series: Decodable { let time: Date; let data: DataBlock }
        struct DataBlock: Decodable {
            let instant: Instant
            let next_1_hours: Next?
            let next_6_hours: Next?
        }
        struct Instant: Decodable { let details: Details }
        struct Details: Decodable {
            let air_temperature: Double?
            let air_temperature_percentile_10: Double?
            let air_temperature_percentile_90: Double?
            let wind_speed: Double?
            let wind_speed_of_gust: Double?
            let cloud_area_fraction: Double?
            let dew_point_temperature: Double?
            let relative_humidity: Double?
            let fog_area_fraction: Double?
        }
        struct Next: Decodable { let details: NextDetails }
        struct NextDetails: Decodable {
            let precipitation_amount: Double?
            let precipitation_amount_min: Double?
            let precipitation_amount_max: Double?
            let probability_of_precipitation: Double?
        }
        let properties: Properties
    }

    private struct NowcastResponse: Decodable {
        struct Properties: Decodable {
            let meta: Meta
            let timeseries: [Series]
        }
        struct Meta: Decodable { let radar_coverage: String? }
        struct Series: Decodable { let time: Date; let data: DataBlock }
        struct DataBlock: Decodable { let instant: Instant }
        struct Instant: Decodable { let details: Details }
        struct Details: Decodable {
            let precipitation_rate: Double?
            let air_temperature: Double?
            let relative_humidity: Double?
            let wind_speed: Double?
            let wind_speed_of_gust: Double?
        }
        let properties: Properties
    }

    struct NowcastPayload {
        struct Observation {
            let time: Date
            let temperature: Double?
            let relativeHumidity: Double?
            let wind: Double?
            let gust: Double?
        }

        let hasRadarCoverage: Bool
        let samples: [PrecipitationSample]
        let observation: Observation?
    }

    static func calculatedDewPoint(temperature: Double, relativeHumidity: Double) -> Double {
        // Magnus-formelen, godt egnet for vanlig utetemperatur.
        let humidity = min(max(relativeHumidity, 0.1), 100) / 100
        let a = 17.62
        let b = 243.12
        let gamma = log(humidity) + (a * temperature) / (b + temperature)
        return (b * gamma) / (a - gamma)
    }

    static func fetch(lat: Double, lon: Double) async throws -> [ForecastHour] {
        async let locationForecast = fetchLocationForecast(lat: lat, lon: lon)
        async let nowcast = try? fetchNowcast(lat: lat, lon: lon)

        var forecast = try await locationForecast
        if let radar = await nowcast {
            forecast = applying(nowcast: radar, to: forecast)
        }
        return forecast
    }

    static func ninetyMinuteNowcast(from samples: [PrecipitationSample]) -> [PrecipitationSample] {
        let sorted = samples.sorted { $0.time < $1.time }
        guard let start = sorted.first?.time else { return [] }
        let end = start.addingTimeInterval(90 * 60)
        var byTime: [Date: PrecipitationSample] = [:]
        for sample in sorted where sample.time <= end {
            // MET can repeat a timestamp when radar tiles are refreshed.
            // Keep the highest rate so the short-range warning is safe and
            // deterministic instead of producing duplicate samples/events.
            if byTime[sample.time].map({ $0.rate >= sample.rate }) != true {
                byTime[sample.time] = sample
            }
        }
        return byTime.values.sorted { $0.time < $1.time }
    }

    static func merging(radarSamples: [PrecipitationSample], into forecast: [ForecastHour]) -> [ForecastHour] {
        forecast.map { hour in
            var updated = hour
            let end = hour.time.addingTimeInterval(3_600)
            let samples = radarSamples.filter { $0.time >= hour.time && $0.time < end }
            if !samples.isEmpty { updated.radarSamples = samples }
            return updated
        }
    }

    static func applying(nowcast: NowcastPayload, to forecast: [ForecastHour]) -> [ForecastHour] {
        // A dry/empty radar sample is never evidence that table precipitation
        // should be removed; only covered samples may refine the table.
        guard nowcast.hasRadarCoverage else { return forecast }
        var updated = merging(radarSamples: ninetyMinuteNowcast(from: nowcast.samples), into: forecast)

        if let observation = nowcast.observation,
           let index = updated.indices.min(by: {
               abs(updated[$0].time.timeIntervalSince(observation.time)) < abs(updated[$1].time.timeIntervalSince(observation.time))
           }), abs(updated[index].time.timeIntervalSince(observation.time)) <= 3_600 {
            if let temperature = observation.temperature {
                updated[index].temp = temperature
                if let humidity = observation.relativeHumidity {
                    updated[index].dew = calculatedDewPoint(temperature: temperature, relativeHumidity: humidity)
                }
            }
            if let wind = observation.wind { updated[index].wind = wind }
            if let gust = observation.gust { updated[index].gust = gust }
        }
        return updated
    }

    private static func fetchLocationForecast(lat: Double, lon: Double) async throws -> [ForecastHour] {
        var comps = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/complete")!
        comps.queryItems = [
            .init(name: "lat", value: String(format: "%.4f", lat)),
            .init(name: "lon", value: String(format: "%.4f", lon)),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decodeLocationForecast(data)
    }

    static func decodeLocationForecast(_ data: Data) throws -> [ForecastHour] {
        guard data.count <= maximumLocationForecastPayloadBytes else {
            throw YrForecastPayloadError.tooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Response.self, from: data)
        guard response.properties.timeseries.count <= maximumLocationForecastTimeSteps else {
            throw YrForecastPayloadError.tooManyTimeSteps
        }
        var hoursByTime: [Date: (resolution: Int, hour: ForecastHour)] = [:]

        for series in response.properties.timeseries {
            let periodHours: Int
            let next: Response.Next
            if let hourly = series.data.next_1_hours {
                periodHours = 1
                next = hourly
            } else if let sixHourly = series.data.next_6_hours {
                periodHours = 6
                next = sixHourly
            } else {
                continue
            }
            let details = series.data.instant.details
            guard let temperature = details.air_temperature,
                  isPlausible(temperature, in: NumericRange.temperature),
                  isPlausible(details.air_temperature_percentile_10, in: NumericRange.temperature),
                  isPlausible(details.air_temperature_percentile_90, in: NumericRange.temperature),
                  isPlausible(details.wind_speed, in: NumericRange.wind),
                  isPlausible(details.wind_speed_of_gust, in: NumericRange.wind),
                  isPlausible(details.cloud_area_fraction, in: NumericRange.percentage),
                  isPlausible(details.dew_point_temperature, in: NumericRange.temperature),
                  isPlausible(details.relative_humidity, in: NumericRange.percentage),
                  isPlausible(details.fog_area_fraction, in: NumericRange.percentage),
                  isPlausible(next.details.precipitation_amount, in: NumericRange.precipitation),
                  isPlausible(next.details.precipitation_amount_min, in: NumericRange.precipitation),
                  isPlausible(next.details.precipitation_amount_max, in: NumericRange.precipitation),
                  isPlausible(next.details.probability_of_precipitation, in: NumericRange.percentage) else {
                continue
            }
            if let minimum = next.details.precipitation_amount_min,
               let maximum = next.details.precipitation_amount_max,
               minimum > maximum { continue }
            if let low = details.air_temperature_percentile_10,
               let high = details.air_temperature_percentile_90,
               low > high { continue }
            let dewPoint = details.dew_point_temperature
                ?? details.relative_humidity.map { calculatedDewPoint(temperature: temperature, relativeHumidity: $0) }
                ?? temperature
            let divisor = Double(periodHours)
            for offset in 0..<periodHours {
                let hour = ForecastHour(
                    time: series.time.addingTimeInterval(TimeInterval(offset * 3_600)),
                    temp: temperature,
                    precip: (next.details.precipitation_amount ?? 0) / divisor,
                    wind: details.wind_speed ?? 0,
                    cloud: details.cloud_area_fraction ?? 0,
                    dew: dewPoint,
                    precipMin: next.details.precipitation_amount_min.map { $0 / divisor },
                    precipMax: next.details.precipitation_amount_max.map { $0 / divisor },
                    precipProbability: next.details.probability_of_precipitation,
                    gust: details.wind_speed_of_gust,
                    fog: details.fog_area_fraction,
                    temperatureLow: details.air_temperature_percentile_10,
                    temperatureHigh: details.air_temperature_percentile_90
                )
                if hoursByTime[hour.time].map({ periodHours < $0.resolution }) ?? true {
                    hoursByTime[hour.time] = (periodHours, hour)
                }
            }
        }

        return hoursByTime.values
            .map(\.hour)
            .sorted { $0.time < $1.time }
            .prefix(9 * 24)
            .map { $0 }
    }

    private static func fetchNowcast(lat: Double, lon: Double) async throws -> NowcastPayload {
        var comps = URLComponents(string: "https://api.met.no/weatherapi/nowcast/2.0/complete")!
        comps.queryItems = [
            .init(name: "lat", value: String(format: "%.4f", lat)),
            .init(name: "lon", value: String(format: "%.4f", lon)),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decodeNowcast(data)
    }

    static func decodeNowcast(_ data: Data) throws -> NowcastPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(NowcastResponse.self, from: data)
        let ordered = response.properties.timeseries.sorted { $0.time < $1.time }
        let samples = ordered.compactMap { series in
            guard let rate = series.data.instant.details.precipitation_rate,
                  isPlausible(rate, in: NumericRange.precipitation) else { return nil }
            return PrecipitationSample(time: series.time, rate: rate)
        }
        let observation = ordered.first.map { series in
            let details = series.data.instant.details
            return NowcastPayload.Observation(
                time: series.time,
                temperature: isPlausible(details.air_temperature, in: NumericRange.temperature) ? details.air_temperature : nil,
                relativeHumidity: isPlausible(details.relative_humidity, in: NumericRange.percentage) ? details.relative_humidity : nil,
                wind: isPlausible(details.wind_speed, in: NumericRange.wind) ? details.wind_speed : nil,
                gust: isPlausible(details.wind_speed_of_gust, in: NumericRange.wind) ? details.wind_speed_of_gust : nil
            )
        }
        return NowcastPayload(
            hasRadarCoverage: response.properties.meta.radar_coverage?.lowercased() == "ok",
            samples: samples,
            observation: observation
        )
    }
}

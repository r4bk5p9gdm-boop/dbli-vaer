import Foundation

enum YrService {
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
        if let radar = await nowcast, radar.properties.meta.radar_coverage?.lowercased() == "ok" {
            let allSamples = radar.properties.timeseries.compactMap { series in
                series.data.instant.details.precipitation_rate.map {
                    PrecipitationSample(time: series.time, rate: $0)
                }
            }
            let samples = ninetyMinuteNowcast(from: allSamples)
            forecast = merging(radarSamples: samples, into: forecast)

            if let observation = radar.properties.timeseries.first,
               let index = forecast.indices.min(by: {
                   abs(forecast[$0].time.timeIntervalSince(observation.time)) < abs(forecast[$1].time.timeIntervalSince(observation.time))
               }), abs(forecast[index].time.timeIntervalSince(observation.time)) <= 3_600 {
                let details = observation.data.instant.details
                if let temperature = details.air_temperature {
                    forecast[index].temp = temperature
                    if let humidity = details.relative_humidity {
                        forecast[index].dew = calculatedDewPoint(temperature: temperature, relativeHumidity: humidity)
                    }
                }
                if let wind = details.wind_speed { forecast[index].wind = wind }
                if let gust = details.wind_speed_of_gust { forecast[index].gust = gust }
            }
        }
        return forecast
    }

    static func ninetyMinuteNowcast(from samples: [PrecipitationSample]) -> [PrecipitationSample] {
        let sorted = samples.sorted { $0.time < $1.time }
        guard let start = sorted.first?.time else { return [] }
        let end = start.addingTimeInterval(90 * 60)
        return sorted.filter { $0.time <= end }
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
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let r = try dec.decode(Response.self, from: data)
        return r.properties.timeseries.flatMap { s -> [ForecastHour] in
            let periodHours: Int
            let next: Response.Next
            if let hourly = s.data.next_1_hours {
                periodHours = 1
                next = hourly
            } else if let sixHourly = s.data.next_6_hours {
                periodHours = 6
                next = sixHourly
            } else {
                return []
            }
            let d = s.data.instant.details
            guard let temperature = d.air_temperature else { return [] }
            let dewPoint = d.dew_point_temperature
                ?? d.relative_humidity.map { calculatedDewPoint(temperature: temperature, relativeHumidity: $0) }
                ?? temperature
            let divisor = Double(periodHours)
            return (0..<periodHours).map { offset in
                ForecastHour(
                    time: s.time.addingTimeInterval(TimeInterval(offset * 3_600)),
                    temp: temperature,
                    precip: (next.details.precipitation_amount ?? 0) / divisor,
                    wind: d.wind_speed ?? 0,
                    cloud: d.cloud_area_fraction ?? 0,
                    dew: dewPoint,
                    precipMin: next.details.precipitation_amount_min.map { $0 / divisor },
                    precipMax: next.details.precipitation_amount_max.map { $0 / divisor },
                    precipProbability: next.details.probability_of_precipitation,
                    gust: d.wind_speed_of_gust,
                    fog: d.fog_area_fraction,
                    temperatureLow: d.air_temperature_percentile_10,
                    temperatureHigh: d.air_temperature_percentile_90
                )
            }
        }.prefix(9 * 24).map { $0 }
    }

    private static func fetchNowcast(lat: Double, lon: Double) async throws -> NowcastResponse {
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NowcastResponse.self, from: data)
    }
}

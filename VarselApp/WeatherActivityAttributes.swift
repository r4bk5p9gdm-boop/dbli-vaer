import ActivityKit
import Foundation

struct WeatherActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let eventAt: Date
        let expectedEndAt: Date
        let detail: String
        let possible: Bool
        let updatedAt: Date
    }

    let placeID: UUID
    let ruleID: UUID
    let placeName: String
    let alertType: String
    let weatherName: String
}


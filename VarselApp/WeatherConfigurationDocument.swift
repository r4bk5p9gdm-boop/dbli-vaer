import SwiftUI
import UniformTypeIdentifiers

struct WeatherConfigurationExport: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let selectedPlaceID: UUID?
    let alertLanguageStyle: AlertLanguageStyle?
    let places: [Place]

    init(places: [Place], selectedPlaceID: UUID?, alertLanguageStyle: AlertLanguageStyle) {
        formatVersion = 1
        exportedAt = Date()
        self.selectedPlaceID = selectedPlaceID
        self.alertLanguageStyle = alertLanguageStyle
        self.places = places
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, selectedPlaceID, alertLanguageStyle, places
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? values.decode(Int.self, forKey: .formatVersion)) ?? 1
        exportedAt = (try? values.decode(Date.self, forKey: .exportedAt)) ?? .distantPast
        selectedPlaceID = try? values.decode(UUID.self, forKey: .selectedPlaceID)
        alertLanguageStyle = try? values.decode(AlertLanguageStyle.self, forKey: .alertLanguageStyle)
        places = (try? values.decode([LossyDecodable<Place>].self, forKey: .places))?.compactMap(\.value) ?? []
    }
}

struct WeatherConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let configuration: WeatherConfigurationExport

    init(places: [Place], selectedPlaceID: UUID?, alertLanguageStyle: AlertLanguageStyle) {
        configuration = WeatherConfigurationExport(places: places, selectedPlaceID: selectedPlaceID, alertLanguageStyle: alertLanguageStyle)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.configuration = try decoder.decode(WeatherConfigurationExport.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return FileWrapper(regularFileWithContents: try encoder.encode(self.configuration))
    }
}

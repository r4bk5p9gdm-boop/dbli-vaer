import SwiftUI
import UniformTypeIdentifiers

struct WeatherConfigurationExport: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let selectedPlaceID: UUID?
    let alertLanguageStyle: AlertLanguageStyle?
    let places: [Place]

    init(places: [Place], selectedPlaceID: UUID?, alertLanguageStyle: AlertLanguageStyle) {
        formatVersion = Self.currentFormatVersion
        exportedAt = Date()
        self.places = places
        self.selectedPlaceID = Self.resolvedSelection(selectedPlaceID, in: places)
        self.alertLanguageStyle = alertLanguageStyle
    }

    private static func resolvedSelection(_ selectedPlaceID: UUID?, in places: [Place]) -> UUID? {
        if let selectedPlaceID, places.contains(where: { $0.id == selectedPlaceID }) {
            return selectedPlaceID
        }
        return places.first?.id
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, selectedPlaceID, alertLanguageStyle, places
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFormatVersion = (try? values.decode(Int.self, forKey: .formatVersion)) ?? 1
        guard decodedFormatVersion <= Self.currentFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: values,
                debugDescription: "Unsupported configuration format version \(decodedFormatVersion); this app supports up to \(Self.currentFormatVersion)."
            )
        }
        formatVersion = decodedFormatVersion
        exportedAt = (try? values.decode(Date.self, forKey: .exportedAt)) ?? .distantPast
        alertLanguageStyle = try? values.decode(AlertLanguageStyle.self, forKey: .alertLanguageStyle)
        places = (try? values.decode([LossyDecodable<Place>].self, forKey: .places))?.compactMap(\.value) ?? []
        let decodedSelection = try? values.decode(UUID.self, forKey: .selectedPlaceID)
        selectedPlaceID = Self.resolvedSelection(decodedSelection, in: places)
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

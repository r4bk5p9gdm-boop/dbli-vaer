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

    private static func uniquePlaces(_ places: [Place]) -> [Place] {
        var seenIDs = Set<UUID>()
        return places.filter { seenIDs.insert($0.id).inserted }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, selectedPlaceID, alertLanguageStyle, places
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFormatVersion = (try? values.decode(Int.self, forKey: .formatVersion)) ?? 1
        guard (1...Self.currentFormatVersion).contains(decodedFormatVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: values,
                debugDescription: "Unsupported configuration format version \(decodedFormatVersion); this app supports versions 1 through \(Self.currentFormatVersion)."
            )
        }
        formatVersion = decodedFormatVersion
        exportedAt = (try? values.decode(Date.self, forKey: .exportedAt)) ?? .distantPast
        alertLanguageStyle = try? values.decode(AlertLanguageStyle.self, forKey: .alertLanguageStyle)
        let decodedPlaces = (try? values.decode([LossyDecodable<Place>].self, forKey: .places))?.compactMap(\.value) ?? []
        places = Self.uniquePlaces(decodedPlaces)
        let decodedSelection = try? values.decode(UUID.self, forKey: .selectedPlaceID)
        selectedPlaceID = Self.resolvedSelection(decodedSelection, in: places)
    }
}

struct WeatherConfigurationDocument: FileDocument {
    static let maximumImportSizeBytes = 5 * 1_024 * 1_024
    static var readableContentTypes: [UTType] { [.json] }
    let configuration: WeatherConfigurationExport

    init(places: [Place], selectedPlaceID: UUID?, alertLanguageStyle: AlertLanguageStyle) {
        configuration = WeatherConfigurationExport(places: places, selectedPlaceID: selectedPlaceID, alertLanguageStyle: alertLanguageStyle)
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(file: configuration.file)
    }

    init(file: FileWrapper) throws {
        guard let data = file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(data: data)
    }

    init(data: Data) throws {
        guard data.count <= Self.maximumImportSizeBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.configuration = try decoder.decode(WeatherConfigurationExport.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try serializedData())
    }

    func serializedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self.configuration)
    }
}

enum ConfigurationExportFailure {
    static func message(for error: Error, languageStyle: AlertLanguageStyle) -> String? {
        let systemError = error as NSError
        let wasCancelled = error is CancellationError
            || (systemError.domain == NSCocoaErrorDomain && systemError.code == NSUserCancelledError)
        guard !wasCancelled else { return nil }
        if languageStyle == .english {
            return "Try exporting again, and choose a different location if the problem continues."
        }
        return WeatherLanguage.text(
            "Prøv eksporten på nytt, og velg en annen plassering hvis problemet fortsetter.",
            style: languageStyle
        )
    }
}

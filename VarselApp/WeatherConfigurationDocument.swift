import SwiftUI
import UniformTypeIdentifiers

struct ApplicationSettingsBackup: Codable, Equatable {
    var homeFavorites: HomeFavorites
    var homePlaceID: String
    var cabinPlaceID: String
    var placeSortMode: String
    var homeShortcutTitle: String
    var cabinShortcutTitle: String
    var textSeparator: String
    var watchPlaceSource: String
    var watchFixedPlaceID: String
    var liveWeatherActivitiesEnabled: Bool

    init(
        homeFavorites: HomeFavorites,
        defaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = WeatherTextSeparator.defaults
    ) {
        self.homeFavorites = homeFavorites
        homePlaceID = defaults.string(forKey: PlaceOrderingSettings.homePlaceIDKey) ?? ""
        cabinPlaceID = defaults.string(forKey: PlaceOrderingSettings.cabinPlaceIDKey) ?? ""
        placeSortMode = defaults.string(forKey: PlaceOrderingSettings.sortModeKey) ?? "automatic"
        homeShortcutTitle = defaults.string(forKey: PlaceOrderingSettings.homeShortcutTitleKey) ?? ""
        cabinShortcutTitle = defaults.string(forKey: PlaceOrderingSettings.cabinShortcutTitleKey) ?? ""
        textSeparator = sharedDefaults?.string(forKey: WeatherTextSeparator.key) ?? WeatherTextSeparator.space.rawValue
        watchPlaceSource = defaults.string(forKey: WatchPlaceSettings.sourceKey) ?? WatchPlaceSource.position.rawValue
        watchFixedPlaceID = defaults.string(forKey: WatchPlaceSettings.fixedPlaceIDKey) ?? ""
        liveWeatherActivitiesEnabled = defaults.object(forKey: LiveWeatherActivitySettings.enabledKey) == nil
            ? true
            : defaults.bool(forKey: LiveWeatherActivitySettings.enabledKey)
    }

    func resolved(availablePlaceIDs: Set<UUID>) -> Self {
        func validID(_ rawValue: String) -> String {
            guard let id = UUID(uuidString: rawValue), availablePlaceIDs.contains(id) else { return "" }
            return id.uuidString
        }
        let resolvedSeparator = WeatherTextSeparator(rawValue: textSeparator) ?? .space
        let resolvedWatchSource = WatchPlaceSource(rawValue: watchPlaceSource) ?? .position
        let titleLimit = 120
        return Self(
            homeFavorites: homeFavorites.resolved(availableIDs: availablePlaceIDs),
            homePlaceID: validID(homePlaceID),
            cabinPlaceID: validID(cabinPlaceID),
            placeSortMode: ["automatic", "manual"].contains(placeSortMode) ? placeSortMode : "automatic",
            homeShortcutTitle: String(homeShortcutTitle.prefix(titleLimit)),
            cabinShortcutTitle: String(cabinShortcutTitle.prefix(titleLimit)),
            textSeparator: resolvedSeparator.rawValue,
            watchPlaceSource: resolvedWatchSource.rawValue,
            watchFixedPlaceID: validID(watchFixedPlaceID),
            liveWeatherActivitiesEnabled: liveWeatherActivitiesEnabled
        )
    }

    func persist(
        to defaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults? = WeatherTextSeparator.defaults
    ) {
        defaults.set(homePlaceID, forKey: PlaceOrderingSettings.homePlaceIDKey)
        defaults.set(cabinPlaceID, forKey: PlaceOrderingSettings.cabinPlaceIDKey)
        defaults.set(placeSortMode, forKey: PlaceOrderingSettings.sortModeKey)
        defaults.set(homeShortcutTitle, forKey: PlaceOrderingSettings.homeShortcutTitleKey)
        defaults.set(cabinShortcutTitle, forKey: PlaceOrderingSettings.cabinShortcutTitleKey)
        sharedDefaults?.set(textSeparator, forKey: WeatherTextSeparator.key)
        defaults.set(watchPlaceSource, forKey: WatchPlaceSettings.sourceKey)
        defaults.set(watchFixedPlaceID, forKey: WatchPlaceSettings.fixedPlaceIDKey)
        defaults.set(liveWeatherActivitiesEnabled, forKey: LiveWeatherActivitySettings.enabledKey)
    }

    init(
        homeFavorites: HomeFavorites, homePlaceID: String, cabinPlaceID: String,
        placeSortMode: String, homeShortcutTitle: String, cabinShortcutTitle: String,
        textSeparator: String, watchPlaceSource: String, watchFixedPlaceID: String,
        liveWeatherActivitiesEnabled: Bool
    ) {
        self.homeFavorites = homeFavorites
        self.homePlaceID = homePlaceID
        self.cabinPlaceID = cabinPlaceID
        self.placeSortMode = placeSortMode
        self.homeShortcutTitle = homeShortcutTitle
        self.cabinShortcutTitle = cabinShortcutTitle
        self.textSeparator = textSeparator
        self.watchPlaceSource = watchPlaceSource
        self.watchFixedPlaceID = watchFixedPlaceID
        self.liveWeatherActivitiesEnabled = liveWeatherActivitiesEnabled
    }
}

struct WeatherConfigurationExport: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let selectedPlaceID: UUID?
    let alertLanguageStyle: AlertLanguageStyle?
    let appSettings: ApplicationSettingsBackup?
    let places: [Place]

    init(
        places: [Place], selectedPlaceID: UUID?, alertLanguageStyle: AlertLanguageStyle,
        appSettings: ApplicationSettingsBackup? = nil
    ) {
        formatVersion = Self.currentFormatVersion
        exportedAt = Date()
        self.places = places
        self.selectedPlaceID = Self.resolvedSelection(selectedPlaceID, in: places)
        self.alertLanguageStyle = alertLanguageStyle
        self.appSettings = appSettings
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
        case formatVersion, exportedAt, selectedPlaceID, alertLanguageStyle, appSettings, places
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
        appSettings = try? values.decode(ApplicationSettingsBackup.self, forKey: .appSettings)
        let decodedPlaces = try values.decode([LossyDecodable<Place>].self, forKey: .places).compactMap(\.value)
        places = Self.uniquePlaces(decodedPlaces)
        let decodedSelection = try? values.decode(UUID.self, forKey: .selectedPlaceID)
        selectedPlaceID = Self.resolvedSelection(decodedSelection, in: places)
    }
}

enum ConfigurationImportMode {
    case replace
    case merge
}

struct ConfigurationImportPlan {
    let places: [Place]
    let selectedPlaceID: UUID?
    let alertLanguageStyle: AlertLanguageStyle
    let addedPlaceCount: Int
    let updatedPlaceCount: Int
    let preservedPlaceCount: Int
    let importedPlaceCount: Int
    let appSettings: ApplicationSettingsBackup?

    var canApply: Bool { importedPlaceCount > 0 && !places.isEmpty }

    init(
        configuration: WeatherConfigurationExport,
        currentPlaces: [Place],
        currentSelection: UUID?,
        currentLanguageStyle: AlertLanguageStyle,
        mode: ConfigurationImportMode
    ) {
        let incoming = configuration.places
        importedPlaceCount = incoming.count
        let currentByID = Dictionary(currentPlaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(incoming.map(\.id))

        switch mode {
        case .replace:
            places = incoming
            addedPlaceCount = incoming.filter { currentByID[$0.id] == nil }.count
            updatedPlaceCount = incoming.filter { currentByID[$0.id] != nil }.count
            preservedPlaceCount = 0
            selectedPlaceID = configuration.selectedPlaceID.flatMap { id in
                incoming.contains(where: { $0.id == id }) ? id : nil
            } ?? incoming.first?.id
        case .merge:
            var merged = currentPlaces.map { existing in
                incoming.first(where: { $0.id == existing.id }) ?? existing
            }
            let newPlaces = incoming.filter { currentByID[$0.id] == nil }
            merged.append(contentsOf: newPlaces)
            places = merged
            addedPlaceCount = newPlaces.count
            updatedPlaceCount = incoming.filter { currentByID[$0.id] != nil }.count
            preservedPlaceCount = currentPlaces.filter { !incomingIDs.contains($0.id) }.count
            selectedPlaceID = configuration.selectedPlaceID.flatMap { id in
                merged.contains(where: { $0.id == id }) ? id : nil
            } ?? currentSelection.flatMap { id in merged.contains(where: { $0.id == id }) ? id : nil }
                ?? merged.first?.id
        }
        alertLanguageStyle = configuration.alertLanguageStyle ?? currentLanguageStyle
        appSettings = configuration.appSettings?.resolved(availablePlaceIDs: Set(places.map(\.id)))
    }
}

struct WeatherConfigurationDocument: FileDocument {
    static let maximumImportSizeBytes = 5 * 1_024 * 1_024
    private static let importReadChunkSize = 64 * 1_024
    static var readableContentTypes: [UTType] { [.json] }
    let configuration: WeatherConfigurationExport

    init(
        places: [Place], selectedPlaceID: UUID?, alertLanguageStyle: AlertLanguageStyle,
        appSettings: ApplicationSettingsBackup? = nil
    ) {
        configuration = WeatherConfigurationExport(
            places: places, selectedPlaceID: selectedPlaceID,
            alertLanguageStyle: alertLanguageStyle, appSettings: appSettings
        )
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

    static func readImportData(from url: URL) throws -> Data {
        if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > maximumImportSizeBytes {
            throw CocoaError(.fileReadTooLarge)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumImportSizeBytes {
            let remaining = maximumImportSizeBytes + 1 - data.count
            let count = min(importReadChunkSize, remaining)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumImportSizeBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        return data
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

enum ConfigurationImportFailure {
    static func message(for error: Error, languageStyle: AlertLanguageStyle) -> String? {
        let systemError = error as NSError
        let wasCancelled = error is CancellationError
            || (systemError.domain == NSCocoaErrorDomain && systemError.code == NSUserCancelledError)
        guard !wasCancelled else { return nil }
        if languageStyle == .english {
            return "Choose a valid setup backup and try again. The current setup has not been changed."
        }
        return WeatherLanguage.text(
            "Velg en gyldig oppsettkopi og prøv på nytt. Det nåværende oppsettet er ikke endret.",
            style: languageStyle
        )
    }
}

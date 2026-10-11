import MapKit
import SwiftUI

struct PlaceSearchResult: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
}

enum PlaceSearchScope: String, CaseIterable, Identifiable {
    case norway = "Norge"
    case world = "Hele verden"
    var id: String { rawValue }
}

enum PlaceSearchCancellation {
    static func run<Value>(
        operation: @escaping () async throws -> Value,
        cancel: @escaping @Sendable () -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler(operation: operation, onCancel: cancel)
    }
}

enum PlaceSearchCopy {
    static func searchPlaceholder(_ style: AlertLanguageStyle) -> String {
        text("Søk etter by eller sted", english: "Search for a city or place", style: style)
    }

    static func addPlaceTitle(_ style: AlertLanguageStyle) -> String {
        text("Legg til sted", english: "Add place", style: style)
    }

    static func close(_ style: AlertLanguageStyle) -> String {
        text("Lukk", english: "Close", style: style)
    }

    static func searchAreaTitle(_ style: AlertLanguageStyle) -> String {
        text("Søkeområde", english: "Search area", style: style)
    }

    static func searchArea(_ scope: PlaceSearchScope, style: AlertLanguageStyle) -> String {
        return switch scope {
        case .norway: text("Norge", english: "Norway", style: style)
        case .world: text("Hele verden", english: "Worldwide", style: style)
        }
    }

    static func prepositionHeading(_ style: AlertLanguageStyle) -> String {
        text("Skriv stedet med", english: "Write the place with", style: style)
    }

    static func prepositionAccessibilityLabel(_ style: AlertLanguageStyle) -> String {
        text("Preposisjon", english: "Preposition", style: style)
    }

    static func preposition(_ value: PlacePreposition, style: AlertLanguageStyle) -> String {
        guard style == .english else { return WeatherLanguage.text(value.rawValue, style: style) }
        return switch value {
        case .pa, .oppa, .utpa, .bortpa, .nedpa, .innpa: "on"
        case .i, .oppi, .nerri, .uti: "in"
        case .inni: "inside"
        case .borti, .oppmed, .nedmed: "near"
        case .frammi: "at"
        }
    }

    static func noNorwayResults(_ style: AlertLanguageStyle) -> String {
        text("Fant ingen steder i Norge. Prøv «Hele verden» eller et navn i nærheten.",
             english: "No places found in Norway. Try “Worldwide” or a nearby place name.", style: style)
    }

    static func noResults(_ style: AlertLanguageStyle) -> String {
        text("Fant ingen steder som passer.", english: "No matching places found.", style: style)
    }

    static func networkError(_ style: AlertLanguageStyle) -> String {
        text("Søket kunne ikke fullføres. Kontroller nettet og prøv igjen.",
             english: "The search could not be completed. Check your connection and try again.", style: style)
    }

    private static func text(_ bokmal: String, english: String, style: AlertLanguageStyle) -> String {
        style == .english ? english : WeatherLanguage.text(bokmal, style: style)
    }
}

@MainActor
final class PlaceSearchModel: ObservableObject {
    typealias SearchProvider = @MainActor (String, PlaceSearchScope) async throws -> [PlaceSearchResult]

    @Published var query = "" {
        didSet {
            guard oldValue != query else { return }
            invalidateCurrentSearch()
        }
    }
    @Published var results: [PlaceSearchResult] = []
    @Published var isSearching = false
    @Published var message: String?
    @Published var scope: PlaceSearchScope = .norway {
        didSet {
            guard oldValue != scope else { return }
            invalidateCurrentSearch()
        }
    }

    private let searchProvider: SearchProvider
    private var searchGeneration = 0

    init(searchProvider: SearchProvider? = nil) {
        self.searchProvider = searchProvider ?? Self.searchMapKit
    }

    private func invalidateCurrentSearch() {
        searchGeneration &+= 1
        results = []
        isSearching = false
        message = nil
    }

    func search(languageStyle: AlertLanguageStyle = .bokmal) async {
        searchGeneration &+= 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            message = nil
            isSearching = false
            return
        }
        isSearching = true
        message = nil
        defer {
            if generation == searchGeneration { isSearching = false }
        }

        do {
            let found = try await searchProvider(trimmed, scope)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = Array(found.prefix(25))
            if results.isEmpty {
                message = scope == .norway
                    ? PlaceSearchCopy.noNorwayResults(languageStyle)
                    : PlaceSearchCopy.noResults(languageStyle)
            }
        } catch {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = []
            message = PlaceSearchCopy.networkError(languageStyle)
        }
    }

    private static func searchMapKit(
        _ query: String,
        _ scope: PlaceSearchScope
    ) async throws -> [PlaceSearchResult] {
        let searchTerms = scope == .norway ? ["\(query), Norge", query] : [query]
        var items: [MKMapItem] = []
        for term in searchTerms {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = term
            request.resultTypes = [.address, .pointOfInterest]
            if scope == .norway {
                request.region = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 64.5, longitude: 11),
                    span: MKCoordinateSpan(latitudeDelta: 15, longitudeDelta: 22)
                )
            }
            let search = MKLocalSearch(request: request)
            let response = try await PlaceSearchCancellation.run(
                operation: { try await search.start() },
                cancel: { search.cancel() }
            )
            items.append(contentsOf: response.mapItems)
        }

        var seen = Set<String>()
        return items.compactMap { item in
            let placemark = item.placemark
            if scope == .norway, placemark.isoCountryCode != "NO" { return nil }
            let name = item.name ?? placemark.locality ?? query
            let latitude = placemark.coordinate.latitude
            let longitude = placemark.coordinate.longitude
            let key = "\(name.lowercased())|\(String(format: "%.4f", latitude))|\(String(format: "%.4f", longitude))"
            guard seen.insert(key).inserted else { return nil }
            let parts = [placemark.subLocality, placemark.locality, placemark.administrativeArea, placemark.country]
                .compactMap { $0 }
                .filter { $0.caseInsensitiveCompare(name) != .orderedSame }
            return PlaceSearchResult(
                id: key,
                name: name,
                subtitle: parts.joined(separator: ", "),
                latitude: latitude,
                longitude: longitude
            )
        }
    }
}

struct PlaceSearchView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlaceSearchModel()
    @State private var preposition: PlacePreposition
    @State private var searchSubmitRevision = 0
    @State private var handledSearchSubmitRevision = 0
    var onSelect: ((Place) -> Void)?

    init(initialPreposition: PlacePreposition = .i, onSelect: ((Place) -> Void)? = nil) {
        _preposition = State(initialValue: initialPreposition)
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(PlaceSearchCopy.searchPlaceholder(store.alertLanguageStyle), text: $model.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { searchSubmitRevision &+= 1 }
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                            model.results = []
                            model.message = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color.secondary.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 10)

                List {
                    Section {
                        Picker(PlaceSearchCopy.searchAreaTitle(store.alertLanguageStyle), selection: $model.scope) {
                            ForEach(PlaceSearchScope.allCases) { scope in
                                Text(PlaceSearchCopy.searchArea(scope, style: store.alertLanguageStyle)).tag(scope)
                            }
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 9) {
                            Text(PlaceSearchCopy.prepositionHeading(store.alertLanguageStyle))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(PlacePreposition.allCases) { value in
                                        Button {
                                            preposition = value
                                        } label: {
                                            Text(PlaceSearchCopy.preposition(value, style: store.alertLanguageStyle))
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(preposition == value ? Color.white : Color.primary)
                                                .padding(.horizontal, 10)
                                                .frame(height: 28)
                                                .background(
                                                    preposition == value ? Color.blue : Color.secondary.opacity(0.11),
                                                    in: Capsule()
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(PlaceSearchCopy.prepositionAccessibilityLabel(store.alertLanguageStyle))
                        }
                    }

                    if model.isSearching {
                        HStack { Spacer(); ProgressView("Søker …"); Spacer() }
                    }
                    if let message = model.message {
                        Text(message).foregroundStyle(.secondary)
                    }
                    ForEach(model.results) { result in
                        Button {
                            let place = Place(
                                name: result.name,
                                lat: result.latitude,
                                lon: result.longitude,
                                preposition: preposition
                            )
                            if let onSelect {
                                onSelect(place)
                                dismiss()
                            } else {
                                // Let place search dismiss immediately; fetching its
                                // first forecast can take a while or fail offline.
                                dismiss()
                                Task { await store.add(place) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(PlaceSearchCopy.preposition(preposition, style: store.alertLanguageStyle)) \(result.name)").foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(PlaceSearchCopy.addPlaceTitle(store.alertLanguageStyle))
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(model.scope.rawValue)|\(model.query)|\(store.alertLanguageStyle.rawValue)|\(searchSubmitRevision)") {
                let submittedImmediately = handledSearchSubmitRevision != searchSubmitRevision
                handledSearchSubmitRevision = searchSubmitRevision
                if !submittedImmediately {
                    try? await Task.sleep(for: .milliseconds(350))
                }
                guard !Task.isCancelled else { return }
                await model.search(languageStyle: store.alertLanguageStyle)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PlaceSearchCopy.close(store.alertLanguageStyle)) { dismiss() }
                }
            }
        }
    }
}

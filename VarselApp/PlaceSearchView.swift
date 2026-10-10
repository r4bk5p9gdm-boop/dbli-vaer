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

@MainActor
final class PlaceSearchModel: ObservableObject {
    typealias SearchProvider = @MainActor (String, PlaceSearchScope) async throws -> [PlaceSearchResult]

    @Published var query = "" {
        didSet { searchGeneration &+= 1 }
    }
    @Published var results: [PlaceSearchResult] = []
    @Published var isSearching = false
    @Published var message: String?
    @Published var scope: PlaceSearchScope = .norway {
        didSet { searchGeneration &+= 1 }
    }

    private let searchProvider: SearchProvider
    private var searchGeneration = 0

    init(searchProvider: SearchProvider? = nil) {
        self.searchProvider = searchProvider ?? Self.searchMapKit
    }

    func search() async {
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
                    ? "Fant ingen steder i Norge. Prøv «Hele verden» eller et navn i nærheten."
                    : "Fant ingen steder som passer."
            }
        } catch {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = []
            message = "Søket kunne ikke fullføres. Kontroller nettet og prøv igjen."
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
            items.append(contentsOf: try await MKLocalSearch(request: request).start().mapItems)
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
                    TextField("Søk etter by eller sted", text: $model.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await model.search() } }
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
                        Picker("Søkeområde", selection: $model.scope) {
                            ForEach(PlaceSearchScope.allCases) { scope in
                                Text(scope.rawValue).tag(scope)
                            }
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 9) {
                            Text("Skriv stedet med")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(PlacePreposition.allCases) { value in
                                        Button {
                                            preposition = value
                                        } label: {
                                            Text(value.rawValue)
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
                            .accessibilityLabel("Preposisjon")
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
                                Text("\(preposition.rawValue) \(result.name)").foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Legg til sted")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: "\(model.scope.rawValue)|\(model.query)") {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await model.search()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Lukk") { dismiss() }
                }
            }
        }
    }
}

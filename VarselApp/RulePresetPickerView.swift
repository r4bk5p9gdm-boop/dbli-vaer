import CoreLocation
import SwiftUI

struct RulePreset: Identifiable {
    let id: String
    let title: String
    let detail: String
    let suggestion: String
    var rule: Rule

    static let all: [RulePreset] = [
        make("regn-neste", "Regn neste dag", "Fra kl. 07–22 · 0,3 mm/t · varsling kl. 21.00", "Husk regntøy", .regn, 0.3, 7, 22, 720, previousDayHour: 21),
        make("regn-natt", "Regn i natt", "Fra kl. 23–07 · 0,2 mm/t · varsling kl. 21.00", "Ta inn det som ikke tåler regn", .regn, 0.2, 23, 7, 180, previousDayHour: 21),
        make("dugg-morgen", "Dugg i morgen", "Fra kl. 05–10 · innen 1 °C fra duggpunkt · varsling kl. 21.00", "Fare for kondens", .dugg, 1, 5, 10, 720, previousDayHour: 21),
        make("sol-morgen", "Sol i morgen", "Fra kl. 07–21 · maks 20 % skyer i 4 t · varsling kl. 21.00", "Klipp gresset!", .sol, 20, 7, 21, 720, duration: 4, previousDayHour: 21),
        weekendSun,
        make("sno-natt", "Snø i natt", "Fra kl. 23–07 · 0,2 mm vann/t · varsling kl. 21.00", "Beregn ekstra kjøretid", .sno, 0.2, 23, 7, 180, previousDayHour: 21),
        make("sno-morgen", "Snø i morgen", "Fra kl. 06–22 · 0,3 mm vann/t · varsling kl. 21.00", "Finn fram snøskuffa", .sno, 0.3, 6, 22, 720, previousDayHour: 21),
        make("frost-natt", "Frost i natt", "Fra kl. 23–07 · 0 °C · varsling kl. 21.00", "Dekk til plantene", .frost, 0, 23, 7, 360, previousDayHour: 21),
        make("temp-natt", "Under 10 grader", "Fra kl. 23–07 · under 10 °C · varsling kl. 21.00", "Ta inn blomstene", .temperatur, 10, 23, 7, 360, previousDayHour: 21),
        make("vind-natt", "Vind i natt", "Fra kl. 23–07 · \(AlertType.vind.defaultThreshold.formatted()) m/s i kastene · varsling kl. 21.00", "Sikre løse gjenstander", .vind, AlertType.vind.defaultThreshold, 23, 7, 180, previousDayHour: 21),
        make("vind-morgen", "Vind i morgen", "Fra kl. 07–22 · \(AlertType.vind.defaultThreshold.formatted()) m/s i kastene · varsling kl. 21.00", "Ta inn putene", .vind, AlertType.vind.defaultThreshold, 7, 22, 720, previousDayHour: 21),
        make("vind-kraftig", "Kraftige vindkast", "Hele døgnet · fra 20 m/s · varsel 3 timer før", "Sikre utemøbler og trampoline", .vind, 20, 0, 0, 180),
        make("vind-ekstrem", "Ekstreme vindkast", "Hele døgnet · fra 40 m/s · varsel 3 timer før", "Følg farevarslene fra MET", .vind, 40, 0, 0, 180),
        sameDay(make("dag-regn", "Regn i dag", "Fra kl. 07–23 · 0,3 mm/t · varsling kl. 07.00", "Husk regntøy", .regn, 0.3, 7, 23, 180, previousDayHour: 7)),
        sameDay(make("dag-sol", "Sol i dag", "Fra kl. 07–21 · maks 20 % skyer i 4 t · varsling kl. 07.00", "Utnytt dagen!", .sol, 20, 7, 21, 180, duration: 4, previousDayHour: 7)),
        sameDay(make("dag-sno", "Snø i dag", "Fra kl. 07–23 · 0,3 mm vann/t · varsling kl. 07.00", "Beregn ekstra kjøretid", .sno, 0.3, 7, 23, 180, previousDayHour: 7)),
        sameDay(make("dag-vind", "Vind i dag", "Fra kl. 07–23 · \(AlertType.vind.defaultThreshold.formatted()) m/s i kastene · varsling kl. 07.00", "Fest løse gjenstander", .vind, AlertType.vind.defaultThreshold, 7, 23, 180, previousDayHour: 7)),
        make("snart-regn", "Regn senere i dag", "Fra kl. 07–23 · 0,3 mm/t · varsel 3 timer før", "Husk regntøy", .regn, 0.3, 7, 23, 180),
        make("snart-sno", "Snø senere i dag", "Fra kl. 07–23 · 0,3 mm vann/t · varsel 3 timer før", "Beregn ekstra kjøretid", .sno, 0.3, 7, 23, 180),
        make("snart-vind", "Vindkast senere i dag", "Fra kl. 07–23 · \(AlertType.vind.defaultThreshold.formatted()) m/s i kastene · varsel 3 timer før", "Fest løse gjenstander", .vind, AlertType.vind.defaultThreshold, 7, 23, 180),
        weekendRain,
    ]

    private static var weekendSun: RulePreset {
        var preset = make("sol-helg", "Sol i helga", "Lørdag eller søndag kl. 08–20 · maks 25 % skyer i 5 t · varsel torsdag kl. 21.00", "Finn fram tursekken!", .sol, 25, 8, 20, 180, duration: 5, previousDayHour: 21)
        preset.rule.days = [5, 6]
        preset.rule.notificationWeekday = 3
        return preset
    }

    private static var weekendRain: RulePreset {
        var preset = make("regn-helg", "Regn i helga", "Lørdag eller søndag kl. 08–20 · 0,3 mm/t · varsel torsdag kl. 21.00", "Planlegg helga", .regn, 0.3, 8, 20, 180, previousDayHour: 21)
        preset.rule.days = [5, 6]
        preset.rule.notificationWeekday = 3
        return preset
    }

    private static func sameDay(_ preset: RulePreset) -> RulePreset {
        var preset = preset
        preset.rule.notificationDayOffset = 0
        return preset
    }

    private static func make(_ id: String, _ title: String, _ detail: String, _ suggestion: String, _ type: AlertType, _ threshold: Double, _ from: Int, _ to: Int, _ lead: Int, duration: Int = 4, previousDayHour: Int? = nil) -> RulePreset {
        var rule = Rule(type: type)
        rule.templateTitle = title
        rule.memoSuggestion = suggestion
        rule.threshold = threshold
        rule.activeFromHour = from
        rule.activeToHour = to
        rule.leadMinutes = lead
        rule.previousDayNotificationHour = previousDayHour
        rule.durationHours = duration
        rule.days = Set(0..<7)
        rule.quiet = true
        rule.quietFrom = 22
        rule.quietTo = 7
        rule.repeatsEnabled = false
        rule.onlyWhenNearby = false
        return RulePreset(id: id, title: title, detail: detail, suggestion: suggestion, rule: rule)
    }
}

struct RulePresetPickerView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var configuringPreset: RulePreset?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(RulePreset.all) { preset in
                        Button { configuringPreset = preset } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.rule.type.systemImage)
                                    .font(.title2)
                                    .foregroundStyle(preset.rule.type.color)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.title).font(.headline).foregroundStyle(.primary)
                                    Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                                    Text("Forslag til huskelapp: \(preset.suggestion)")
                                        .font(.caption2).foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Velg et utgangspunkt. Alle innstillinger kan endres etterpå.")
                }
            }
            .navigationTitle("Nytt varsel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } } }
            .sheet(item: $configuringPreset) { preset in
                RuleEditorView(rule: preset.rule, isNew: true) {
                    dismiss()
                }
            }
        }
    }
}

enum WizardAlertCategory: String, CaseIterable, Identifiable {
    case rain, wind, winter, sun, moisture

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rain: "Regn"
        case .wind: "Vind"
        case .winter: "Snø og frost"
        case .sun: "Sol"
        case .moisture: "Temperatur og dugg"
        }
    }
    var detail: String {
        switch self {
        case .rain: "Få tid til å ta inn eller kle på deg."
        case .wind: "Sikre løse ting før vinden øker."
        case .winter: "Vær klar for snøfall eller frost."
        case .sun: "Finn et godt tidspunkt for uteplaner."
        case .moisture: "Følg med på kulde og kondens."
        }
    }
    var image: String {
        switch self {
        case .rain: AlertType.regn.systemImage
        case .wind: AlertType.vind.systemImage
        case .winter: AlertType.sno.systemImage
        case .sun: AlertType.sol.systemImage
        case .moisture: AlertType.dugg.systemImage
        }
    }
    var color: Color {
        switch self {
        case .rain: AlertType.regn.color
        case .wind: AlertType.vind.color
        case .winter: AlertType.frost.color
        case .sun: AlertType.sol.color
        case .moisture: AlertType.dugg.color
        }
    }
    var types: Set<AlertType> {
        switch self {
        case .rain: [.regn]
        case .wind: [.vind]
        case .winter: [.sno, .frost]
        case .sun: [.sol]
        case .moisture: [.temperatur, .dugg]
        }
    }

    var presets: [RulePreset] {
        RulePreset.all.filter { types.contains($0.rule.type) }
    }
}

enum WizardPlaceKind: Equatable {
    case home
    case cabin
}

struct WizardPresetSelections {
    private(set) var homeIDs = Set(WizardPresetConfiguration.homePresetIDs)
    private(set) var cabinIDs = Set(WizardPresetConfiguration.cabinPresetIDs)

    func ids(for place: WizardPlaceKind) -> Set<String> {
        place == .cabin ? cabinIDs : homeIDs
    }

    mutating func set(_ id: String, selected: Bool, for place: WizardPlaceKind) {
        switch place {
        case .home:
            if selected { homeIDs.insert(id) }
            else { homeIDs.remove(id) }
        case .cabin:
            if selected { cabinIDs.insert(id) }
            else { cabinIDs.remove(id) }
        }
    }
}

enum WizardPresetConfiguration {
    static let homePresetIDs = ["regn-neste", "sol-morgen", "frost-natt", "vind-morgen"]
    static let cabinPresetIDs = ["regn-natt", "sno-natt", "frost-natt", "vind-kraftig"]

    static func addingMissingRules(_ proposedRules: [Rule], to existingRules: [Rule]) -> [Rule] {
        proposedRules.reduce(into: existingRules) { rules, proposedRule in
            guard !rules.contains(where: { $0.templateTitle == proposedRule.templateTitle }) else { return }
            rules.append(proposedRule)
        }
    }

    static func rules(
        selectedIDs: Set<String>,
        for place: WizardPlaceKind,
        cabinOnlyWhenNearby: Bool
    ) -> [Rule] {
        RulePreset.all.compactMap { preset in
            guard selectedIDs.contains(preset.id) else { return nil }
            var rule = preset.rule
            rule.onlyWhenNearby = place == .cabin && cabinOnlyWhenNearby
            return rule
        }
    }
}

struct OnboardingWizardView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var locationManager = LocationManager()
    @State private var step = 0
    @State private var selectedCategory: WizardAlertCategory?
    @State private var showingHomeSearch = false
    @State private var showingCabinSearch = false
    @State private var isLocating = false
    @State private var locationMessage: String?
    @State private var presetSelections = WizardPresetSelections()
    @State private var homePlaceID: UUID?
    @State private var cabinPlaceID: UUID?
    @State private var cabinOnlyWhenNearby = true

    let onFinish: () -> Void

    private var isCabinStep: Bool { step == 3 }
    private var activePlaceKind: WizardPlaceKind { isCabinStep ? .cabin : .home }
    private var activePresetIDs: Set<String> {
        presetSelections.ids(for: activePlaceKind)
    }
    private var activePlace: Place? {
        let id = isCabinStep ? cabinPlaceID : homePlaceID
        return store.places.first { $0.id == id }
    }
    private var pageTitle: String {
        switch step {
        case 0: "Velg hjemsted"
        case 1: selectedCategory?.title ?? "Velg varsler"
        case 2: "Vil du sette opp hytta?"
        default: selectedCategory?.title ?? "Varsler på hytta"
        }
    }
    private var progressStage: Int { step == 0 ? 0 : step == 1 ? 1 : 2 }
    private let progressTitles = ["Sted", "Varsler", "Hytte"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressHeader
                Group {
                    switch step {
                    case 0: homePlaceStep
                    case 1, 3: alertChoiceStep
                    default: cabinStepView
                    }
                }
            }
            .navigationTitle(pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hopp over") { onFinish() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ContextHelpButton(topic: .wizard)
                }
            }
        }
        .sheet(isPresented: $showingHomeSearch) {
            PlaceSearchView(onSelect: selectSearchedHome)
        }
        .sheet(isPresented: $showingCabinSearch) {
            PlaceSearchView(initialPreposition: .pa, onSelect: selectSearchedCabin)
        }
    }

    private var progressHeader: some View {
        HStack(spacing: 7) {
            ForEach(progressTitles.indices, id: \.self) { index in
                Button {
                    guard index < progressStage else { return }
                    selectedCategory = nil
                    step = index
                } label: {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .fill(index <= progressStage ? Color.blue : Color.secondary.opacity(0.13))
                                .frame(width: 25, height: 25)
                            if index < progressStage {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(index == progressStage ? .white : .secondary)
                            }
                        }
                        Text(progressTitles[index])
                            .font(.caption.weight(index == progressStage ? .semibold : .regular))
                            .foregroundStyle(index == progressStage ? .primary : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 8)
                    .background(
                        index == progressStage ? Color.blue.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(index > progressStage)
                .accessibilityLabel("Steg \(index + 1) av 3: \(progressTitles[index])")
                .accessibilityAddTraits(index == progressStage ? .isSelected : [])
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var homePlaceStep: some View {
        VStack(spacing: 8) {
            VStack(spacing: 8) {
                Image(systemName: "house.and.flag.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.blue)
                Text("Start med stedet du bor")
                    .font(.title3.weight(.semibold))
                Text("Vi foreslår posisjonen din. Du kan også søke etter hjemstedet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)
            .padding(.top, 14)

            List {
                Section("Forslag") {
                    Button(action: useCurrentLocation) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(isLocating ? "Finner posisjonen …" : "Bruk posisjonen min")
                                    .foregroundStyle(.primary)
                                Text("Appen foreslår nærmeste sted der du er")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "location.fill").foregroundStyle(.blue)
                        }
                    }
                    .disabled(isLocating)
                    if let locationMessage {
                        Text(locationMessage).font(.caption).foregroundStyle(.red)
                    }
                }
                if !store.places.isEmpty {
                    Section("Lagrede steder") {
                        ForEach(store.places) { place in
                            Button {
                                homePlaceID = place.id
                                store.select(place)
                            } label: {
                                HStack {
                                    Label(place.nameWithPreposition, systemImage: "mappin.and.ellipse")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if homePlaceID == place.id || (homePlaceID == nil && store.selectedID == place.id) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        showingHomeSearch = true
                    } label: {
                        Label("Søk etter hjemsted", systemImage: "magnifyingglass")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .bottom) {
                footer {
                    Spacer()
                    Button("Neste") {
                        if homePlaceID == nil { homePlaceID = store.selectedID }
                        step = 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(homePlaceID == nil && store.selectedID == nil)
                }
            }
        }
    }

    private var alertChoiceStep: some View {
        Group {
            if let selectedCategory {
                presetDetail(for: selectedCategory)
            } else {
                categoryList
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer {
                Button("Tilbake") {
                    if selectedCategory != nil {
                        selectedCategory = nil
                    } else if step == 1 {
                        step = 0
                    } else {
                        step = 2
                    }
                }
                Spacer()
                Button(step == 3 ? "Lagre varsler" : "Neste") {
                    if step == 3 {
                        installSelectedRules()
                    } else {
                        step = 2
                    }
                }
                .fontWeight(.semibold)
                .buttonStyle(.borderedProminent)
                .accessibilityHint(step == 3 ? "Lagrer varslene for hjemstedet og hytta." : "Går videre til valgfri hytteoppsett.")
            }
        }
    }

    private var categoryList: some View {
        List {
            Section {
                Text("Velg en type for å se ferdige varselforslag. Du kan endre detaljene senere.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activePresetIDs.isEmpty ? "Klar for egne valg" : "\(activePresetIDs.count) forslag valgt")
                            .font(.subheadline.weight(.semibold))
                        Text(activePresetIDs.isEmpty
                             ? "Velg et forslag, eller fortsett uten varsler."
                             : "Du kan bruke dem som de er eller tilpasse dem nå.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: activePresetIDs.isEmpty ? "slider.horizontal.3" : "sparkles")
                        .foregroundStyle(.blue)
                }
                .padding(.vertical, 4)
                ForEach(WizardAlertCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.image)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(category.color)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(category.title).font(.headline).foregroundStyle(.primary)
                                Text(category.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let count = category.presets.filter { activePresetIDs.contains($0.id) }.count
                            if count > 0 {
                                Text("\(count) valgt")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(category.color)
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(category.color.opacity(0.055))
                }
            } header: {
                Text(isCabinStep ? "Varsler for \(activePlace?.nameWithPreposition ?? "hytta")" : "Varsler for \(activePlace?.nameWithPreposition ?? "hjemstedet")")
            } footer: {
                Text("Forslagene er ferdige å bruke. Du kan finjustere tid, grense og varsling senere under Tilpass.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func presetDetail(for category: WizardAlertCategory) -> some View {
        List {
            Section {
                Text("Velg ett eller flere forslag. Hvert forslag har et rolig standardtidspunkt som kan endres senere.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(category.presets) { preset in
                    Toggle(isOn: presetBinding(for: preset.id)) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.title).font(.subheadline.weight(.semibold))
                                Text(preset.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Forslag: \(preset.suggestion)")
                                    .font(.caption2).foregroundStyle(.blue)
                            }
                        } icon: {
                            Image(systemName: preset.rule.type.systemImage)
                                .foregroundStyle(preset.rule.type.color)
                        }
                    }
                    .tint(preset.rule.type.color)
                    .padding(.vertical, 3)
                }
            } header: {
                Text(category.title)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var cabinStepView: some View {
        List {
            Section {
                Label("Hyttevarsler lagres separat fra hjemstedet.", systemImage: "house.lodge.fill")
                    .font(.subheadline)
                Text("Du kan bruke de samme enkle varseltypene på hytta og velge at de bare skal varsle når du er i nærheten.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bare når jeg er i nærheten", isOn: $cabinOnlyWhenNearby)
                Text("Når dette er på, venter hytta med å sende pushvarsel til telefonen er i nærheten.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Valgfritt")
            }
            let otherPlaces = store.places.filter { $0.id != homePlaceID }
            if !otherPlaces.isEmpty {
                Section("Velg et lagret sted") {
                    ForEach(otherPlaces) { place in
                        Button {
                            cabinPlaceID = place.id
                        } label: {
                            HStack {
                                Label(place.nameWithPreposition, systemImage: "mappin.and.ellipse")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if cabinPlaceID == place.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    showingCabinSearch = true
                } label: {
                    Label("Søk etter hytta", systemImage: "magnifyingglass")
                }
            } footer: {
                Text("Hopp over hvis du vil gjøre dette senere. Du kan alltid legge til et sted under Steder.")
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            footer {
                Button("Tilbake") { step = 1 }
                Spacer()
                if cabinPlaceID == nil {
                    Button("Ferdig uten hytte") { installSelectedRules() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Velg hyttevarsler") { step = 3 }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func footer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12, content: content)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.bar)
    }

    private func presetBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { activePresetIDs.contains(id) },
            set: { enabled in
                presetSelections.set(id, selected: enabled, for: activePlaceKind)
            }
        )
    }

    private func useCurrentLocation() {
        isLocating = true
        locationMessage = nil
        Task {
            do {
                let location = try await locationManager.current()
                if let existing = store.places.first(where: { place in
                    CLLocation(latitude: place.lat, longitude: place.lon).distance(from: location) < 500
                }) {
                    store.select(existing)
                    homePlaceID = existing.id
                } else {
                    let name = await LocationManager.name(for: location)
                    let place = Place(
                        name: name,
                        lat: location.coordinate.latitude,
                        lon: location.coordinate.longitude,
                        preposition: .i
                    )
                    homePlaceID = place.id
                    Task { await store.add(place) }
                }
                step = 1
            } catch {
                locationMessage = "Fant ikke posisjonen. Du kan søke etter hjemstedet i stedet."
            }
            isLocating = false
        }
    }

    private func selectSearchedHome(_ place: Place) {
        homePlaceID = place.id
        Task { await store.add(place) }
        step = 1
    }

    private func selectSearchedCabin(_ place: Place) {
        cabinPlaceID = place.id
        Task { await store.add(place) }
        step = 3
    }

    private func installSelectedRules() {
        guard let homePlaceID,
              var home = store.places.first(where: { $0.id == homePlaceID }) else {
            onFinish()
            return
        }
        home.rules = WizardPresetConfiguration.addingMissingRules(
            WizardPresetConfiguration.rules(
                selectedIDs: presetSelections.ids(for: .home),
                for: .home,
                cabinOnlyWhenNearby: false
            ),
            to: home.rules
        )
        store.update(home)

        if let cabinPlaceID,
           var cabin = store.places.first(where: { $0.id == cabinPlaceID }) {
            cabin.rules = WizardPresetConfiguration.addingMissingRules(
                WizardPresetConfiguration.rules(
                    selectedIDs: presetSelections.ids(for: .cabin),
                    for: .cabin,
                    cabinOnlyWhenNearby: cabinOnlyWhenNearby
                ),
                to: cabin.rules
            )
            store.update(cabin)
        }
        store.select(home)
        Task { await store.replan() }
        onFinish()
    }

}

enum ContextHelpTopic {
    case home, places, alerts, settings, wizard

    var title: String {
        switch self {
        case .home: "Slik leser du Hjem"
        case .places: "Steder og hytte"
        case .alerts: "Hva betyr varsellista?"
        case .settings: "Innstillinger"
        case .wizard: "Hjelp til oppstarten"
        }
    }

    func title(languageStyle: AlertLanguageStyle) -> String {
        guard languageStyle == .english else {
            return WeatherLanguage.text(title, style: languageStyle)
        }
        return switch self {
        case .home: "How to read Home"
        case .places: "Places and cabin"
        case .alerts: "What does the alert list mean?"
        case .settings: "Settings"
        case .wizard: "Getting started help"
        }
    }

    func accessibilityLabel(languageStyle: AlertLanguageStyle) -> String {
        let topicTitle: String
        if languageStyle == .english {
            switch self {
            case .home: topicTitle = "How to read Home"
            case .places: topicTitle = "Places and cabin"
            case .alerts: topicTitle = "Understanding the alert list"
            case .settings: topicTitle = "Settings"
            case .wizard: topicTitle = "Getting started help"
            }
            return "Help: \(topicTitle)"
        }
        return WeatherLanguage.text("Hjelp: \(title)", style: languageStyle)
    }
    var introduction: String {
        switch self {
        case .home: "Hjem viser været for det valgte stedet og de neste dagene. Trykk på blyanten for å tilpasse rader, terskler og pushvarsler."
        case .places: "Legg til hjemsted, hytte og andre steder. Et sted med aktive regler får egne varsler og kan velges på Hjem."
        case .alerts: "Her ser du både varsler som allerede er planlagt sendt, og aktive regler som følger med på været framover."
        case .settings: "Her finner du språk, klokkeformat, enheter og valg for Apple Watch og CarPlay. Oppstartsveiviseren kan kjøres på nytt herfra."
        case .wizard: "Velg først hjemsted, og deretter værtypene du vil følge. Forslagene lagres som vanlige varsler du kan endre senere."
        }
    }

    func introduction(languageStyle: AlertLanguageStyle) -> String {
        guard languageStyle == .english else {
            return WeatherLanguage.text(introduction, style: languageStyle)
        }
        return switch self {
        case .home: "Home shows the weather for the selected place and the coming days. Tap the pencil to customize rows, thresholds, and push alerts."
        case .places: "Add your home, cabin, and other places. Places with active rules get their own alerts and can be selected on Home."
        case .alerts: "Here you can see alerts already scheduled to be sent and active rules that keep monitoring the forecast."
        case .settings: "Here you can find language, clock format, units, and Apple Watch and CarPlay options. You can restart the setup guide here."
        case .wizard: "First choose your home place, then the weather types you want to follow. Suggestions are saved as regular alerts that you can edit later."
        }
    }
    var steps: [String] {
        switch self {
        case .home: ["Værbåndene viser når prognosen passerer en markert grense.", "Trykk på blyanten for å endre hva som vises og hvilke pushvarsler som brukes.", "Sveip sidelengs for å bla mellom favorittsteder."]
        case .places: ["Bruk posisjon eller søk for å legge til et sted.", "Velg et sted for å åpne det på Hjem.", "For hytta kan du slå på «Bare når jeg er i nærheten» på varslene."]
        case .alerts: ["Bjelle betyr at et pushvarsel allerede er satt opp.", "Øye betyr at appen følger med på regelen, men ingen sending er planlagt akkurat nå.", "Åpne Tilpass fra Hjem for å endre eller legge til regler."]
        case .settings: ["Språkstil påvirker varseltekster og talemåte.", "Apple Watch kan følge telefonens posisjon eller ett fast sted.", "Du kan når som helst kjøre oppstartsveiviseren på nytt."]
        case .wizard: ["Velg hjemsted med posisjon eller søk.", "Åpne en værtype for å velge ferdige forslag, som regn i natt eller vind i morgen.", "Hytte er valgfritt; hyttevarsler kan bare gjelde når du er i nærheten.", "Alt kan endres senere under Tilpass."]
        }
    }

    func steps(languageStyle: AlertLanguageStyle) -> [String] {
        guard languageStyle == .english else {
            return steps.map { WeatherLanguage.text($0, style: languageStyle) }
        }
        return switch self {
        case .home:
            ["The weather bands show when the forecast crosses a marked threshold.", "Tap the pencil to change what is shown and which push alerts are used.", "Swipe sideways to browse favorite places."]
        case .places:
            ["Use your location or search to add a place.", "Select a place to open it on Home.", "For a cabin, you can enable ‘Only when nearby’ for its alerts."]
        case .alerts:
            ["A bell means a push alert is already scheduled.", "An eye means the app is monitoring the rule, but nothing is scheduled to be sent right now.", "Open Customize from Home to change or add rules."]
        case .settings:
            ["Language style affects alert text and wording.", "Apple Watch can follow your phone’s location or one fixed place.", "You can restart the setup guide at any time."]
        case .wizard:
            ["Choose your home place using your location or search.", "Open a weather type to choose ready-made suggestions, such as rain tonight or wind tomorrow.", "Adding a cabin is optional; cabin alerts can be limited to when you are nearby.", "You can change everything later under Customize."]
        }
    }
}

struct ContextHelpButton: View {
    let topic: ContextHelpTopic
    @EnvironmentObject private var store: Store
    @State private var showingHelp = false

    var body: some View {
        Button { showingHelp = true } label: {
            Image(systemName: "questionmark.circle.fill")
                .font(.body)
                .foregroundStyle(Color(red: 0.91, green: 0.62, blue: 0.08))
                .shadow(color: .yellow.opacity(0.28), radius: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(topic.accessibilityLabel(languageStyle: store.alertLanguageStyle))
        .sheet(isPresented: $showingHelp) {
            HelpGuideView(topic: topic)
        }
    }
}

enum ContextHelpChromeCopy {
    static func quickExplanation(languageStyle: AlertLanguageStyle) -> String {
        localized("Kort forklart", english: "Quick explanation", languageStyle: languageStyle)
    }

    static func navigationTitle(languageStyle: AlertLanguageStyle) -> String {
        localized("Hjelp", english: "Help", languageStyle: languageStyle)
    }

    static func doneButton(languageStyle: AlertLanguageStyle) -> String {
        localized("Ferdig", english: "Done", languageStyle: languageStyle)
    }

    private static func localized(_ bokmal: String, english: String, languageStyle: AlertLanguageStyle) -> String {
        languageStyle == .english ? english : WeatherLanguage.text(bokmal, style: languageStyle)
    }
}

private struct HelpGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store
    let topic: ContextHelpTopic

    private var languageStyle: AlertLanguageStyle { store.alertLanguageStyle }

    var body: some View {
        NavigationStack {
            List {
                Section(topic.title(languageStyle: languageStyle)) {
                    Text(topic.introduction(languageStyle: languageStyle))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section(ContextHelpChromeCopy.quickExplanation(languageStyle: languageStyle)) {
                    ForEach(Array(topic.steps(languageStyle: languageStyle).enumerated()), id: \.offset) { index, text in
                        Label {
                            Text(text).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color.blue, in: Circle())
                        }
                    }
                }
            }
            .navigationTitle(ContextHelpChromeCopy.navigationTitle(languageStyle: languageStyle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ContextHelpChromeCopy.doneButton(languageStyle: languageStyle)) { dismiss() }
                }
            }
        }
    }
}

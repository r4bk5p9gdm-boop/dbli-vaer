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

private enum WizardAlertCategory: String, CaseIterable, Identifiable {
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
    @State private var selectedHomePresetIDs: Set<String> = ["regn-neste", "sol-morgen", "frost-natt", "vind-morgen"]
    @State private var selectedCabinPresetIDs: Set<String> = ["regn-natt", "sno-natt", "frost-natt", "vind-kraftig"]
    @State private var homePlaceID: UUID?
    @State private var cabinPlaceID: UUID?
    @State private var cabinOnlyWhenNearby = true

    let onFinish: () -> Void

    private var isCabinStep: Bool { step == 3 }
    private var activePresetIDs: Set<String> {
        isCabinStep ? selectedCabinPresetIDs : selectedHomePresetIDs
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

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 0: homePlaceStep
                case 1, 3: alertChoiceStep
                default: cabinStepView
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
            PlaceSearchView(initialPreposition: .på, onSelect: selectSearchedCabin)
        }
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
                    Button("Velg varsler") {
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
                .accessibilityHint(step == 3 ? "Lagrer varslene for hjemstedet og hytta." : "Går videre til valgfri hytteoppsett.")
            }
        }
    }

    private var categoryList: some View {
        List {
            Section {
                Text("Velg en type for å se ferdige varselforslag. Du kan endre detaljene senere.")
                    .font(.subheadline).foregroundStyle(.secondary)
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
                            let count = RulePreset.all.filter { category.types.contains($0.rule.type) && activePresetIDs.contains($0.id) }.count
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
                ForEach(RulePreset.all.filter { category.types.contains($0.rule.type) }) { preset in
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
                if isCabinStep {
                    if enabled { selectedCabinPresetIDs.insert(id) }
                    else { selectedCabinPresetIDs.remove(id) }
                } else {
                    if enabled { selectedHomePresetIDs.insert(id) }
                    else { selectedHomePresetIDs.remove(id) }
                }
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
        addRules(selectedHomePresetIDs, to: &home, onlyWhenNearby: false)
        store.update(home)

        if let cabinPlaceID,
           var cabin = store.places.first(where: { $0.id == cabinPlaceID }) {
            addRules(selectedCabinPresetIDs, to: &cabin, onlyWhenNearby: cabinOnlyWhenNearby)
            store.update(cabin)
        }
        store.select(home)
        Task { await store.replan() }
        onFinish()
    }

    private func addRules(_ presetIDs: Set<String>, to place: inout Place, onlyWhenNearby: Bool) {
        for preset in RulePreset.all where presetIDs.contains(preset.id) {
            var rule = preset.rule
            rule.onlyWhenNearby = onlyWhenNearby
            guard !place.rules.contains(where: { $0.templateTitle == rule.templateTitle }) else { continue }
            place.rules.append(rule)
        }
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
    var introduction: String {
        switch self {
        case .home: "Hjem viser været for det valgte stedet og de neste dagene. Trykk på blyanten for å tilpasse rader, terskler og pushvarsler."
        case .places: "Legg til hjemsted, hytte og andre steder. Et sted med aktive regler får egne varsler og kan velges på Hjem."
        case .alerts: "Her ser du både varsler som allerede er planlagt sendt, og aktive regler som følger med på været framover."
        case .settings: "Her finner du språk, klokkeformat, enheter og valg for Apple Watch og CarPlay. Oppstartsveiviseren kan kjøres på nytt herfra."
        case .wizard: "Velg først hjemsted, og deretter værtypene du vil følge. Forslagene lagres som vanlige varsler du kan endre senere."
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
}

struct ContextHelpButton: View {
    let topic: ContextHelpTopic
    @State private var showingHelp = false

    var body: some View {
        Button { showingHelp = true } label: {
            Image(systemName: "questionmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Color(red: 0.91, green: 0.62, blue: 0.08))
                .shadow(color: .yellow.opacity(0.35), radius: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hjelp: \(topic.title)")
        .sheet(isPresented: $showingHelp) {
            HelpGuideView(topic: topic)
        }
    }
}

private struct HelpGuideView: View {
    @Environment(\.dismiss) private var dismiss
    let topic: ContextHelpTopic

    var body: some View {
        NavigationStack {
            List {
                Section(topic.title) {
                    Text(topic.introduction)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Kort forklart") {
                    ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, text in
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
            .navigationTitle("Hjelp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ferdig") { dismiss() }
                }
            }
        }
    }
}

import CoreLocation
import SwiftUI

private struct RulePreset: Identifiable {
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
        make("vind-natt", "Vind i natt", "Fra kl. 23–07 · 12 m/s · varsling kl. 21.00", "Sikre løse gjenstander", .vind, 12, 23, 7, 180, previousDayHour: 21),
        make("vind-morgen", "Vind i morgen", "Fra kl. 07–22 · 12 m/s · varsling kl. 21.00", "Ta inn putene", .vind, 12, 7, 22, 720, previousDayHour: 21),
        make("vind-kraftig", "Kraftige vindkast", "Hele døgnet · fra 20 m/s · varsel 3 timer før", "Sikre utemøbler og trampoline", .vind, 20, 0, 0, 180),
        make("vind-ekstrem", "Ekstreme vindkast", "Hele døgnet · fra 40 m/s · varsel 3 timer før", "Følg farevarslene fra MET", .vind, 40, 0, 0, 180),
        sameDay(make("dag-regn", "Regn i dag", "Fra kl. 07–23 · 0,3 mm/t · varsling kl. 07.00", "Husk regntøy", .regn, 0.3, 7, 23, 180, previousDayHour: 7)),
        sameDay(make("dag-sol", "Sol i dag", "Fra kl. 07–21 · maks 20 % skyer i 4 t · varsling kl. 07.00", "Utnytt dagen!", .sol, 20, 7, 21, 180, duration: 4, previousDayHour: 7)),
        sameDay(make("dag-sno", "Snø i dag", "Fra kl. 07–23 · 0,3 mm vann/t · varsling kl. 07.00", "Beregn ekstra kjøretid", .sno, 0.3, 7, 23, 180, previousDayHour: 7)),
        sameDay(make("dag-vind", "Vind i dag", "Fra kl. 07–23 · 12 m/s · varsling kl. 07.00", "Fest løse gjenstander", .vind, 12, 7, 23, 180, previousDayHour: 7)),
        make("snart-regn", "Regn senere i dag", "Fra kl. 07–23 · 0,3 mm/t · varsel 3 timer før", "Husk regntøy", .regn, 0.3, 7, 23, 180),
        make("snart-sno", "Snø senere i dag", "Fra kl. 07–23 · 0,3 mm vann/t · varsel 3 timer før", "Beregn ekstra kjøretid", .sno, 0.3, 7, 23, 180),
        make("snart-vind", "Vindkast senere i dag", "Fra kl. 07–23 · 12 m/s · varsel 3 timer før", "Fest løse gjenstander", .vind, 12, 7, 23, 180),
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

struct OnboardingWizardView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var locationManager = LocationManager()
    @State private var step = 0
    @State private var showingPlaceSearch = false
    @State private var isLocating = false
    @State private var locationMessage: String?
    @State private var selectedPresetIDs: Set<String> = ["regn-neste", "sol-morgen", "frost-natt", "vind-morgen"]
    @State private var eveningTime = Self.time(hour: 21)
    @State private var morningTime = Self.time(hour: 7)
    @State private var weekendTime = Self.time(hour: 21)
    @State private var daytimeLeadMinutes = 180

    let onFinish: () -> Void

    private let eveningIDs = ["regn-neste", "regn-natt", "dugg-morgen", "sol-morgen", "sno-natt", "sno-morgen", "frost-natt", "temp-natt", "vind-natt", "vind-morgen"]
    private let morningIDs = ["dag-regn", "dag-sol", "dag-sno", "dag-vind"]
    private let weekendIDs = ["sol-helg", "regn-helg"]
    private let daytimeIDs = ["snart-regn", "snart-sno", "snart-vind", "vind-kraftig", "vind-ekstrem"]

    private static func time(hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: 0)) ?? Date()
    }

    private var currentIDs: [String] {
        switch step {
        case 1: eveningIDs
        case 2: morningIDs
        case 3: weekendIDs
        default: daytimeIDs
        }
    }

    private var currentPresets: [RulePreset] {
        currentIDs.compactMap { id in RulePreset.all.first { $0.id == id } }
    }

    private var pageTitle: String {
        switch step {
        case 0: "Hvor er hjemme?"
        case 1: "Kvelden før"
        case 2: "Om morgenen"
        case 3: "Før helga"
        default: "Før det skjer"
        }
    }

    private var pageExplanation: String {
        switch step {
        case 1: "Varsler om natt eller neste dag, samlet på et rolig tidspunkt kvelden før."
        case 2: "En kort oppsummering samme morgen for været resten av dagen."
        case 3: "Se etter helgevær allerede torsdag kveld. Langtidsvarselet er litt grovere."
        default: "Varsler på dagtid noen timer før selve værhendelsen."
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 { placeStep } else { alertGroupStep }
            }
            .navigationTitle(pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hopp over") { onFinish() }
                }
            }
        }
        .sheet(isPresented: $showingPlaceSearch) { PlaceSearchView() }
    }

    private var placeStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 7) {
                Image(systemName: "house.and.flag.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.blue)
                Text("Velg stedet du vil se først")
                    .font(.title3.weight(.semibold))
                Text("Du kan legge til hytte og andre steder etterpå.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 22)

            List {
                Section {
                    Button {
                        useCurrentLocation()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isLocating ? "Finner posisjonen din …" : "Bruk posisjonen min")
                                    .foregroundStyle(.primary)
                                Text("Vær hentes direkte fra MET/Yr")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isLocating { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isLocating)
                    if let locationMessage {
                        Text(locationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    ForEach(store.places) { place in
                        Button {
                            store.select(place)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.displayName).foregroundStyle(.primary)
                                    Text("\(place.resolvedPreposition.rawValue) \(place.displayName)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if place.id == store.selectedID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    Button {
                        showingPlaceSearch = true
                    } label: {
                        Label("Finn et annet sted", systemImage: "magnifyingglass")
                    }
                }
            }
            .listStyle(.insetGrouped)

            Button {
                step = 1
            } label: {
                Text("Neste")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.bottom, 12)
            .disabled(store.selected == nil)
        }
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
                } else {
                    let name = await LocationManager.name(for: location)
                    await store.add(Place(
                        name: name,
                        lat: location.coordinate.latitude,
                        lon: location.coordinate.longitude,
                        preposition: .i
                    ))
                }
            } catch {
                locationMessage = "Fant ikke posisjonen. Kontroller stedstilgang i Innstillinger."
            }
            isLocating = false
        }
    }

    private var alertGroupStep: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("D bli Vær! \(store.selected?.nameWithPreposition ?? "")")
                        Spacer()
                        Text("\(step) av 4")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                        .font(.headline)
                    Text(pageExplanation)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Velg varsler") {
                ForEach(currentPresets) { preset in
                    Toggle(isOn: Binding(
                        get: { selectedPresetIDs.contains(preset.id) },
                        set: { enabled in
                            if enabled { selectedPresetIDs.insert(preset.id) }
                            else { selectedPresetIDs.remove(preset.id) }
                        }
                    )) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                Text(preset.detail.components(separatedBy: " · varsling").first ?? preset.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: preset.rule.type.systemImage)
                                .foregroundStyle(preset.rule.type.color)
                        }
                    }
                }
            }

            Section {
                scheduleControl
            } footer: {
                Text(scheduleHelp)
            }

            Section {
                HStack {
                    Button("Tilbake") { step -= 1 }
                    Spacer()
                    Button(step == 4 ? "Kom i gang" : "Neste") {
                        if step == 4 { installSelectedRules() }
                        else { step += 1 }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var scheduleControl: some View {
        switch step {
        case 1:
            DatePicker("Foreslått tidspunkt", selection: $eveningTime, displayedComponents: .hourAndMinute)
        case 2:
            DatePicker("Foreslått tidspunkt", selection: $morningTime, displayedComponents: .hourAndMinute)
        case 3:
            DatePicker("Torsdag", selection: $weekendTime, displayedComponents: .hourAndMinute)
        default:
            Picker("Varsle før", selection: $daytimeLeadMinutes) {
                Text("1 time").tag(60)
                Text("2 timer").tag(120)
                Text("3 timer").tag(180)
                Text("6 timer").tag(360)
            }
        }
    }

    private var scheduleHelp: String {
        switch step {
        case 1: "Foreslått kl. 21.00. Ett tidspunkt brukes for alle valgene på denne siden."
        case 2: "Foreslått kl. 07.00 samme dag."
        case 3: "Foreslått torsdag kl. 21.00 for kommende lørdag og søndag."
        default: "Foreslått 3 timer før. Disse varslene kan komme gjennom dagen."
        }
    }

    private func installSelectedRules() {
        guard var place = store.selected else {
            onFinish()
            return
        }
        let evening = Calendar.current.dateComponents([.hour, .minute], from: eveningTime)
        let morning = Calendar.current.dateComponents([.hour, .minute], from: morningTime)
        let weekend = Calendar.current.dateComponents([.hour, .minute], from: weekendTime)
        let allWizardIDs = eveningIDs + morningIDs + weekendIDs + daytimeIDs
        for preset in RulePreset.all where allWizardIDs.contains(preset.id) && selectedPresetIDs.contains(preset.id) {
            var rule = preset.rule
            if eveningIDs.contains(preset.id) {
                rule.previousDayNotificationHour = evening.hour ?? 21
                rule.previousDayNotificationMinute = evening.minute ?? 0
                rule.notificationWeekday = nil
                rule.notificationDayOffset = nil
            } else if morningIDs.contains(preset.id) {
                rule.previousDayNotificationHour = morning.hour ?? 7
                rule.previousDayNotificationMinute = morning.minute ?? 0
                rule.notificationWeekday = nil
                rule.notificationDayOffset = 0
            } else if weekendIDs.contains(preset.id) {
                rule.previousDayNotificationHour = weekend.hour ?? 21
                rule.previousDayNotificationMinute = weekend.minute ?? 0
                rule.notificationWeekday = 3
                rule.notificationDayOffset = nil
            } else {
                rule.previousDayNotificationHour = nil
                rule.notificationWeekday = nil
                rule.notificationDayOffset = nil
                rule.leadMinutes = daytimeLeadMinutes
            }
            let alreadyExists = place.rules.contains {
                !$0.templateTitle.isEmpty && $0.templateTitle == rule.templateTitle
            }
            if !alreadyExists { place.rules.append(rule) }
        }
        store.update(place)
        Task { await store.replan() }
        onFinish()
    }
}

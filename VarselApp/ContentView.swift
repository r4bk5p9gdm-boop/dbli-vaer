import SwiftUI

struct LocalCalibrationView: View {
    @EnvironmentObject var store: Store
    let placeID: UUID
    @State private var date = Date()
    @State private var temperature = ""
    @State private var frost = "Vet ikke"
    @State private var surface = "Gress"
    @State private var saved = false

    private var measured: Double? { Double(temperature.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
    private var valid: Bool {
        (temperature.isEmpty || measured.map { $0.isFinite && (-60...60).contains($0) } == true)
            && (measured != nil || frost != "Vet ikke")
    }

    var body: some View {
        Form {
            if let place = store.places.first(where: { $0.id == placeID }) {
                Section("Observasjon \(place.nameWithPreposition)") {
                    DatePicker("Tidspunkt", selection: $date, in: Date().addingTimeInterval(-48 * 3600)...Date())
                    TextField("Målt lufttemperatur (valgfritt)", text: $temperature)
                        .keyboardType(.numbersAndPunctuation)
                    Picker("Frost i natt", selection: $frost) {
                        ForEach(["Vet ikke", "Ja", "Nei"], id: \.self) { Text($0) }
                    }
                    if frost == "Ja" {
                        Picker("Hvor?", selection: $surface) {
                            ForEach(["Gress", "Bil/tak", "Gress og bil/tak", "Annet"], id: \.self) { Text($0) }
                        }
                    }
                    Text("Temperatur gjelder valgt tidspunkt. Frost gjelder natten før dette tidspunktet. Rim på en overflate er ikke en måling av lufttemperatur.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Lagre observasjon") {
                        store.recordObservation(place: place, at: date, temperature: measured,
                            frost: frost == "Vet ikke" ? nil : frost == "Ja", surface: frost == "Ja" ? surface : "")
                        temperature = ""; frost = "Vet ikke"; saved = true
                    }.disabled(!valid)
                }
                Section("Registreringer") {
                    let observations = store.calibration.observations.filter { $0.place.id == placeID }
                    if observations.isEmpty { Text("Ingen registreringer ennå.").foregroundStyle(.secondary) }
                    ForEach(observations) { observation in
                        DisclosureGroup {
                            if let offset = observation.suggestedTemperatureOffset {
                                Text("Målt avvik fra Yr: \(offset.formatted(.number.precision(.fractionLength(1)))) °C")
                                Text("Én måling er ikke nok til å fastslå en fast justering. Endre innstillingen manuelt når du har nok grunnlag.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let frost = observation.frost { Text(frost ? "Frost: \(observation.surface)" : "Ingen frost observert") }
                            if observation.measuredTemperature != nil, observation.frost != nil {
                                if let night = observation.nightForecast, let minimum = night.hours.map(\.temp).min() {
                                    Text("Nattens varslede minimum: \(minimum.formatted()) °C (hentet \(night.fetchedAt.formatted(date: .abbreviated, time: .shortened)))")
                                        .font(.caption)
                                } else { Text("Ingen prognose fra før natten lagret.").font(.caption) }
                            }
                            if observation.evidence.isEmpty { Text("Ingen lagret prognose for sammenligning.").foregroundStyle(.secondary) }
                            if let fetched = observation.forecastFetchedAt {
                                Text("Prognose hentet \(fetched.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                            }
                            ForEach(observation.evidence) { hour in
                                Text("\(hour.time.formatted(date: .omitted, time: .shortened)) · Yr \(hour.temp.formatted(.number.precision(.fractionLength(1))))° · duggpunkt \(hour.dew.formatted(.number.precision(.fractionLength(1))))° · vind \(hour.wind.formatted()) m/s · skyer \(hour.cloud.formatted()) %")
                                    .font(.caption)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(observation.observedAt.formatted(date: .abbreviated, time: .shortened))
                                if let temp = observation.measuredTemperature { Text("Målt \(temp.formatted()) °C").font(.caption) }
                            }
                        }
                        .swipeActions { Button("Slett", role: .destructive) { store.removeObservation(id: observation.id) } }
                    }
                }
                Section {
                    Text("Prognoser beholdes rullerende i 48 timer og ryddes ved neste oppdatering eller oppstart. Registrerte observasjoner beholder sitt sammenligningsgrunnlag. Netatmo og automatisk kurvejustering er ikke aktivert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Lokale målinger")
        .alert("Observasjonen er lagret", isPresented: $saved) { Button("OK", role: .cancel) {} }
    }
}

struct ContentView: View {
    private enum Tab: Hashable { case home, queue, places, settings }

    @EnvironmentObject var store: Store
    @AppStorage("varsel.onboardingCompleted") private var onboardingCompleted = false
    @State private var showingOnboarding = false
    @State private var selectedTab: Tab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView().tabItem { Label("Hjem", systemImage: "cloud.sun") }.tag(Tab.home)
            PlacesView(onOpen: { place in store.select(place); selectedTab = .home }).tabItem { Label("Steder", systemImage: "mappin.and.ellipse") }.tag(Tab.places)
            AlertQueueView().tabItem { Label("Varslingsregler", systemImage: "bell.and.waves.left.and.right") }.tag(Tab.queue)
            GlobalSettingsView(showsDoneButton: false)
                .tabItem { Label("Innstillinger", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Color(red: 0.09, green: 0.14, blue: 0.23))
        .onAppear {
            if !onboardingCompleted { showingOnboarding = true }
            openNotificationPlace(NotificationRoute.consumePendingPlaceID())
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationRoute.requested)) { notification in
            let notifiedPlaceID = notification.userInfo?[NotificationRoute.placeIDKey] as? String
            openNotificationPlace(NotificationRoute.consumePendingPlaceID() ?? notifiedPlaceID)
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingWizardView {
                onboardingCompleted = true
                showingOnboarding = false
            }
        }
    }

    private func openNotificationPlace(_ placeIDString: String?) {
        guard let placeIDString,
              let placeID = UUID(uuidString: placeIDString),
              store.places.contains(where: { $0.id == placeID }) else { return }
        if let place = store.places.first(where: { $0.id == placeID }) {
            store.select(place)
        }
        selectedTab = .home
    }
}

struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Rule?
    @State private var showingSettings = false
    @State private var transitionDirection: Edge = .trailing

    private var swipePlaces: [Place] {
        let favorites = store.resolvedHomeFavorites
        let left = favorites.left.flatMap { id in store.places.first { $0.id == id } }
        let right = favorites.right.flatMap { id in store.places.first { $0.id == id } }
        let orderedIDs = HomeSwipeSelection.orderedIDs(
            leftID: left?.id,
            currentID: store.selected?.id,
            rightID: right?.id
        )
        return orderedIDs.compactMap { id in store.places.first { $0.id == id } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ZStack {
                VStack(alignment: .leading, spacing: 14) {
                    if store.notificationsAuthorized == false {
                        Label("Varslinger er avslått. Slå dem på i Innstillinger for å motta værvarsler.", systemImage: "bell.slash.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .card()
                    }
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .card()
                    }
                    if let p = store.selected {
                        let fc = store.selectedForecast
                        let visibleForecast = Array(fc.prefix(48))
                        if !visibleForecast.isEmpty {
                            CurrentWeatherCard(
                                place: p,
                                places: store.places,
                                forecast: visibleForecast,
                                languageStyle: store.alertLanguageStyle,
                                isCurrentLocation: store.selectionIsCurrentLocation,
                                onSelect: store.select
                            )
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Neste 48 timer").font(.subheadline.bold())
                                Spacer()
                                if store.isRefreshing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Yr.no" + (store.lastUpdate.map { " · \(timeLabel($0))" } ?? ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if fc.isEmpty {
                                Text(store.error ?? "Henter prognose …").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                ForecastVariantsView(
                                    forecast: visibleForecast,
                                    rules: p.rulesForDisplay,
                                    frostMargin: p.localFrostMargin,
                                    mode: .weatherBands,
                                    sunThreshold2: p.resolvedDisplaySunThreshold2,
                                    temperatureLowThreshold: p.resolvedDisplayTemperatureThreshold,
                                    temperatureHighThreshold: p.resolvedDisplayTemperatureHighThreshold
                                )
                            }
                        }.card()

                    } else {
                        ContentUnavailableView(
                            "Ingen steder",
                            systemImage: "mappin.slash",
                            description: Text("Legg til et sted under Steder for å hente værvarsel.")
                        )
                    }
                }.padding()
                    .id(store.selectedID)
                    .transition(.asymmetric(
                        insertion: .move(edge: transitionDirection),
                        removal: .move(edge: transitionDirection == .trailing ? .leading : .trailing)
                    ))
                }
                .animation(.easeInOut(duration: 0.32), value: store.selectedID)
            }
            .background(Color(red: 0.93, green: 0.95, blue: 0.97))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Tilpass", systemImage: "slider.horizontal.3") { showingSettings = true }
                }
            }
            .refreshable { _ = await store.refreshAll() }
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 45).onEnded { value in
                let uniqueIDs = swipePlaces.map(\.id)
                guard let current = store.selected,
                      let next = HomeSwipeSelection.nextIndex(
                        currentID: current.id,
                        placeIDs: uniqueIDs,
                        horizontalTranslation: value.translation.width,
                        verticalTranslation: value.translation.height
                      ),
                      uniqueIDs.indices.contains(next) else { return }
                let nextID = uniqueIDs[next]
                guard let nextPlace = swipePlaces.first(where: { $0.id == nextID }) else { return }
                transitionDirection = value.translation.width < 0 ? .trailing : .leading
                withAnimation(.easeInOut(duration: 0.32)) { store.select(nextPlace) }
            })
            .sheet(item: $editing) { r in RuleEditorView(rule: r, isNew: false) }
            .sheet(isPresented: $showingSettings) { RulesView() }
        }
    }
}

private struct CurrentWeatherCard: View {
    let place: Place
    let places: [Place]
    let forecast: [ForecastHour]
    let languageStyle: AlertLanguageStyle
    let isCurrentLocation: Bool
    let onSelect: (Place) -> Void
    var showsPlaceMenu = true

    private var current: ForecastHour { forecast[0] }
    private var precipitation: CurrentPrecipitationSummary {
        CurrentPrecipitationSummary.make(from: forecast)
    }
    private var rotatingStatuses: [WeatherStatus] {
        Array(
            Planner.statuses(for: place, forecast: forecast)
                .filter { $0.type != .regn && $0.type != .sno }
                .prefix(4)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                WeatherWordmark(languageStyle: languageStyle)

                Text(place.resolvedPreposition.rawValue)
                    .font(.caption.weight(.bold).italic())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        LinearGradient(
                            colors: [.blue.opacity(0.72), .cyan.opacity(0.72)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                    .rotationEffect(.degrees(-4))

                if showsPlaceMenu {
                    Menu {
                        ForEach(places) { candidate in
                            Button {
                                onSelect(candidate)
                            } label: {
                                if candidate.id == place.id {
                                    Label(candidate.displayName, systemImage: "checkmark")
                                } else {
                                    Text(candidate.displayName)
                                }
                            }
                        }
                    } label: {
                        PlaceTitle(place: place, showsChevron: true)
                    }
                    .layoutPriority(1)
                } else {
                    PlaceTitle(place: place, showsChevron: false)
                        .layoutPriority(1)
                }

                if isCurrentLocation {
                    Label("Posisjon", systemImage: "location.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                        .accessibilityLabel("Posisjonsbasert værvarsel")
                        .accessibilityHint("Dette stedet følger telefonens aktuelle posisjon.")
                }

                HStack(spacing: 4) {
                    Text("\(Int(current.temp.rounded()))°")
                        .font(.system(size: 29, weight: .light, design: .rounded))
                    Image(systemName: currentCondition.systemImage)
                        .font(.system(size: 27, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(currentCondition.color)
                        .frame(width: 36, height: 36)
                        .accessibilityLabel(currentCondition.label)
                }
                .fixedSize()
                .layoutPriority(3)
            }

            HStack(spacing: 5) {
                LiveWeatherMetric(
                    icon: current.temp <= 1 ? AlertType.sno.systemImage : AlertType.regn.systemImage,
                    label: current.temp <= 1 ? "Snø" : "Regn",
                    value: precipitationMetricValue,
                    color: current.temp <= 1 ? AlertType.sno.color : AlertType.regn.color,
                    isActive: current.precipitationRiskRate >= 0.1
                )
                LiveWeatherMetric(
                    icon: AlertType.vind.systemImage,
                    label: "Vindkast",
                    value: current.compactWindAndGust,
                    color: AlertType.vind.color,
                    isActive: (current.gust ?? 0) >= WindGustLevel.looseObjects.threshold
                )
                LiveWeatherMetric(
                    icon: moistureMetric.icon,
                    label: moistureMetric.label,
                    value: moistureMetric.value,
                    color: moistureMetric.color,
                    isActive: moistureMetric.isActive
                )
                LiveWeatherMetric(
                    icon: skyMetric.icon,
                    label: skyMetric.label,
                    value: skyMetric.value,
                    color: skyMetric.color,
                    isActive: current.cloud <= 65
                )
            }

            SwiftUI.TimelineView(.periodic(from: .now, by: 6)) { timeline in
                let count = rotatingStatuses.count + 1
                let index = Int(timeline.date.timeIntervalSince1970 / 6) % max(count, 1)
                if index == 0 {
                    headline(
                        title: WeatherLanguage.text(precipitation.title, style: languageStyle),
                        detail: WeatherLanguage.text(precipitation.detail, style: languageStyle),
                        systemImage: precipitation.systemImage,
                        color: precipitation.color
                    )
                } else {
                    let status = rotatingStatuses[index - 1]
                    headline(
                        title: WeatherLanguage.text(status.text, style: languageStyle),
                        detail: Planner.statusDetail(for: status, place: place, forecast: forecast)
                            .map { WeatherLanguage.text($0, style: languageStyle) },
                        systemImage: status.type.systemImage,
                        color: status.type.color
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.white, Color(red: 0.96, green: 0.98, blue: 1.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.12)))
    }

    private var precipitationMetricValue: String {
        let amount = current.precipitationRiskRate
        return amount >= 0.1
            ? "\(amount.formatted(.number.precision(.fractionLength(0...1)))) mm"
            : "opphold"
    }

    private var moistureMetric: (icon: String, label: String, value: String, color: Color, isActive: Bool) {
        if current.temp <= 0 {
            return (AlertType.frost.systemImage, "Frost", "\(current.temp.formatted(.number.precision(.fractionLength(0...1))))°", AlertType.frost.color, true)
        }
        let gap = max(0, current.temp - current.dew)
        return (
            AlertType.dugg.systemImage,
            "Dugg",
            "\(gap.formatted(.number.precision(.fractionLength(0...1))))° fra",
            AlertType.dugg.color,
            gap <= 1 && current.precipitationRiskRate < 0.1
        )
    }

    private var skyMetric: (icon: String, label: String, value: String, color: Color) {
        let condition = CurrentWeatherCondition.resolve(current, precipitationIsFalling: false)
        let value = switch condition {
        case .clear: "klart"
        case .partlyCloudy: "solgløtt"
        default: "overskyet"
        }
        return (condition.systemImage, "Sol", value, condition.color)
    }

    private func headline(title: String, detail: String?, systemImage: String, color: Color) -> some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }

    private var currentCondition: CurrentWeatherCondition {
        CurrentWeatherCondition.resolve(current, precipitationIsFalling: precipitation.isFallingNow)
    }
}

private struct PlaceTitle: View {
    let place: Place
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text(place.displayName)
                .font(.system(size: 29, weight: .light, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .foregroundStyle(.blue)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WeatherWordmark: View {
    var languageStyle: AlertLanguageStyle = .bokmal

    var body: some View {
        Group {
            if languageStyle == .english {
                Text(AppCopy.name(languageStyle: languageStyle))
                    .font(.system(size: 23, weight: .black, design: .rounded))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("D")
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                    Text(" bli ")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("Vær")
                        .font(.system(size: 23, weight: .black, design: .rounded))
                    Text("!")
                        .font(.system(size: 23, weight: .black, design: .rounded))
                        .foregroundStyle(Color(red: 0.96, green: 0.63, blue: 0.08))
                        .offset(y: -1)
                }
            }
        }
        .foregroundStyle(Color(red: 0.06, green: 0.12, blue: 0.22))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppCopy.name(languageStyle: languageStyle))
}
}

private struct LiveWeatherMetric: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    let isActive: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(height: 14)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            isActive ? color.opacity(0.10) : Color.secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}

private struct CurrentPrecipitationSummary {
    let title: String
    let detail: String
    let systemImage: String
    let color: Color
    let isFallingNow: Bool

    static func make(from forecast: [ForecastHour], now: Date = Date()) -> CurrentPrecipitationSummary {
        let current = forecast[0]
        let samples = forecast.flatMap { $0.radarSamples ?? [] }.sorted { $0.time < $1.time }
        let latest = samples.last { $0.time <= now.addingTimeInterval(2 * 60) }

        if let latest, latest.time >= now.addingTimeInterval(-10 * 60), latest.rate >= 0.1 {
            return CurrentPrecipitationSummary(
                title: current.temp <= 1 ? "Snø nå" : "Regn nå",
                detail: "\(amountLabel(latest.rate, temperature: current.temp, perHour: true)) i Nå-varselet",
                systemImage: current.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: true
            )
        }

        if let upcoming = samples.first(where: { $0.time > now.addingTimeInterval(2 * 60) && $0.rate >= 0.1 }) {
            let kind = current.temp <= 1 ? "Snø" : "Regn"
            return CurrentPrecipitationSummary(
                title: "\(kind) \(eventTimePhrase(upcoming.time, relativeTo: now))",
                detail: "Nå-varsel · opptil \(amountLabel(upcoming.rate, temperature: current.temp, perHour: true))",
                systemImage: current.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: false
            )
        }

        if current.precip >= 0.1 {
            return CurrentPrecipitationSummary(
                title: current.temp <= 1 ? "Snø denne timen" : "Regn denne timen",
                detail: "\(amountLabel(current.precip, temperature: current.temp)) neste time\(probabilitySuffix(current.precipProbability))",
                systemImage: current.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: false
            )
        }

        if current.precipitationRiskRate >= 0.1 {
            return CurrentPrecipitationSummary(
                title: current.temp <= 1 ? "Mulig snø denne timen" : "Mulig regn denne timen",
                detail: "opptil \(amountLabel(current.precipMax ?? current.precipitationRiskRate, temperature: current.temp))\(probabilitySuffix(current.precipProbability))",
                systemImage: "umbrella.fill",
                color: .blue.opacity(0.75),
                isFallingNow: false
            )
        }

        if let upcoming = forecast.dropFirst().first(where: { $0.precipitationRiskRate >= 0.1 }) {
            let possible = upcoming.precip < 0.1
            return CurrentPrecipitationSummary(
                title: "\(precipitationHeadlineName(temperature: upcoming.temp, possible: possible)) \(eventTimePhrase(upcoming.time, relativeTo: now))",
                detail: possible
                    ? "opptil \(amountLabel(upcoming.precipMax ?? upcoming.precipitationRiskRate, temperature: upcoming.temp))\(probabilitySuffix(upcoming.precipProbability))"
                    : "\(amountLabel(upcoming.precip, temperature: upcoming.temp)) neste time",
                systemImage: possible ? "umbrella.fill" : (upcoming.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill"),
                color: possible ? .blue.opacity(0.75) : .blue,
                isFallingNow: false
            )
        }

        return CurrentPrecipitationSummary(
            title: "Opphold nå",
            detail: samples.isEmpty ? "0 mm neste time" : "Ingen nedbør i Nå-varselet",
            systemImage: "umbrella",
            color: .secondary,
            isFallingNow: false
        )
    }

    private static func rateLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func amountLabel(_ waterEquivalent: Double, temperature: Double, perHour: Bool = false) -> String {
        let suffix = perHour ? "/t" : ""
        if temperature <= 1 {
            return "anslått \(rateLabel(estimatedFreshSnowMillimeters(waterEquivalent: waterEquivalent, temperature: temperature))) mm snø\(suffix)"
        }
        return "\(rateLabel(waterEquivalent)) mm\(suffix)"
    }

    private static func probabilitySuffix(_ probability: Double?) -> String {
        probability.map { " · \(Int($0.rounded())) % sannsynlig" } ?? ""
    }
}

struct RulesView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Rule?
    @State private var creating = false
    @State private var testAlertMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if var p = store.selected {
                    Section {
                        Menu {
                            ForEach(store.places) { candidate in
                                Button {
                                    store.select(candidate)
                                } label: {
                                    if candidate.id == p.id {
                                        Label(candidate.nameWithPreposition, systemImage: "checkmark")
                                    } else {
                                        Text(candidate.nameWithPreposition)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                WeatherWordmark(languageStyle: store.alertLanguageStyle)
                                Text(p.resolvedPreposition.rawValue)
                                    .font(.caption.weight(.bold).italic())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.72), in: Capsule())
                                Text(p.displayName)
                                    .font(.title2.weight(.light))
                                    .foregroundStyle(.blue)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                        Text("Trykk på stedet for å bytte.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Section("Lokal temperatur") {
                        if let hour = store.selectedForecast.last(where: { $0.time <= Date() && $0.time > Date().addingTimeInterval(-3600) }) {
                            HStack {
                                Text("Yr")
                                Text("\((hour.yrTemperature ?? hour.temp).formatted(.number.precision(.fractionLength(1))))°")
                                    .strikethrough(p.localTemperatureOffset != 0)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                Text("\(hour.temp.formatted(.number.precision(.fractionLength(1))))° \(p.nameWithPreposition) nå").bold()
                            }
                        }
                        Stepper(value: Binding(
                            get: { p.localTemperatureOffset },
                            set: { p.temperatureOffset = $0; store.update(p); Task { await store.replan() } }
                        ), in: -10...10, step: 0.5) {
                            Text("Justering: \(p.localTemperatureOffset.formatted(.number.precision(.fractionLength(1)))) °C")
                        }
                        Text("Gjelder akkurat denne lagrede posisjonen. Minus betyr kaldere enn Yr. Frostmarginen kommer i tillegg. Ingen justering skjer automatisk.")
                            .font(.caption).foregroundStyle(.secondary)
                        NavigationLink("Registrer temperatur eller frost") {
                            LocalCalibrationView(placeID: p.id)
                        }
                    }
                    Section {
                        ForEach([AlertType.regn, .dugg, .sno, .frost, .temperatur, .vind, .sol]) { type in
                            HStack {
                                Image(systemName: type.systemImage).foregroundStyle(type.color)
                                if [.temperatur, .dugg, .sol, .vind].contains(type) {
                                    HStack(spacing: 2) {
                                        Text(type == .temperatur ? "Temp under / over" : type == .dugg ? "Fare for dugg" : type == .vind ? "Vindkast" : "Sol · maks skyer 1")
                                            .font(.subheadline)
                                        Picker("Grense for \(type.label)", selection: Binding(
                                            get: { p.displayThreshold(for: type) },
                                            set: { value in
                                                switch type {
                                                case .temperatur: p.displayTemperatureThreshold = value
                                                case .dugg: p.displayDewThreshold = value
                                                case .sol: p.displaySunThreshold = value
                                                case .vind: p.displayGustThreshold = value
                                                default: break
                                                }
                                                store.update(p)
                                            }
                                        )) {
                                            ForEach(Array(stride(from: type.range.lowerBound, through: type.range.upperBound, by: type.step)), id: \.self) { value in
                                                if type == .vind {
                                                    Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) m/s · \(windStrengthLabel(for: value))").tag(value)
                                                } else {
                                                    Text("\(value.formatted(.number.precision(.fractionLength(0...1))))\(type == .sol ? " %" : "°")").tag(value)
                                                }
                                            }
                                        }
                                        .labelsHidden().pickerStyle(.menu)
                                        if type == .temperatur {
                                            Picker("Temp over", selection: Binding(
                                                get: { p.resolvedDisplayTemperatureHighThreshold },
                                                set: { p.displayTemperatureHighThreshold = $0; store.update(p) }
                                            )) {
                                                ForEach(Array(stride(from: -10.0, through: 40.0, by: 1.0)), id: \.self) { value in
                                                    Text("over \(value.formatted(.number.precision(.fractionLength(0...1))))°").tag(value)
                                                }
                                            }
                                            .labelsHidden().pickerStyle(.menu)
                                        }
                                        if type == .sol {
                                            Picker("Sol maks skyer 2", selection: Binding(
                                                get: { p.resolvedDisplaySunThreshold2 },
                                                set: { p.displaySunThreshold2 = $0; store.update(p) }
                                            )) {
                                                ForEach(Array(stride(from: 0.0, through: 50.0, by: 5.0)), id: \.self) { value in
                                                    Text("2: \(value.formatted(.number.precision(.fractionLength(0)))) %").tag(value)
                                                }
                                            }
                                            .labelsHidden().pickerStyle(.menu)
                                        }
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(type.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                                } else if type == .frost {
                                    Text("Frost")
                                    Picker("Frostmargin", selection: Binding(
                                        get: { p.localFrostMargin },
                                        set: { p.frostMargin = $0; store.update(p); Task { await store.replan() } }
                                    )) {
                                        ForEach(Array(stride(from: 0.0, through: 5.0, by: 0.5)), id: \.self) { value in
                                            Text("+\(value.formatted())°").tag(value)
                                        }
                                    }.labelsHidden().pickerStyle(.menu)
                                } else {
                                    Text(type.label)
                                }
                                Spacer()
                                Toggle("Vis \(type.label)", isOn: Binding(
                                    get: { p.isAlertTypeVisible(type) },
                                    set: { visible in
                                        var hidden = p.hiddenAlertTypes ?? []
                                        if visible { hidden.remove(type) } else { hidden.insert(type) }
                                        p.hiddenAlertTypes = hidden
                                        store.update(p)
                                    }
                                )).labelsHidden()
                            }
                        }
                    } header: { Text("Synlige værrader på Hjem")
                    } footer: {
                        Text("Grensene gjelder visning uten aktive regler. Aktive varsler beholder egne grenser. Dugggrensen er avstand mellom lufttemperatur og duggpunkt; Yr-verdien endres ikke. Solgrensen er maksimalt skydekke for gult felt.")
                    }
                    Section {
                        ForEach(p.rules) { r in
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(r.type.color).frame(width: 4, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.displayName).bold()
                                Text("\(r.summary) · \(r.notificationScheduleLabel), \(r.activeHoursLabel)" + (r.repeatsEnabled ? ", \(r.alertCount)×" : "") + (r.quiet ? ", stille \(r.quietFrom)–\(r.quietTo)" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let aftertext = r.cleanedCustomName {
                                    Text("Huskelapp: \(aftertext)")
                                        .font(.caption2).foregroundStyle(.blue)
                                }
                                Text((r.days.count == 7 ? "Alle dager" : r.days.sorted().map { dayNames[$0] }.joined(separator: " ")) + (r.onlyWhenNearby ? " · bare i nærheten" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = r }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { r.enabled },
                                set: { v in
                                    if let i = p.rules.firstIndex(of: r) { p.rules[i].enabled = v; store.update(p) }
                                    Task { await store.replan() }
                                })).labelsHidden()
                        }
                        .opacity(r.enabled ? 1 : 0.55)
                        }
                        .onDelete { idx in p.rules.remove(atOffsets: idx); store.update(p); Task { await store.replan() } }
                        Button {
                            creating = true
                        } label: {
                            Label("Nytt varsel", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .padding(.vertical, 3)
                        }
                        Button {
                            Task {
                                let sent = await NotificationScheduler.sendTest(for: p, languageStyle: store.alertLanguageStyle)
                                testAlertMessage = sent
                                    ? "Testvarselet kommer om et par sekunder. Det vises også mens appen er åpen."
                                    : "Testvarselet kunne ikke sendes. Kontroller at varslinger er tillatt i Innstillinger."
                            }
                        } label: {
                            Label("Send testvarsel", systemImage: "bell.badge.fill")
                        }
                    } header: {
                        Text("Varselinnstillinger for \(p.displayName)")
                    }
                }
            }
            .navigationTitle("Tilpass")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu("Sorter", systemImage: "arrow.up.arrow.down") {
                        Button("Aktive først") { sortRules { $0.enabled && !$1.enabled } }
                        Button("Etter værtype") { sortRules { $0.type.label < $1.type.label } }
                        Button("Etter navn") { sortRules { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending } }
                    }
                    Button("Ferdig") { dismiss() }
                }
            }
            .sheet(item: $editing) { r in RuleEditorView(rule: r, isNew: false) }
            .sheet(isPresented: $creating) { RulePresetPickerView() }
            .alert("Testvarsel", isPresented: Binding(
                get: { testAlertMessage != nil },
                set: { if !$0 { testAlertMessage = nil } }
            )) {
                Button("OK") { testAlertMessage = nil }
            } message: {
                Text(testAlertMessage ?? "")
            }
        }
    }

    private func sortRules(by areInIncreasingOrder: (Rule, Rule) -> Bool) {
        guard var place = store.selected else { return }
        place.rules.sort { lhs, rhs in
            if areInIncreasingOrder(lhs, rhs) { return true }
            if areInIncreasingOrder(rhs, lhs) { return false }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        store.update(place)
    }
}

struct AlertQueueView: View {
    @EnvironmentObject private var store: Store

    private var alerts: [PlannedAlert] {
        Planner.planAll(places: store.places, forecasts: store.forecasts, nearbyPlaceIDs: store.nearbyPlaceIDs)
    }
    private var watchedRules: [WatchedRule] {
        store.places.filter(\.areNotificationsEnabled).flatMap { place in
            place.rules.filter(\.enabled).map { WatchedRule(place: place, rule: $0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if alerts.isEmpty && watchedRules.isEmpty {
                    ContentUnavailableView(
                        "Ingen aktive varsler",
                        systemImage: "bell.slash",
                        description: Text("Opprett eller slå på et varsel fra Tilpass på Hjem.")
                    )
                }
                if !alerts.isEmpty {
                    Section("Kommende pushvarsler") {
                        ForEach(alerts) { alert in
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: "bell.fill")
                                    .foregroundStyle(.orange)
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(NotificationCopy.title(for: alert.rule, placeName: alert.placeName, possible: alert.possible, languageStyle: store.alertLanguageStyle))
                                        .font(.subheadline.weight(.semibold))
                                    Text(NotificationCopy.message(for: alert.rule, eventAt: alert.eventAt, referenceAt: alert.fireAt, possible: alert.possible, eventDetail: alert.eventDetail, languageStyle: store.alertLanguageStyle))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text("Sendes \(eventTimePhrase(alert.fireAt))")
                                        .font(.caption2).foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
                if !watchedRules.isEmpty {
                    Section {
                        ForEach(watchedRules) { item in
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: alerts.contains(where: { $0.rule.id == item.rule.id }) ? "bell.fill" : "eye.fill")
                                    .foregroundStyle(alerts.contains(where: { $0.rule.id == item.rule.id }) ? .orange : .secondary)
                                    .frame(width: 22)
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(item.rule.displayName) · \(item.place.nameWithPreposition)")
                                        .font(.subheadline.weight(.semibold))
                                    Text(watchedDetail(item))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if item.rule.onlyWhenNearby {
                                        Text("Varsler bare når du er i nærheten")
                                            .font(.caption2).foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Aktive regler som følger med")
                    } footer: {
                        Text("Øye betyr at regelen følger prognosen. Bjelle betyr at minst ett pushvarsel allerede er planlagt.")
                    }
                }
                if let latestUpdate = store.log.first {
                    Section("Siste oppdatering") {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(latestUpdate.text)
                                .font(.footnote)
                            Text(latestUpdate.time.formatted(.dateTime.day().month().hour().minute()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        NavigationLink("Vis oppdateringslogg") {
                            UpdateLogView()
                        }
                    }
                }
            }
            .navigationTitle("Varslingsregler")
            .refreshable { _ = await store.refreshAll() }
        }
    }

    private func watchedDetail(_ item: WatchedRule) -> String {
        let forecast = store.forecasts[item.place.id] ?? []
        guard !forecast.isEmpty else { return "Venter på prognose" }
        let result = Planner.plan(
            rule: item.rule,
            forecast: forecast,
            placeName: item.place.nameWithPreposition,
            frostMargin: item.place.localFrostMargin
        )
        if let eventAt = result.eventAt {
            if result.alerts.isEmpty { return "Treff \(eventTimePhrase(eventAt)), men forvarseltidspunktet er passert" }
            return "Treff \(eventTimePhrase(eventAt))"
        }
        return "Ingen treff i prognosen de neste 48 timene"
    }
}

private struct WatchedRule: Identifiable {
    let place: Place
    let rule: Rule
    var id: String { "\(place.id)-\(rule.id)" }
}

struct PlacesView: View {
    var onOpen: (Place) -> Void = { Store.shared.select($0) }
    @EnvironmentObject var store: Store
    @StateObject private var loc = LocationManager()
    @State private var busy = false
    @State private var showingSearch = false
    @State private var locationError: String?
    @State private var showingExporter = false
    @State private var editingPlaces = false

    private var alertPlaces: [Place] {
        store.places.filter { $0.areNotificationsEnabled && $0.rules.contains(where: \.enabled) }
    }

    private var savedPlaces: [Place] {
        store.places.filter { !$0.areNotificationsEnabled || !$0.rules.contains(where: \.enabled) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if editingPlaces {
                    List {
                if store.places.isEmpty {
                    ContentUnavailableView(
                        "Ingen steder",
                        systemImage: "mappin.and.ellipse",
                        description: Text("Søk etter et sted eller bruk posisjonen din.")
                    )
                }
                if !alertPlaces.isEmpty {
                    Section("Steder med aktive varsler") {
                        ForEach(alertPlaces) { place in
                            PlaceRow(place: place)
                        }
                        .onDelete { offsets in remove(offsets, from: alertPlaces) }
                        .onMove { source, destination in move(source, to: destination, within: alertPlaces) }
                    }
                }

                if !savedPlaces.isEmpty {
                    Section("Lagret for å sjekke") {
                        ForEach(savedPlaces) { place in
                            PlaceRow(place: place)
                        }
                        .onDelete { offsets in remove(offsets, from: savedPlaces) }
                        .onMove { source, destination in move(source, to: destination, within: savedPlaces) }
                    }
                }

                    Section {
                    Button("Søk etter sted", systemImage: "magnifyingglass") {
                        showingSearch = true
                    }
                    Button(busy ? "Finner posisjon …" : "Legg til min posisjon") {
                        busy = true
                        locationError = nil
                        Task {
                            do {
                                let l = try await loc.current()
                                let name = await LocationManager.name(for: l)
                                await store.add(Place(name: name, lat: l.coordinate.latitude, lon: l.coordinate.longitude, preposition: .i))
                            } catch {
                                locationError = "Fant ikke posisjonen. Tillat stedstilgang for D bli Vær! i Innstillinger → Personvern og sikkerhet → Stedstjenester."
                            }
                            busy = false
                        }
                    }.disabled(busy)
                    if let locationError {
                        Text(locationError).font(.footnote).foregroundStyle(.red)
                    }
                    } footer: {
                        Text("Nye steder lagres uten varsler. Velg et sted og opprett varslene du vil ha under Varsler.")
                    }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(store.places) { place in
                                if let forecast = store.forecasts[place.id], !forecast.isEmpty {
                                    CurrentWeatherCard(
                                        place: place,
                                        places: store.places,
                                        forecast: forecast,
                                        languageStyle: store.alertLanguageStyle,
                                        isCurrentLocation: false,
                                        onSelect: store.select,
                                        showsPlaceMenu: false
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 18))
                                    .onTapGesture { onOpen(place) }
                                } else {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack { WeatherWordmark(languageStyle: store.alertLanguageStyle); Text(place.nameWithPreposition).font(.headline).foregroundStyle(.blue) }
                                        Text(store.forecastErrors[place.id] ?? "Henter prognose …")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    .card()
                                    .contentShape(Rectangle())
                                    .onTapGesture { onOpen(place) }
                                }
                            }
                        }
                        .padding()
                    }
                    .background(Color(red: 0.93, green: 0.95, blue: 0.97))
                    .refreshable { _ = await store.refreshAll() }
                }
            }
            .navigationTitle("Steder")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(editingPlaces ? "Ferdig" : "Rediger") { editingPlaces.toggle() }
                    Button("Eksporter oppsett", systemImage: "square.and.arrow.up") {
                        showingExporter = true
                    }
                }
            }
            .sheet(isPresented: $showingSearch) { PlaceSearchView() }
            .fileExporter(
                isPresented: $showingExporter,
                document: WeatherConfigurationDocument(places: store.places, selectedPlaceID: store.selectedID, alertLanguageStyle: store.alertLanguageStyle),
                contentType: .json,
                defaultFilename: "D-bli-Vaer-oppsett"
            ) { _ in }
        }
    }

    private func remove(_ offsets: IndexSet, from places: [Place]) {
        store.removePlaces(ids: Set(offsets.compactMap { index in
            places.indices.contains(index) ? places[index].id : nil
        }))
    }

    private func move(_ source: IndexSet, to destination: Int, within visiblePlaces: [Place]) {
        var reordered = visiblePlaces
        reordered.move(fromOffsets: source, toOffset: destination)
        let visibleIDs = Set(visiblePlaces.map(\.id))
        var next = reordered.makeIterator()
        var allPlaces = store.places
        for index in allPlaces.indices where visibleIDs.contains(allPlaces[index].id) {
            if let replacement = next.next() { allPlaces[index] = replacement }
        }
        store.places = allPlaces
    }
}

private struct GlobalSettingsView: View {
    @AppStorage(WeatherTextSeparator.key, store: WeatherTextSeparator.defaults) private var textSeparator = WeatherTextSeparator.space.rawValue
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showingOnboarding = false
    @AppStorage(LiveWeatherActivitySettings.enabledKey) private var liveActivitiesEnabled = true
    var showsDoneButton = true

    private func favoriteBinding(left: Bool) -> Binding<UUID?> {
        Binding {
            left ? store.resolvedHomeFavorites.left : store.resolvedHomeFavorites.right
        } set: { id in
            var favorites = store.resolvedHomeFavorites
            if left {
                favorites.left = id
                if id != nil && favorites.right == id { favorites.right = nil }
            } else {
                favorites.right = id
                if id != nil && favorites.left == id { favorites.left = nil }
            }
            store.homeFavorites = favorites
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Favoritt 1 · høyre", selection: favoriteBinding(left: false)) {
                        Text("Ikke valgt").tag(nil as UUID?)
                        ForEach(store.places) { place in
                            Text(place.nameWithPreposition).tag(Optional(place.id))
                        }
                    }
                    Picker("Favoritt 2 · venstre", selection: favoriteBinding(left: true)) {
                        Text("Ikke valgt").tag(nil as UUID?)
                        ForEach(store.places) { place in
                            Text(place.nameWithPreposition).tag(Optional(place.id))
                        }
                    }
                } header: {
                    Text("Favorittsteder")
                } footer: {
                    Text("Sveip Hjem mot venstre eller høyre for å bytte mellom valgt sted og favoritter. Valgene endrer ikke varslene dine.")
                }
                Section("Språk og varseltekst") {
                    Picker("Skilletegn før klokkeslett", selection: $textSeparator) {
                        ForEach(WeatherTextSeparator.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Text((WeatherTextSeparator(rawValue: textSeparator) ?? .space).format("Duggfall natt te onsda'n kl. 05"))
                        .font(.caption).foregroundStyle(.secondary)
                        .onChange(of: textSeparator) { _, _ in store.refreshDisplaySettings() }
                    Picker("Språkstil", selection: $store.alertLanguageStyle) {
                        ForEach(AlertLanguageStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Preposisjonen du har valgt for stedet – som i, på, nerri eller oppi – endres ikke av språkvalget.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        showingOnboarding = true
                    } label: {
                        Label("Kjør oppstartsveiviseren", systemImage: "wand.and.stars")
                    }
                } footer: {
                    Text("Velg hjemsted og legg til anbefalte standardvarsler på nytt.")
                }

                Section("CarPlay") {
                    Text("Steder i CarPlay og Watch")
                        .font(.subheadline.weight(.semibold))
                    ForEach(0..<3, id: \.self) { index in
                        Picker(index == 0 ? "Primært sted" : "Sted \(index + 1)", selection: Binding<UUID?>(
                            get: { store.resolvedSharedPlaceIDs.indices.contains(index) ? store.resolvedSharedPlaceIDs[index] : nil },
                            set: { id in
                                var ids = store.resolvedSharedPlaceIDs
                                if ids.count <= index { ids.append(contentsOf: Array(repeating: store.places.first?.id ?? UUID(), count: index + 1 - ids.count)) }
                                if let id { ids[index] = id } else if ids.indices.contains(index) { ids.remove(at: index) }
                                store.sharedPlaceSelection = SharedPlaceSelection(ids: ids)
                            })) {
                            Text("Ikke valgt").tag(nil as UUID?)
                            ForEach(store.places) { place in Text(place.nameWithPreposition).tag(Optional(place.id)) }
                        }
                    }
                    Text("CarPlay kan vise opptil tre valgte steder. Watch bruker fortsatt primærstedet som standard.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("CarPlay-widgeten er klar", systemImage: "car.fill")
                    Text("Krever iOS 26 eller nyere. Legg til D bli Vær! fra widgetinnstillingene for bilen under Innstillinger › Generelt › CarPlay.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Live Activity") {
                    Toggle("Vis nedtelling til regn og snø", isOn: $liveActivitiesEnabled)
                    Text("Starter når appen finner regn eller snø 10–60 minutter fram. Fortsetter på låseskjermen, Dynamic Island og i CarPlay etter at appen lukkes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .onChange(of: liveActivitiesEnabled) { _, _ in
                    Task { await store.replan() }
                }

                Section("Apple Watch") {
                    Label("Watch-app og komplikasjoner er med", systemImage: "applewatch")
                    Text("Klokka følger valgt sted fra iPhone. Du kan åpne Watch-appen, legge D bli Vær! i Smart stabel og velge komplikasjonen på urskiven.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Innstillinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Ferdig") { dismiss() }
                    }
                }
            }
            .fullScreenCover(isPresented: $showingOnboarding) {
                OnboardingWizardView { showingOnboarding = false }
            }
        }
    }
}

private struct PlaceRow: View {
    @EnvironmentObject private var store: Store
    let place: Place
    @State private var showingNameEditor = false
    @State private var nameDraft = ""

    private var enabledRules: [Rule] { place.rules.filter(\.enabled) }
    private var nearbyRuleCount: Int { enabledRules.filter(\.onlyWhenNearby).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(PlacePreposition.allCases) { preposition in
                            Button(preposition.rawValue) { updatePreposition(preposition) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(place.resolvedPreposition.rawValue)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                        .font(.subheadline.italic())
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.blue.opacity(0.1), in: Capsule())
                    }
                    Button { store.select(place) } label: {
                        Text(place.displayName)
                            .font(.title3.weight(.light))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if let current = store.forecasts[place.id]?.first {
                    Image(systemName: current.cloud <= 20 ? "sun.max.fill" : (current.precipitationRiskRate >= 0.1 ? "cloud.rain.fill" : "cloud.fill"))
                        .foregroundStyle(current.cloud <= 20 ? .orange : .blue)
                    Text("\(Int(current.temp.rounded()))°").font(.title3.weight(.medium))
                }
                if place.id == store.selectedID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
            }
            HStack {
                if enabledRules.isEmpty {
                    Text("Ingen aktive varsler")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(enabledRules.count) aktive \(enabledRules.count == 1 ? "varsel" : "varsler")" + nearbyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.forecastErrors[place.id] != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            HStack(spacing: 8) {
                Button(place.areNotificationsEnabled ? "Push på" : "Push av", systemImage: place.areNotificationsEnabled ? "bell.fill" : "bell.slash") {
                    update { $0.notificationsEnabled = !place.areNotificationsEnabled }
                }
                Menu {
                    Button("Vis alle værtyper") { update { $0.rulesOnlyDisplay = false } }
                    Button("Vis bare regelstyrte varsel") { update { $0.rulesOnlyDisplay = true } }
                } label: {
                    Label(place.showsOnlyRuleAlerts ? "Bare regler" : "Alle værtyper", systemImage: "eye")
                }
                Button("Gi eget navn", systemImage: "pencil") {
                    nameDraft = place.customName ?? ""
                    showingNameEditor = true
                }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 5)
        .sheet(isPresented: $showingNameEditor) {
            NavigationStack {
                Form {
                    Section("Eget navn") {
                        TextField("For eksempel Hytta", text: $nameDraft)
                        Text("Det opprinnelige stedsnavnet er \(place.name). La feltet stå tomt for å bruke det igjen.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Navn på stedet")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { showingNameEditor = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Lagre") {
                            update { $0.customName = nameDraft }
                            showingNameEditor = false
                        }
                    }
                }
            }
        }
    }

    private var nearbyText: String {
        guard nearbyRuleCount > 0 else { return "" }
        return " · \(nearbyRuleCount) bare i nærheten"
    }

    private func updatePreposition(_ preposition: PlacePreposition) { update { $0.preposition = preposition } }

    private func update(_ change: (inout Place) -> Void) {
        var updated = place
        change(&updated)
        store.update(updated)
        Task { await store.replan() }
    }
}

struct UpdateLogView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            if store.log.isEmpty {
                ContentUnavailableView(
                    "Ingen oppdateringer ennå",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Oppdateringshistorikken vises når prognosen er hentet.")
                )
            } else {
                ForEach(store.log) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.text).font(.footnote)
                        Text(entry.time.formatted(.dateTime.day().month().hour().minute()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Oppdateringslogg")
    }
}

extension View {
    func card(accent: Color? = nil) -> some View {
        HStack(spacing: 0) {
            if let a = accent { Rectangle().fill(a).frame(width: 4) }
            self.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(white: 0.87)))
    }
}

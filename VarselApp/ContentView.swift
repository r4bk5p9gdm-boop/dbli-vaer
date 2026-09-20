import SwiftUI
import CoreLocation

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
            AlertQueueView().tabItem { Label("Varsler", systemImage: "bell.and.waves.left.and.right") }.tag(Tab.queue)
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

    private var forecastHeaderTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nb_NO")
        formatter.dateFormat = "EEEE d. MMM"
        let title = formatter.string(from: Date())
        return "Resten av i dag, \(title)"
    }

    private var swipePlaces: [Place] {
        // Hjem har sin egen tre-steders hurtignavigering. Den styrer ikke
        // Watch eller CarPlay, som begge følger den felles datakilden der.
        return store.homeSwipePlaceIDs.compactMap { id in
            store.places.first { $0.id == id }
        }
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
                        // The Home view is a three-day visual forecast. Its
                        // range is intentionally independent of the shorter
                        // 24-hour horizon used by the rotating alert text.
                        let visibleForecast = Array(fc.prefix(72))
                        if !visibleForecast.isEmpty {
                            VStack(spacing: 0) {
                                CurrentWeatherCard(
                                    place: p,
                                    places: store.places,
                                    forecast: visibleForecast,
                                    languageStyle: store.alertLanguageStyle,
                                    isCurrentLocation: store.selectionIsCurrentLocation,
                                    onSelect: { place in store.select(place) },
                                    onEdit: { showingSettings = true },
                                    showsContainer: false
                                )
                                .background(
                                    LinearGradient(
                                        colors: store.selectionIsCurrentLocation
                                            ? [Color.indigo.opacity(0.12), Color.cyan.opacity(0.08)]
                                            : [Color.white, Color(red: 0.96, green: 0.98, blue: 1.0)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 18)
                                )
                                .padding(.horizontal, 4)
                                .padding(.top, 4)

                                ForecastVariantsView(
                                    forecast: visibleForecast,
                                    rules: p.rulesForDisplay,
                                    frostMargin: p.localFrostMargin,
                                    mode: .weatherBands,
                                    sunThreshold2: p.resolvedDisplaySunThreshold2,
                                    temperatureLowThreshold: p.resolvedDisplayTemperatureThreshold,
                                    temperatureHighThreshold: p.resolvedDisplayTemperatureHighThreshold,
                                    latitude: p.lat,
                                    longitude: p.lon,
                                    todayTitle: forecastHeaderTitle,
                                    updatedAt: store.lastUpdate,
                                    isRefreshing: store.isRefreshing,
                                    isStale: Store.isForecastStale(store.lastUpdate)
                                )
                                .padding(.horizontal, 12)
                                .padding(.top, 16)
                                .padding(.bottom, 4)
                            }
                            .background(
                                Color(uiColor: .systemBackground),
                                in: RoundedRectangle(cornerRadius: 18)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(store.selectionIsCurrentLocation ? Color.indigo.opacity(0.28) : Color.blue.opacity(0.12)))

                            let pageCount = max(1, swipePlaces.count)
                            HStack(spacing: 6) {
                                let activeIndex = min(pageCount - 1, max(0, swipePlaces.firstIndex(where: { $0.id == p.id }) ?? 0))
                                ForEach(0..<pageCount, id: \.self) { index in
                                    Circle()
                                        .fill(index == activeIndex ? Color.indigo : Color.secondary.opacity(0.25))
                                        .frame(width: index == activeIndex ? 7 : 5, height: index == activeIndex ? 7 : 5)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, -3)
                            .padding(.bottom, -2)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Stedside \(activeIndexForSelectedPlace + 1) av \(pageCount)")
                        } else {
                            Text(store.error ?? "Henter prognose …")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .card()
                        }

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
                withAnimation(.easeInOut(duration: 0.32)) {
                    store.select(nextPlace, fromCurrentLocation: nextID == store.currentLocationPlaceID)
                }
            })
            .sheet(item: $editing) { r in RuleEditorView(rule: r, isNew: false) }
            .sheet(isPresented: $showingSettings) { RulesView() }
        }
    }

    private var activeIndexForSelectedPlace: Int {
        let pageCount = max(1, swipePlaces.count)
        return min(pageCount - 1, max(0, swipePlaces.firstIndex(where: { $0.id == store.selected?.id }) ?? 0))
    }
}

private struct CurrentWeatherCard: View {
    let place: Place
    let places: [Place]
    let forecast: [ForecastHour]
    let languageStyle: AlertLanguageStyle
    let isCurrentLocation: Bool
    let onSelect: (Place) -> Void
    var onEdit: (() -> Void)? = nil
    var showsPlaceMenu = true
    var showsContainer = true

    private var current: ForecastHour { forecast[0] }
    private var precipitation: CurrentPrecipitationSummary {
        CurrentPrecipitationSummary.make(from: forecast)
    }
    private var rotatingStatuses: [WeatherStatus] {
        let horizon = Date().addingTimeInterval(24 * 60 * 60)
        return WeatherStatus.uniqueByType(
            Planner.statuses(for: place, forecast: forecast)
                .filter { $0.type != .regn && $0.type != .sno && $0.eventAt <= horizon }
        )
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                WeatherWordmark(languageStyle: languageStyle)

                if isCurrentLocation {
                    ZStack {
                        // Keep the arrow visible behind «her»: the word is
                        // deliberately drawn directly on the marker instead
                        // of inside an opaque capsule.
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(.indigo.gradient)
                        Text(languageStyle == .english ? "here" : "her")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(.white)
                            .shadow(color: .indigo.opacity(0.45), radius: 0.8)
                            .offset(x: 3, y: 2)
                    }
                    .frame(width: languageStyle == .english ? 42 : 36, height: 30)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Posisjonsbasert værvarsel her")
                    .accessibilityHint("Dette stedet følger telefonens aktuelle posisjon.")
                }

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
                        PlaceTitle(place: place, showsChevron: true, isCurrentLocation: isCurrentLocation)
                    }
                    .layoutPriority(1)
                } else {
                    PlaceTitle(place: place, showsChevron: false, isCurrentLocation: isCurrentLocation)
                        .layoutPriority(1)
                }

                HStack(spacing: 4) {
                    ZStack {
                        if frostIsActiveNow {
                            Image(systemName: AlertType.frost.systemImage)
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.34))
                        }
                        Text("\(Int(current.temp.rounded()))°")
                            .font(.system(size: 29, weight: .light, design: .rounded))
                            .foregroundStyle(currentTemperatureColor)
                    }
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
                    label: "Nedbør",
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
                        detail: precipitation.detail.map { WeatherLanguage.text($0, style: languageStyle) },
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
        .background {
            if showsContainer {
                LinearGradient(
                    colors: isCurrentLocation
                        ? [Color.indigo.opacity(0.12), Color.cyan.opacity(0.08)]
                        : [Color.white, Color(red: 0.96, green: 0.98, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
        .overlay {
            if showsContainer {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isCurrentLocation ? Color.indigo.opacity(0.28) : Color.blue.opacity(0.12))
            }
        }
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
        HStack(spacing: 6) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))

            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Rediger varsler for \(place.displayName)")
            }
        }
    }

    private var currentCondition: CurrentWeatherCondition {
        CurrentWeatherCondition.resolve(current, precipitationIsFalling: precipitation.isFallingNow)
    }

    private var frostIsActiveNow: Bool {
        current.temp <= 1 + place.localFrostMargin
    }

    /// Keep the current temperature aligned with the blue/cold and warm/high
    /// segments in the temperature band below.
    private var currentTemperatureColor: Color {
        if current.temp <= place.resolvedDisplayTemperatureThreshold {
            return Color(red: 0.10, green: 0.43, blue: 0.72)
        }
        if current.temp >= place.resolvedDisplayTemperatureHighThreshold {
            return Color(red: 0.82, green: 0.23, blue: 0.16)
        }
        return .primary
    }
}

private struct PlaceTitle: View {
    let place: Place
    let showsChevron: Bool
    let isCurrentLocation: Bool

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
        .foregroundStyle(isCurrentLocation ? .indigo : .blue)
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
    let detail: String?
    let systemImage: String
    let color: Color
    let isFallingNow: Bool

    static func make(from forecast: [ForecastHour], now: Date = Date()) -> CurrentPrecipitationSummary {
        let current = forecast[0]
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        let samples = forecast.flatMap { $0.radarSamples ?? [] }.sorted { $0.time < $1.time }
        let latest = samples.last { $0.time <= now.addingTimeInterval(2 * 60) }

        if let latest, latest.time >= now.addingTimeInterval(-10 * 60), latest.rate >= 0.1 {
            return CurrentPrecipitationSummary(
                title: current.temp <= 1 ? "Snø nå" : "Regn nå",
                detail: precipitationDetail(waterEquivalent: latest.rate, temperature: current.temp),
                systemImage: current.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: true
            )
        }

        if let upcoming = samples.first(where: {
            $0.time > now.addingTimeInterval(2 * 60)
                && $0.time <= horizon
                && $0.rate >= 0.1
        }) {
            let kind = current.temp <= 1 ? "Snø" : "Regn"
            return CurrentPrecipitationSummary(
                title: "\(kind) \(eventTimePhrase(upcoming.time, relativeTo: now))",
                detail: precipitationDetail(waterEquivalent: upcoming.rate, temperature: current.temp),
                systemImage: current.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: false
            )
        }

        if current.precip >= 0.1 {
            return CurrentPrecipitationSummary(
                title: current.temp <= 1 ? "Snø denne timen" : "Regn denne timen",
                detail: precipitationDetail(waterEquivalent: current.precip, temperature: current.temp),
                systemImage: current.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: false
            )
        }

        if current.precipitationRiskRate >= 0.1 {
            return CurrentPrecipitationSummary(
                title: current.temp <= 1 ? "Mulig snø denne timen" : "Mulig regn denne timen",
                detail: precipitationDetail(
                    waterEquivalent: current.precipMax ?? current.precipitationRiskRate,
                    temperature: current.temp,
                    possible: true
                ),
                systemImage: "umbrella.fill",
                color: .blue.opacity(0.75),
                isFallingNow: false
            )
        }

        if let upcoming = forecast.dropFirst().first(where: {
            $0.time <= horizon && $0.precipitationRiskRate >= 0.1
        }) {
            let possible = upcoming.precip < 0.1
            return CurrentPrecipitationSummary(
                title: "\(precipitationHeadlineName(temperature: upcoming.temp, possible: possible)) \(eventTimePhrase(upcoming.time, relativeTo: now))",
                detail: precipitationDetail(
                    waterEquivalent: possible ? (upcoming.precipMax ?? upcoming.precipitationRiskRate) : upcoming.precip,
                    temperature: upcoming.temp,
                    possible: possible
                ),
                systemImage: possible ? "umbrella.fill" : (upcoming.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill"),
                color: possible ? .blue.opacity(0.75) : .blue,
                isFallingNow: false
            )
        }

        return CurrentPrecipitationSummary(
            title: "Opphold nå",
            detail: "Opphold neste time.",
            systemImage: "umbrella",
            color: .secondary,
            isFallingNow: false
        )
    }

    /// A second line is only useful when it says more than the weather type
    /// already named in the headline. A generic rain/snow classification is
    /// therefore deliberately omitted.
    private static func precipitationDetail(waterEquivalent: Double, temperature: Double, possible: Bool = false) -> String? {
        let description = PrecipitationCopy.description(
            waterEquivalent: waterEquivalent,
            temperature: temperature
        )
        let generic = temperature <= 1 ? description == "Snøfall" : description == "Regn"
        guard !generic else { return nil }
        return "\(possible ? "Mulig " : "")\(description.lowercased())."
    }

}

struct RulesView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Rule?
    @State private var creating = false
    @State private var testAlertMessage: String?
    @State private var pushFilter: AlertType?

    var body: some View {
        NavigationStack {
            List {
                if var p = store.selected {
                    let visibleRules = Rule.filtered(p.rules, by: pushFilter)
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
                                                    Text("\(value.formatted(.number.precision(.fractionLength(0...1))))\(type == .sol ? " % skydekke" : "°")").tag(value)
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
                                                    Text("2: \(value.formatted(.number.precision(.fractionLength(0)))) % skydekke").tag(value)
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
                                Button("Push \(p.rules.filter { $0.type == type }.count)") {
                                    pushFilter = type
                                }
                                .font(.caption2.weight(.semibold))
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Pushvarsler for \(type.label)")
                                .accessibilityValue("\(p.rules.filter { $0.type == type }.count) oppsatt")
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
                    } header: {
                        HStack {
                            Text("Synlige værrader på Hjem")
                            Spacer()
                            if pushFilter != nil {
                                Button("Vis alle push") { pushFilter = nil }
                                    .font(.caption2)
                            }
                        }
                    } footer: {
                        Text("Grensene gjelder visning uten aktive regler. Aktive varsler beholder egne grenser. Dugggrensen er avstand mellom lufttemperatur og duggpunkt; Yr-verdien endres ikke. Solgrensen er maksimalt skydekke for gult felt.")
                    }
                    Section {
                        ForEach(visibleRules) { r in
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
                        .onDelete { idx in
                            let ids = Set(idx.compactMap { visibleRules.indices.contains($0) ? visibleRules[$0].id : nil })
                            p.rules.removeAll { ids.contains($0.id) }
                            store.update(p)
                            Task { await store.replan() }
                        }
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
            .onChange(of: store.selectedID) { _, _ in
                pushFilter = nil
                editing = nil
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
                                    Text(NotificationCopy.title(for: alert.rule, placeName: alert.placeName, eventAt: alert.eventAt, referenceAt: alert.fireAt, possible: alert.possible, languageStyle: store.alertLanguageStyle))
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
            .navigationTitle("Varsler")
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

private enum PlaceSortMode: String, CaseIterable, Identifiable {
    case automatic
    case manual
    var id: String { rawValue }
    var label: String { self == .automatic ? "Favoritter og avstand" : "Manuell rekkefølge" }
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
    @State private var expandedPlaceID: UUID?
    @AppStorage(PlaceOrderingSettings.homePlaceIDKey) private var homePlaceID = ""
    @AppStorage(PlaceOrderingSettings.sortModeKey) private var placeSortMode = PlaceSortMode.automatic.rawValue

    private var sortMode: PlaceSortMode { PlaceSortMode(rawValue: placeSortMode) ?? .automatic }
    private var orderedPlaces: [Place] {
        guard sortMode == .automatic else { return store.places }
        let favorites = store.resolvedHomeFavorites
        let homeID = UUID(uuidString: homePlaceID) ?? store.selected?.id
        return PlaceOrdering.automatic(store.places, favorite1ID: favorites.right, favorite2ID: favorites.left, homeID: homeID)
    }

    private var alertPlaces: [Place] {
        orderedPlaces.filter { $0.areNotificationsEnabled && $0.rules.contains(where: \.enabled) }
    }

    private var savedPlaces: [Place] {
        orderedPlaces.filter { !$0.areNotificationsEnabled || !$0.rules.contains(where: \.enabled) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if editingPlaces {
                    List {
                Section("Rekkefølge") {
                    Picker("Sorter steder", selection: $placeSortMode) {
                        ForEach(PlaceSortMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .accessibilityHint("Velg automatisk avstandssortering eller manuell rekkefølge")
                    Picker("Hjemsted", selection: $homePlaceID) {
                        Text("Velg hjemsted").tag("")
                        ForEach(store.places) { place in
                            Text(place.displayName).tag(place.id.uuidString)
                        }
                    }
                    .accessibilityHint("Brukes som utgangspunkt for avstandssortering")
                    Text(sortMode == .automatic
                         ? "Favoritt 1 og 2 står først. Resten sorteres etter avstand til hjemstedet."
                         : "Dra stedene i ønsket rekkefølge med håndtaket.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                            PlaceRow(place: place, compact: true)
                        }
                        .onDelete { offsets in remove(offsets, from: alertPlaces) }
                        .onMove { source, destination in move(source, to: destination, within: alertPlaces) }
                    }
                }

                if !savedPlaces.isEmpty {
                    Section("Lagret for å sjekke") {
                        ForEach(savedPlaces) { place in
                            PlaceRow(place: place, compact: true)
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
                    .environment(\.editMode, .constant(sortMode == .manual ? .active : .inactive))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(orderedPlaces) { place in
                                if let forecast = store.forecasts[place.id], !forecast.isEmpty {
                                    let visibleForecast = Array(forecast.prefix(72))
                                    VStack(spacing: 0) {
                                        CurrentWeatherCard(
                                            place: place,
                                            places: store.places,
                                            forecast: visibleForecast,
                                            languageStyle: store.alertLanguageStyle,
                                            isCurrentLocation: false,
                                            onSelect: { _ in },
                                            showsPlaceMenu: false,
                                            showsContainer: false
                                        )
                                        .background(
                                            LinearGradient(
                                                colors: [Color.white, Color(red: 0.96, green: 0.98, blue: 1.0)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            in: RoundedRectangle(cornerRadius: 18)
                                        )
                                        .padding(.horizontal, 4)
                                        .padding(.top, 4)
                                        .contentShape(RoundedRectangle(cornerRadius: 18))
                                        .onTapGesture {
                                            withAnimation(.easeInOut(duration: 0.22)) {
                                                expandedPlaceID = expandedPlaceID == place.id ? nil : place.id
                                            }
                                        }

                                        if expandedPlaceID == place.id {
                                            expandedForecast(for: place, forecast: visibleForecast)
                                        }
                                    }
                                    .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.12)))
                                } else {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            WeatherWordmark(languageStyle: store.alertLanguageStyle)
                                            Text(place.nameWithPreposition)
                                                .font(.headline)
                                                .foregroundStyle(.blue)
                                        }
                                        Text(store.forecastErrors[place.id] ?? "Henter prognose …")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
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

    @ViewBuilder
    private func expandedForecast(for place: Place, forecast: [ForecastHour]) -> some View {
        ForecastVariantsView(
            forecast: forecast,
            rules: place.rulesForDisplay,
            frostMargin: place.localFrostMargin,
            mode: .weatherBands,
            sunThreshold2: place.resolvedDisplaySunThreshold2,
            temperatureLowThreshold: place.resolvedDisplayTemperatureThreshold,
            temperatureHighThreshold: place.resolvedDisplayTemperatureHighThreshold,
            latitude: place.lat,
            longitude: place.lon,
            todayTitle: "Resten av i dag",
            updatedAt: store.lastUpdate,
            isRefreshing: store.isRefreshing,
            isStale: Store.isForecastStale(store.lastUpdate)
        )
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
    }

    private func remove(_ offsets: IndexSet, from places: [Place]) {
        let removedIDs = Set(offsets.compactMap { index in
            places.indices.contains(index) ? places[index].id : nil
        })
        store.removePlaces(ids: removedIDs)
        if let homeID = UUID(uuidString: homePlaceID), removedIDs.contains(homeID) {
            homePlaceID = ""
        }
    }

    private func move(_ source: IndexSet, to destination: Int, within visiblePlaces: [Place]) {
        guard sortMode == .manual else { return }
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
    @AppStorage(WatchPlaceSettings.sourceKey) private var watchPlaceSource = WatchPlaceSource.position.rawValue
    @AppStorage(WatchPlaceSettings.fixedPlaceIDKey) private var watchFixedPlaceID = ""
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showingOnboarding = false
    @AppStorage(LiveWeatherActivitySettings.enabledKey) private var liveActivitiesEnabled = true
    var showsDoneButton = true

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Samme sted som Apple Watch")
                        .font(.subheadline.weight(.semibold))
                    Text("CarPlay og Apple Watch bruker én felles datakilde. Velg aktuell posisjon eller fast sted under Apple Watch nedenfor.")
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
                    Picker("Datakilde", selection: $watchPlaceSource) {
                        ForEach(WatchPlaceSource.allCases) { source in
                            Text(source.label).tag(source.rawValue)
                        }
                    }
                    if WatchPlaceSource(rawValue: watchPlaceSource) == .fixed {
                        Picker("Fast sted", selection: $watchFixedPlaceID) {
                            Text("Velg sted").tag("")
                            ForEach(store.places) { place in
                                Text(place.nameWithPreposition).tag(place.id.uuidString)
                            }
                        }
                    }
                    Text("Aktuell posisjon følger telefonens siste GPS-sted. Fast sted låser Watch til stedet du velger her.")
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
            .onChange(of: watchPlaceSource) { _, _ in store.refreshDisplaySettings() }
            .onChange(of: watchFixedPlaceID) { _, _ in store.refreshDisplaySettings() }
            .fullScreenCover(isPresented: $showingOnboarding) {
                OnboardingWizardView { showingOnboarding = false }
            }
        }
    }
}

private struct PlaceOverviewRow: View {
    let place: Place
    let forecast: [ForecastHour]
    let isExpanded: Bool
    let forecastError: String?

    private var current: ForecastHour? { forecast.first }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(place.resolvedPreposition.rawValue)
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                    Text(place.displayName)
                        .font(.headline)
                    if place.id == Store.shared.selectedID {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Valgt sted")
                    }
                }
                if let current {
                    Text("\(Int(current.temp.rounded()))° · \(place.enabledRuleCount) aktive \(place.enabledRuleCount == 1 ? "varsel" : "varsler")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(forecastError ?? "Henter prognose …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let current {
                Image(systemName: current.cloud <= 20 ? "sun.max.fill" : (current.precipitationRiskRate >= 0.1 ? "cloud.rain.fill" : "cloud.fill"))
                    .foregroundStyle(current.cloud <= 20 ? .orange : .blue)
                Text("\(Int(current.temp.rounded()))°")
                    .font(.title3.weight(.medium))
            }
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isExpanded ? Color.indigo.opacity(0.35) : Color.secondary.opacity(0.14), lineWidth: isExpanded ? 1.5 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "Trykk for å lukke værdetaljene" : "Trykk for å vise værdetaljer")
    }
}

private struct PlaceRow: View {
    @EnvironmentObject private var store: Store
    let place: Place
    var compact = false
    @AppStorage(PlaceOrderingSettings.homePlaceIDKey) private var homePlaceID = ""
    @State private var showingNameEditor = false
    @State private var nameDraft = ""

    private var enabledRules: [Rule] { place.rules.filter(\.enabled) }
    private var nearbyRuleCount: Int { enabledRules.filter(\.onlyWhenNearby).count }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
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
                            .font(compact ? .body.weight(.medium) : .title3.weight(.light))
                    }
                    .buttonStyle(.plain)
                    if homePlaceID == place.id.uuidString {
                        Image(systemName: "house.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Hjemsted")
                    }
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
                if place.enabledRuleCount == 0 {
                    Text("Ingen aktive varsler")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(place.enabledRuleCount) aktive \(place.enabledRuleCount == 1 ? "varsel" : "varsler")" + nearbyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.forecastErrors[place.id] != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            HStack(spacing: compact ? 5 : 8) {
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
                    Button {
                        toggleFavorite(slot: 1)
                    } label: {
                        if compact { Image(systemName: isFavorite1 ? "star.fill" : "star") }
                        else { Label("Stjerne 1", systemImage: isFavorite1 ? "star.fill" : "star") }
                    }
                    .accessibilityLabel("Stjerne 1")
                    .tint(isFavorite1 ? .orange : nil)
                    Button {
                        toggleFavorite(slot: 2)
                    } label: {
                        if compact { Image(systemName: isFavorite2 ? "star.fill" : "star") }
                        else { Label("Stjerne 2", systemImage: isFavorite2 ? "star.fill" : "star") }
                    }
                    .accessibilityLabel("Stjerne 2")
                    .tint(isFavorite2 ? .orange : nil)
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.bordered)
            .controlSize(compact ? .mini : .small)
        }
        .padding(.vertical, compact ? 2 : 5)
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

    private var isFavorite1: Bool { store.resolvedHomeFavorites.right == place.id }
    private var isFavorite2: Bool { store.resolvedHomeFavorites.left == place.id }

    private func toggleFavorite(slot: Int) {
        var favorites = store.resolvedHomeFavorites
        let isSelected = slot == 1 ? isFavorite1 : isFavorite2
        let otherID = slot == 1 ? favorites.left : favorites.right
        let nextID: UUID? = isSelected ? nil : place.id
        if slot == 1 {
            favorites.right = nextID
            if nextID != nil { favorites.left = otherID == nextID ? nil : otherID }
        } else {
            favorites.left = nextID
            if nextID != nil { favorites.right = otherID == nextID ? nil : otherID }
        }
        store.homeFavorites = favorites
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

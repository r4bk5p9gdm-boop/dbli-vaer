import SwiftUI
import CoreLocation

private struct LocationPresenceBadge: View {
    let course: CLLocationDirection?
    let languageStyle: AlertLanguageStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldPulse: Bool {
        LiveLocationBadgeMotionPolicy.shouldPulse(reduceMotion: reduceMotion)
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .stroke(Color.indigo.opacity(0.22), lineWidth: 1)
                    .frame(width: 21, height: 21)
                Image(systemName: "location.north.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.indigo.gradient)
                    .rotationEffect(.degrees(course ?? 0))
                    .symbolEffect(.pulse, options: .repeating, isActive: shouldPulse)
                    .animation(.easeInOut(duration: 0.35), value: course)
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.2))
            }
            Text("GPS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LocationPresenceAccessibilityCopy.label(languageStyle: languageStyle))
    }
}

struct LocalCalibrationView: View {
    @EnvironmentObject var store: Store
    let placeID: UUID
    @State private var date = Date()
    @State private var temperature = ""
    @State private var frost = "Vet ikke"
    @State private var surface = "Gress"
    @State private var visibleObservationCount = 50
    @State private var saveSucceeded: Bool?

    private var measured: Double? { Double(temperature.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
    private var languageStyle: AlertLanguageStyle { store.alertLanguageStyle }
    private func copy(_ bokmal: String, _ english: String) -> String {
        LocalCalibrationCopy.text(bokmal, english: english, style: languageStyle)
    }
    private var valid: Bool {
        (temperature.isEmpty || measured.map { $0.isFinite && (-60...60).contains($0) } == true)
            && (measured != nil || frost != "Vet ikke")
    }

    var body: some View {
        Form {
            if let place = store.places.first(where: { $0.id == placeID }) {
                Section(copy("Observasjon \(place.nameWithPreposition)", "Observation \(place.nameWithPreposition)")) {
                    DatePicker(copy("Tidspunkt", "Time"), selection: $date, in: Date().addingTimeInterval(-48 * 3600)...Date())
                    TextField(copy("Målt lufttemperatur (valgfritt)", "Measured air temperature (optional)"), text: $temperature)
                        .keyboardType(.numbersAndPunctuation)
                    Picker(copy("Frost i natt", "Frost last night"), selection: $frost) {
                        Text(copy("Vet ikke", "Unknown")).tag("Vet ikke")
                        Text(copy("Ja", "Yes")).tag("Ja")
                        Text(copy("Nei", "No")).tag("Nei")
                    }
                    if frost == "Ja" {
                        Picker(copy("Hvor?", "Where?"), selection: $surface) {
                            Text(copy("Gress", "Grass")).tag("Gress")
                            Text(copy("Bil/tak", "Car/roof")).tag("Bil/tak")
                            Text(copy("Gress og bil/tak", "Grass and car/roof")).tag("Gress og bil/tak")
                            Text(copy("Annet", "Other")).tag("Annet")
                        }
                    }
                    Text(copy(
                        "Temperatur gjelder valgt tidspunkt. Frost gjelder natten før dette tidspunktet. Rim på en overflate er ikke en måling av lufttemperatur.",
                        "Temperature is for the selected time. Frost is for the night before it. Frost on a surface is not an air-temperature measurement."
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(copy("Lagre observasjon", "Save observation")) {
                        let succeeded = store.recordObservation(place: place, at: date, temperature: measured,
                            frost: frost == "Vet ikke" ? nil : frost == "Ja", surface: frost == "Ja" ? surface : "")
                        saveSucceeded = succeeded
                        if succeeded {
                            temperature = ""; frost = "Vet ikke"
                        }
                    }.disabled(!valid)
                }
                Section(copy("Registreringer", "Records")) {
                    let observations = store.calibration.observations.filter { $0.place.id == placeID }
                    if observations.isEmpty { Text(copy("Ingen registreringer ennå.", "No records yet.")).foregroundStyle(.secondary) }
                    ForEach(observations.prefix(visibleObservationCount)) { observation in
                        DisclosureGroup {
                            if let offset = observation.suggestedTemperatureOffset {
                                Text(copy("Målt avvik fra Yr: \(offset.formatted(.number.precision(.fractionLength(1)))) °C", "Measured difference from Yr: \(offset.formatted(.number.precision(.fractionLength(1)))) °C"))
                                Text(copy("Én måling er ikke nok til å fastslå en fast justering. Endre innstillingen manuelt når du har nok grunnlag.", "One measurement is not enough to establish a permanent adjustment. Change the setting manually when you have enough evidence."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let frost = observation.frost {
                                Text(frost
                                     ? copy("Frost: \(observation.surface)", "Frost: \(LocalCalibrationCopy.surface(observation.surface, style: languageStyle))")
                                     : copy("Ingen frost observert", "No frost observed"))
                            }
                            if observation.measuredTemperature != nil, observation.frost != nil {
                                if let night = observation.nightForecast, let minimum = night.hours.map(\.temp).min() {
                                    Text(copy("Nattens varslede minimum: \(minimum.formatted()) °C (hentet \(night.fetchedAt.formatted(date: .abbreviated, time: .shortened)))", "Forecast low overnight: \(minimum.formatted()) °C (fetched \(night.fetchedAt.formatted(date: .abbreviated, time: .shortened)))"))
                                        .font(.caption)
                                } else { Text(copy("Ingen prognose fra før natten lagret.", "No forecast from before that night was saved.")).font(.caption) }
                            }
                            if observation.evidence.isEmpty { Text(copy("Ingen lagret prognose for sammenligning.", "No saved forecast is available for comparison.")).foregroundStyle(.secondary) }
                            if let fetched = observation.forecastFetchedAt {
                                Text(copy("Prognose hentet \(fetched.formatted(date: .abbreviated, time: .shortened))", "Forecast fetched \(fetched.formatted(date: .abbreviated, time: .shortened))")).font(.caption)
                            }
                            ForEach(observation.evidence) { hour in
                                Text(copy("\(hour.time.formatted(date: .omitted, time: .shortened)) · Yr \(hour.temp.formatted(.number.precision(.fractionLength(1))))° · duggpunkt \(hour.dew.formatted(.number.precision(.fractionLength(1))))° · vind \(hour.wind.formatted()) m/s · skyer \(hour.cloud.formatted()) %", "\(hour.time.formatted(date: .omitted, time: .shortened)) · Yr \(hour.temp.formatted(.number.precision(.fractionLength(1))))° · dew point \(hour.dew.formatted(.number.precision(.fractionLength(1))))° · wind \(hour.wind.formatted()) m/s · clouds \(hour.cloud.formatted()) %"))
                                    .font(.caption)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(observation.observedAt.formatted(date: .abbreviated, time: .shortened))
                                if let temp = observation.measuredTemperature { Text(copy("Målt \(temp.formatted()) °C", "Measured \(temp.formatted()) °C")).font(.caption) }
                            }
                        }
                        .swipeActions {
                            Button(copy("Slett", "Delete"), role: .destructive) {
                                if !store.removeObservation(id: observation.id) { saveSucceeded = false }
                            }
                        }
                    }
                    if observations.count > visibleObservationCount {
                        Button(copy("Vis flere registreringer", "Show more records")) {
                            visibleObservationCount += 50
                        }
                    }
                }
                Section {
                    Text(copy("Prognoser beholdes rullerende i 48 timer og ryddes ved neste oppdatering eller oppstart. Registrerte observasjoner beholder sitt sammenligningsgrunnlag. Netatmo og automatisk kurvejustering er ikke aktivert.", "Forecasts are retained for a rolling 48 hours and cleared on the next update or app launch. Saved observations keep their comparison data. Netatmo and automatic curve adjustment are not enabled."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(copy("Lokale målinger", "Local measurements"))
        .onChange(of: placeID) { _, _ in visibleObservationCount = 50 }
        .alert(copy("Registrering", "Record"), isPresented: Binding(
            get: { saveSucceeded != nil },
            set: { if !$0 { saveSucceeded = nil } }
        )) {
            Button(copy("OK", "OK"), role: .cancel) { saveSucceeded = nil }
        } message: {
            Text(saveSucceeded == true
                 ? copy("Observasjonen er lagret.", "The observation was saved.")
                 : copy("Kunne ikke lagre endringen. Kontroller ledig lagringsplass og prøv igjen.", "Could not save the change. Check available storage and try again."))
        }
    }
}

struct ContentView: View {
    private enum Tab: Hashable { case home, places, settings }

    @EnvironmentObject var store: Store
    @AppStorage("varsel.onboardingCompleted") private var onboardingCompleted = false
    @AppStorage(PlaceOrderingSettings.homePlaceIDKey) private var homePlaceID = ""
    @AppStorage(PlaceOrderingSettings.cabinPlaceIDKey) private var cabinPlaceID = ""
    @State private var showingOnboarding = false
    @State private var selectedTab: Tab = .home

    private var quickPlaceTabs: [HomeSwipeSelection.NavigationDestination] {
        HomeSwipeSelection.navigationDestinations(
            positionID: store.currentLocationPlaceID,
            homeID: UUID(uuidString: homePlaceID) ?? store.selected?.id,
            cabinID: UUID(uuidString: cabinPlaceID),
            availableIDs: Set(store.places.map(\.id)),
            languageStyle: store.alertLanguageStyle
        )
    }

    private var navigationPlaceIDs: [UUID] {
        quickPlaceTabs.map(\.placeID)
    }

    private var selectedQuickPlaceID: UUID? {
        HomeSwipeSelection.selectedNavigationID(
            selectedID: store.selectedID,
            selectionIsCurrentLocation: store.selectionIsCurrentLocation,
            positionID: store.currentLocationPlaceID,
            homeID: UUID(uuidString: homePlaceID) ?? store.selected?.id,
            destinations: quickPlaceTabs
        )
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(navigationPlaceIDs: navigationPlaceIDs)
                .tag(Tab.home)
            PlacesView()
                .tag(Tab.places)
            GlobalSettingsView(showsDoneButton: false)
                .tag(Tab.settings)
        }
        .tint(Color(red: 0.09, green: 0.14, blue: 0.23))
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            mainNavigationBar
        }
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

    private var mainNavigationBar: some View {
        HStack(spacing: 0) {
            ForEach(quickPlaceTabs) { item in
                navigationButton(
                    item.title,
                    systemImage: item.systemImage,
                    isSelected: selectedTab == .home && selectedQuickPlaceID == item.placeID,
                    showsLiveDot: item.representsCurrentPosition,
                    accessibilityLabel: item.accessibilityLabel(languageStyle: store.alertLanguageStyle),
                    accessibilityHint: item.representsCurrentPosition
                        ? (store.alertLanguageStyle == .english ? "Shows weather for your live GPS location" : WeatherLanguage.text("Viser vær for live-posisjonen", style: store.alertLanguageStyle))
                        : (store.alertLanguageStyle == .english ? "Shows weather for this place" : WeatherLanguage.text("Viser vær for dette stedet", style: store.alertLanguageStyle))
                ) {
                    guard let place = store.places.first(where: { $0.id == item.placeID }) else { return }
                    store.select(place, fromCurrentLocation: item.representsCurrentPosition)
                    selectedTab = .home
                }
            }
            navigationButton(
                FixedNavigationDestination.places.title(languageStyle: store.alertLanguageStyle),
                systemImage: "mappin.and.ellipse",
                isSelected: selectedTab == .places
            ) {
                selectedTab = .places
            }
            navigationButton(
                FixedNavigationDestination.settings.title(languageStyle: store.alertLanguageStyle),
                systemImage: "gearshape",
                isSelected: selectedTab == .settings
            ) {
                selectedTab = .settings
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func navigationButton(
        _ title: String,
        systemImage: String,
        isSelected: Bool,
        showsLiveDot: Bool = false,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    if showsLiveDot {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.25))
                            .offset(x: 3, y: 2)
                    }
                }
                .frame(height: 19)
                Text(title)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isSelected ? Color.indigo : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 43)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.indigo.opacity(0.09))
                        .padding(.horizontal, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(accessibilityHint ?? "")
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
    var navigationPlaceIDs: [UUID]? = nil
    @State private var editing: Rule?
    @State private var showingSettings = false
    @State private var transitionDirection: Edge = .trailing
    @GestureState private var liveSwipeOffset: CGFloat = 0

    private var forecastHeaderTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nb_NO")
        formatter.dateFormat = "EEEE d. MMM"
        let title = formatter.string(from: Date())
        return "Resten av i dag, \(title)"
    }

    private var swipePlaces: [Place] {
        // The bottom quick-navigation destinations and the swipe sequence
        // share one order; Watch and CarPlay remain on their own data source.
        let ids = navigationPlaceIDs ?? store.homeSwipePlaceIDs
        return ids.compactMap { id in
            store.places.first { $0.id == id }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ZStack {
                LazyVStack(alignment: .leading, spacing: 14) {
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
                        let forecastUpdatedAt = store.forecastUpdatedAt(for: p.id)
                        // The Home view is a three-day visual forecast. Its
                        // range is intentionally independent of the shorter
                        // 24-hour horizon used by the rotating alert text.
                        let visibleForecast = ForecastDaySelection.hoursForVisibleDays(from: fc)
                        if !visibleForecast.isEmpty {
                            VStack(spacing: 0) {
                                CurrentWeatherCard(
                                    place: p,
                                    places: store.places,
                                    forecast: visibleForecast,
                                    languageStyle: store.alertLanguageStyle,
                                    isCurrentLocation: store.selectionIsCurrentLocation,
                                    locationCourse: store.selectionIsCurrentLocation ? store.currentLocationCourse : nil,
                                    onSelect: { place in store.select(place) },
                                    onEdit: { showingSettings = true },
                                    showsPlaceMenu: false,
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
                                    languageStyle: store.alertLanguageStyle,
                                    frostMargin: p.localFrostMargin,
                                    mode: .weatherBands,
                                    sunThreshold: p.displayThreshold(for: .sol),
                                    sunThreshold2: p.resolvedDisplaySunThreshold2,
                                    temperatureLowThreshold: p.resolvedDisplayTemperatureThreshold,
                                    temperatureHighThreshold: p.resolvedDisplayTemperatureHighThreshold,
                                    displayDewThreshold: p.displayThreshold(for: .dugg),
                                    displayGustThreshold: p.displayThreshold(for: .vind),
                                    latitude: p.lat,
                                    longitude: p.lon,
                                    todayTitle: forecastHeaderTitle,
                                    updatedAt: forecastUpdatedAt,
                                    isRefreshing: store.isRefreshing,
                                    isStale: Store.isForecastStale(forecastUpdatedAt)
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
                            .accessibilityLabel(HomeSwipeSelection.pageAccessibilityLabel(
                                index: activeIndexForSelectedPlace + 1,
                                count: pageCount,
                                languageStyle: store.alertLanguageStyle
                            ))
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

                    if let p = store.selected {
                        CurrentPlacePushAlertsSection(
                            place: p,
                            forecast: store.forecasts[p.id] ?? [],
                            nearbyPlaceIDs: store.nearbyPlaceIDs,
                            notificationsAuthorized: store.notificationsAuthorized,
                            languageStyle: store.alertLanguageStyle
                        )
                        .padding(.horizontal, 4)
                    }
                }
                .offset(x: effectiveSwipeOffset)
                .padding()
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
                    ContextHelpButton(topic: .home)
                }
            }
            .refreshable { _ = await store.refreshAll() }
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 8)
                .updating($liveSwipeOffset) { value, offset, transaction in
                    guard abs(value.translation.width) > abs(value.translation.height) else {
                        offset = 0
                        return
                    }
                    transaction.animation = .interactiveSpring(response: 0.24, dampingFraction: 0.86)
                    offset = value.translation.width
                }
                .onEnded { value in
                let uniqueIDs = swipePlaces.map(\.id)
                guard let current = store.selected,
                      let next = HomeSwipeSelection.nextIndex(
                        currentID: current.id,
                        placeIDs: uniqueIDs,
                        horizontalTranslation: value.translation.width,
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        if let place = interactiveSwipeNeighbor,
                           let forecast = interactiveSwipeForecast,
                           !forecast.isEmpty {
                            HomeSwipeIncomingPage(
                                place: place,
                                places: store.places,
                                forecast: forecast,
                                languageStyle: store.alertLanguageStyle,
                                isCurrentLocation: place.id == store.currentLocationPlaceID,
                                frostMargin: place.localFrostMargin,
                                sunThreshold: place.displayThreshold(for: .sol),
                                sunThreshold2: place.resolvedDisplaySunThreshold2,
                                temperatureLowThreshold: place.resolvedDisplayTemperatureThreshold,
                                temperatureHighThreshold: place.resolvedDisplayTemperatureHighThreshold,
                                todayTitle: forecastHeaderTitle,
                                updatedAt: store.forecastUpdatedAt(for: place.id),
                                isRefreshing: store.isRefreshing
                            )
                            .frame(width: geometry.size.width)
                            .offset(x: effectiveSwipeOffset < 0
                                ? geometry.size.width + effectiveSwipeOffset
                                : -geometry.size.width + effectiveSwipeOffset)
                            .zIndex(2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
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

private struct CurrentPlacePushAlertsSection: View {
    let place: Place
    let forecast: [ForecastHour]
    let nearbyPlaceIDs: Set<UUID>
    let notificationsAuthorized: Bool?
    let languageStyle: AlertLanguageStyle

    @State private var alertExpansion = PlaceExpansionState()

    private var plannedPushAlerts: [PlannedAlert] {
        Planner.planAll(
            places: [place],
            forecasts: [place.id: forecast],
            nearbyPlaceIDs: nearbyPlaceIDs
        )
    }

    private var enabledPushRules: [Rule] {
        place.rules.filter { $0.enabled && !($0.isDisplayOnly) }
    }

    private func localized(_ bokmal: String, english: String) -> String {
        languageStyle == .english ? english : WeatherLanguage.text(bokmal, style: languageStyle)
    }

    var body: some View {
        let upcomingAlerts = plannedPushAlerts
        let showsAllAlerts = alertExpansion.expandedPlaceID == place.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Kommende pushvarsler", english: "Upcoming push alerts"))
                        .font(.headline)
                    Text(place.nameWithPreposition)

    private var interactiveSwipeNeighbor: Place? {
        guard abs(liveSwipeOffset) > 8,
              let selectedID = store.selected?.id,
              let selectedIndex = swipePlaces.firstIndex(where: { $0.id == selectedID }) else { return nil }
        let neighborIndex = selectedIndex + (liveSwipeOffset < 0 ? 1 : -1)
        guard swipePlaces.indices.contains(neighborIndex) else { return nil }
        return swipePlaces[neighborIndex]
    }

    private var effectiveSwipeOffset: CGFloat {
        interactiveSwipeNeighbor == nil ? 0 : liveSwipeOffset
    }

    private var interactiveSwipeForecast: [ForecastHour]? {
        guard let place = interactiveSwipeNeighbor else { return nil }
        return ForecastDaySelection.hoursForVisibleDays(from: store.forecasts[place.id] ?? [])
    }
}

private struct HomeSwipeIncomingPage: View {
    let place: Place
    let places: [Place]
    let forecast: [ForecastHour]
    let languageStyle: AlertLanguageStyle
    let isCurrentLocation: Bool
    let frostMargin: Double
    let sunThreshold: Double
    let sunThreshold2: Double
    let temperatureLowThreshold: Double
    let temperatureHighThreshold: Double
    let todayTitle: String
    let updatedAt: Date?
    let isRefreshing: Bool

    var body: some View {
        VStack(spacing: 0) {
            CurrentWeatherCard(
                place: place,
                places: places,
                forecast: forecast,
                languageStyle: languageStyle,
                isCurrentLocation: isCurrentLocation,
                onSelect: { _ in },
                showsPlaceMenu: false,
                showsContainer: false
            )
            .background(
                LinearGradient(
                    colors: isCurrentLocation
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
                forecast: forecast,
                rules: place.rulesForDisplay,
                languageStyle: languageStyle,
                frostMargin: frostMargin,
                mode: .weatherBands,
                sunThreshold: sunThreshold,
                sunThreshold2: sunThreshold2,
                temperatureLowThreshold: temperatureLowThreshold,
                temperatureHighThreshold: temperatureHighThreshold,
                displayDewThreshold: place.displayThreshold(for: .dugg),
                displayGustThreshold: place.displayThreshold(for: .vind),
                latitude: place.lat,
                longitude: place.lon,
                todayTitle: todayTitle,
                updatedAt: updatedAt,
                isRefreshing: isRefreshing,
                isStale: Store.isForecastStale(updatedAt)
            )
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 4)
        }
        .padding()
        .background(Color(uiColor: .systemBackground))
    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if notificationsAuthorized != false && place.areNotificationsEnabled && !upcomingAlerts.isEmpty {
                    Text("\(upcomingAlerts.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(uiColor: .tertiarySystemBackground), in: Capsule())
                        .accessibilityLabel(localized("\(upcomingAlerts.count) planlagte pushvarsler", english: "\(upcomingAlerts.count) planned push alerts"))
                }
            }

            if notificationsAuthorized == false {
                emptyState(localized("Varsler er avslått i iPhone-innstillingene.", english: "Notifications are disabled in iPhone Settings."))
            } else if !place.areNotificationsEnabled {
                emptyState(localized("Pushvarsler er slått av for dette stedet.", english: "Push alerts are turned off for this place."))
            } else if enabledPushRules.isEmpty {
                emptyState(localized("Ingen pushvarsler er slått på for dette stedet.", english: "No push alerts are enabled for this place."))
            } else if forecast.isEmpty {
                emptyState(localized("Venter på værvarsel før pushvarsler kan beregnes.", english: "Waiting for a forecast to calculate push alerts."))
            } else if upcomingAlerts.isEmpty {
                emptyState(localized("Ingen pushvarsler er ventet ut fra prognosen nå.", english: "No push alerts are expected from the current forecast."))
            } else {
                VStack(spacing: 9) {
                    ForEach(Array(upcomingAlerts.prefix(showsAllAlerts ? upcomingAlerts.count : 3))) { alert in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: alert.rule.type.systemImage)
                                .foregroundStyle(alert.rule.type.color)
                                .frame(width: 20)
                                .padding(.top, 2)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(NotificationCopy.title(
                                    for: alert.rule,
                                    placeName: alert.placeName,
                                    eventAt: alert.eventAt,
                                    referenceAt: alert.fireAt,
                                    possible: alert.possible,
                                    languageStyle: languageStyle
                                ))
                                .font(.subheadline.weight(.semibold))
                                Text(NotificationCopy.message(
                                    for: alert.rule,
                                    eventAt: alert.eventAt,
                                    referenceAt: alert.fireAt,
                                    possible: alert.possible,
                                    eventDetail: alert.eventDetail,
                                    languageStyle: languageStyle
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                Text(localized("Sendes \(eventTimePhrase(alert.fireAt))", english: "Scheduled \(eventTimePhrase(alert.fireAt))"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.blue)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if upcomingAlerts.count > 3 {
                    Button(showsAllAlerts
                           ? localized("Vis færre", english: "Show fewer")
                           : localized("Vis alle \(upcomingAlerts.count) varsler", english: "Show all \(upcomingAlerts.count) alerts")) {
                        alertExpansion.toggle(place.id)
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

private struct CurrentWeatherCard: View {
    let place: Place
    let places: [Place]
    let forecast: [ForecastHour]
    let languageStyle: AlertLanguageStyle
    let isCurrentLocation: Bool
    var locationCourse: CLLocationDirection? = nil
    let onSelect: (Place) -> Void
    var onEdit: (() -> Void)? = nil
    var showsPlaceMenu = true
    var showsContainer = true

    private var current: ForecastHour {
        ForecastHourSelection.current(in: forecast, at: Date()) ?? forecast[0]
    }
    private var precipitation: CurrentPrecipitationSummary {
        CurrentPrecipitationSummary.make(
            from: forecast, current: current, languageStyle: languageStyle
        )
    }
    private var rotatingStatuses: [WeatherStatus] {
        return WeatherStatus.uniqueByType(
            Planner.rollingStatuses(for: place, forecast: forecast)
                .filter {
                    $0.type != .regn && $0.type != .sno
                        && Planner.isWithinRotatingHomeHorizon($0.eventAt)
                }
        )
            .prefix(4)
            .map { $0 }
    }

    private var hasPrecipitationHeadline: Bool {
        !precipitation.title.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 7) {
                WeatherWordmark(languageStyle: languageStyle)

                if isCurrentLocation {
                    let heading = CurrentLocationPlaceHeading(place: place)
                    HStack(alignment: .center, spacing: 4) {
                        Text(heading.prefixedPreposition)
                            .font(.caption.weight(.bold).italic())
                            .foregroundStyle(.white)
                            .fixedSize()

                        if showsPlaceMenu {
                            Menu {
                                placeMenuItems
                            } label: {
                                currentLocationPlaceName(showsChevron: true, heading: heading)
                            }
                            .layoutPriority(1)
                        } else {
                            currentLocationPlaceName(showsChevron: false, heading: heading)
                                .layoutPriority(1)
                        }
                    }
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
                    .rotationEffect(.degrees(-2))
                    // Overlay leaves the original text baseline and card height unchanged.
                    .overlay(alignment: .topLeading) {
                        LocationPresenceBadge(course: locationCourse, languageStyle: languageStyle)
                            .offset(x: 7, y: -19)
                    }
                    .accessibilityElement(children: .contain)
                }

                if !isCurrentLocation {
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
                            placeMenuItems
                        } label: {
                            PlaceTitle(place: place, showsChevron: true, isCurrentLocation: false)
                        }
                        .layoutPriority(1)
                    } else {
                        PlaceTitle(place: place, showsChevron: false, isCurrentLocation: false)
                            .layoutPriority(1)
                    }
                }

                Spacer(minLength: 0)

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
                    Image(systemName: currentWeatherIcon.systemImage)
                        .font(.system(size: 27, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(currentWeatherIcon.color)
                        .frame(width: 36, height: 36)
                        .accessibilityLabel(currentWeatherIcon.label)
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
                    isActive: isDaylightNow && current.cloud <= 65
                )
            }

            if hasPrecipitationHeadline || !rotatingStatuses.isEmpty {
                SwiftUI.TimelineView(.periodic(from: .now, by: 6)) { timeline in
                    let count = rotatingStatuses.count + (hasPrecipitationHeadline ? 1 : 0)
                    let index = Int(timeline.date.timeIntervalSince1970 / 6) % count
                    if hasPrecipitationHeadline && index == 0 {
                        headline(
                            title: WeatherLanguage.text(precipitation.title, style: languageStyle),
                            detail: precipitation.detail.map { WeatherLanguage.text($0, style: languageStyle) },
                            systemImage: precipitation.systemImage,
                            color: precipitation.color
                        )
                    } else {
                        let statusIndex = hasPrecipitationHeadline ? index - 1 : index
                        let status = rotatingStatuses[statusIndex]
                        let statusTitle = rotatingTitle(for: status)
                        headline(
                            title: WeatherLanguage.text(statusTitle, style: languageStyle),
                            detail: Planner.rotatingStatusDetail(
                                for: status, place: place, forecast: forecast,
                                headlineDescribesTime: Planner.headlineDescribesTime(statusTitle)
                            )
                                .map { WeatherLanguage.text($0, style: languageStyle) },
                            systemImage: status.type.systemImage,
                            color: status.type.color
                        )
                    }
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

    @ViewBuilder
    private var placeMenuItems: some View {
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
    }

    private func currentLocationPlaceName(
        showsChevron: Bool,
        heading: CurrentLocationPlaceHeading
    ) -> some View {
        HStack(spacing: 3) {
            Text(heading.placeName)
                .font(.system(size: 21, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(languageStyle == .english ? "Here \(place.nameWithPreposition)" : heading.visibleText), \(LocationPresenceAccessibilityCopy.label(languageStyle: languageStyle))")
        .accessibilityHint(LocationPresenceAccessibilityCopy.hint(languageStyle: languageStyle))
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
        guard isDaylightNow else {
            return ("moon.stars.fill", "Sol", "sola er nede", Color.indigo)
        }
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
                .accessibilityLabel(AlertEditingAccessibilityCopy.label(
                    placeName: place.displayName,
                    languageStyle: languageStyle
                ))
            }
        }
    }

    private var currentCondition: CurrentWeatherCondition {
        CurrentWeatherCondition.resolve(current, precipitationIsFalling: precipitation.isFallingNow)
    }

    private var isDaylightNow: Bool {
        // `current.time` is the timestamp of Yr's latest hourly sample. Near
        // sunset that sample can still be in daylight after the sun has set.
        SolarCycle.isDaylight(Date(), latitude: place.lat, longitude: place.lon)
    }

    private var currentWeatherIcon: (systemImage: String, color: Color, label: String) {
        if !isDaylightNow {
            switch currentCondition {
            case .clear, .partlyCloudy:
                return ("moon.stars.fill", Color.indigo, "Natt")
            default:
                break
            }
        }
        return (currentCondition.systemImage, currentCondition.color, currentCondition.label)
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

    private func rotatingTitle(for status: WeatherStatus) -> String {
        let rule = Planner.displayRule(for: status, place: place)
        return RotatingAlertCopy.headline(
            for: status, rule: rule, languageStyle: languageStyle
        )
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

struct CurrentPrecipitationSummary {
    let title: String
    let detail: String?
    let systemImage: String
    let color: Color
    let isFallingNow: Bool

    static func make(
        from forecast: [ForecastHour], current: ForecastHour,
        languageStyle: AlertLanguageStyle = .inntrondersk, now: Date = Date()
    ) -> CurrentPrecipitationSummary {
        let horizon = now.addingTimeInterval(Planner.rotatingHomeHorizon)
        let samples = forecast.flatMap { $0.radarSamples ?? [] }.sorted { $0.time < $1.time }
        let radarInterval = PrecipitationSample.nominalInterval(in: samples)
        let latest = samples.last { $0.time <= now }

        if let latest, now.timeIntervalSince(latest.time) < radarInterval, latest.rate >= 0.1 {
            return CurrentPrecipitationSummary(
                title: RotatingAlertCopy.currentHeadline(
                    for: current.temp <= 1 ? .sno : .regn,
                    languageStyle: languageStyle
                ),
                detail: radarDetail(
                    samples: samples, startingAt: latest, temperature: current.temp,
                    interval: radarInterval, now: now
                ),
                systemImage: current.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: true
            )
        }

        if let upcoming = samples.first(where: {
            $0.time > now
                && $0.time <= horizon
                && $0.rate >= 0.1
        }) {
            let eventTemperature = forecast.last(where: { $0.time <= upcoming.time })?.temp ?? current.temp
            let kind: AlertType = eventTemperature <= 1 ? .sno : .regn
            let status = WeatherStatus(
                ruleID: UUID(), type: kind, text: "", eventAt: upcoming.time,
                isNow: false
            )
            return CurrentPrecipitationSummary(
                title: RotatingAlertCopy.headline(
                    for: status, rule: nil, languageStyle: languageStyle, now: now
                ),
                detail: radarDetail(
                    samples: samples, startingAt: upcoming, temperature: eventTemperature,
                    interval: radarInterval,
                    startTimeAlreadyInHeadline: Planner.headlineDescribesTime(
                        RotatingAlertCopy.headline(
                            for: status, rule: nil, languageStyle: languageStyle, now: now
                        )
                    )
                ),
                systemImage: eventTemperature <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: false
            )
        }

        let currentHourIsFresh = current.time <= now && now.timeIntervalSince(current.time) < 3_600
        if currentHourIsFresh && current.precip >= 0.1 {
            let type: AlertType = current.temp <= 1 ? .sno : .regn
            return CurrentPrecipitationSummary(
                title: RotatingAlertCopy.currentHourHeadline(
                    for: type, possible: false, languageStyle: languageStyle
                ),
                detail: forecastDetail(
                    forecast: forecast, startingAt: current.time,
                    waterEquivalent: current.precip, temperature: current.temp,
                    includeStartClock: false, now: now
                ),
                systemImage: current.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill",
                color: .blue,
                isFallingNow: false
            )
        }

        let currentForecastRisk = (current.precipProbability ?? 0) >= 20
            ? max(current.precip, current.precipMax ?? 0)
            : current.precip
        if currentHourIsFresh && currentForecastRisk >= 0.1 {
            let type: AlertType = current.temp <= 1 ? .sno : .regn
            return CurrentPrecipitationSummary(
                title: RotatingAlertCopy.currentHourHeadline(
                    for: type, possible: true, languageStyle: languageStyle
                ),
                detail: forecastDetail(
                    forecast: forecast,
                    startingAt: current.time,
                    waterEquivalent: current.precipMax ?? currentForecastRisk,
                    temperature: current.temp,
                    possible: true, includeStartClock: false, now: now
                ),
                systemImage: "umbrella.fill",
                color: .blue.opacity(0.75),
                isFallingNow: false
            )
        }

        if let upcoming = forecast.first(where: {
            $0.time > now && $0.time <= horizon && $0.precipitationRiskRate >= 0.1
        }) {
            let possible = upcoming.precipitationRate < 0.1
            let kind: AlertType = upcoming.temp <= 1 ? .sno : .regn
            let status = WeatherStatus(
                ruleID: UUID(), type: kind, text: "", eventAt: upcoming.time,
                isNow: false, possible: possible
            )
            let title = RotatingAlertCopy.headline(
                for: status, rule: nil, languageStyle: languageStyle, now: now
            )
            return CurrentPrecipitationSummary(
                title: title,
                detail: forecastDetail(
                    forecast: forecast,
                    startingAt: upcoming.time,
                    waterEquivalent: possible ? (upcoming.precipMax ?? upcoming.precipitationRiskRate) : upcoming.precip,
                    temperature: upcoming.temp,
                    possible: possible,
                    includeStartClock: !Planner.headlineDescribesTime(title)
                ),
                systemImage: possible ? "umbrella.fill" : (upcoming.temp <= 1 ? "cloud.snow.fill" : "cloud.rain.fill"),
                color: possible ? .blue.opacity(0.75) : .blue,
                isFallingNow: false
            )
        }

        return CurrentPrecipitationSummary(
            // Dry weather is intentionally silent in the rolling alert area;
            // this space is reserved for actual precipitation or another
            // active status (wind, temperature, dew, frost, or sun).
            title: "",
            detail: nil,
            systemImage: "umbrella",
            color: .secondary,
            isFallingNow: false
        )
    }

    /// The second line adds intensity and a contiguous duration. The exact
    /// start clock is omitted when the headline already includes it.
    private static func forecastDetail(
        forecast: [ForecastHour], startingAt date: Date, waterEquivalent: Double,
        temperature: Double, possible: Bool = false, includeStartClock: Bool = true,
        now: Date? = nil
    ) -> String? {
        let description = PrecipitationCopy.description(
            waterEquivalent: waterEquivalent,
            temperature: temperature
        )
        guard let start = forecast.firstIndex(where: { abs($0.time.timeIntervalSince(date)) < 60 }) else {
            return precipitationDescription(description, temperature: temperature)
        }
        var duration = 0
        var previousTime: Date?
        for hour in forecast[start...] {
            let rate = possible ? hour.precipitationRiskRate : hour.precipitationRate
            guard rate >= 0.1,
                  (hour.temp <= 1) == (temperature <= 1),
                  previousTime.map({ abs(hour.time.timeIntervalSince($0) - 3_600) < 60 }) ?? true
            else { break }
            duration += 1
            previousTime = hour.time
        }
        guard duration > 0 else {
            return precipitationDescription(description, temperature: temperature)
        }
        // The approved Hjem template uses a bounded shower window for a long
        // uncertain rain period. This branch is only for future forecasts;
        // the current-hour card keeps its shorter «opptil …» wording.
        if possible, now == nil, temperature > 1, duration >= 4 {
            return "Opptil \(duration) timer regnbyger på \(weekdayLabel(forecast[start].time))."
        }
        let remainingSeconds = max(0, Double(duration) * 3_600 - (now?.timeIntervalSince(forecast[start].time) ?? 0))
        let durationText: String
        if remainingSeconds < 3_600 {
            let quarters = max(1, Int((remainingSeconds / (15 * 60)).rounded()))
            durationText = "\(min(3, quarters) * 15) min"
        } else {
            let hours = max(1, Int((remainingSeconds / 3_600).rounded()))
            durationText = hours == 1 ? "1 time" : "\(hours) timer"
        }
        let intensity = description.lowercased()
        // The approved compact rain/snow form places the description directly
        // after the duration: «4 timer litt regn» / «2 timer lett snøfall».
        let connector = " "
        let summary = possible
            ? "Opptil \(durationText)\(connector)\(intensity)"
            : "\(durationText)\(connector)\(intensity)"
        let startClock = includeStartClock ? " fra kl. \(shortClockLabel(forecast[start].time))" : ""
        return "\(summary)\(startClock)."
    }

    private static func radarDetail(
        samples: [PrecipitationSample], startingAt sample: PrecipitationSample,
        temperature: Double, interval: TimeInterval, now: Date? = nil,
        startTimeAlreadyInHeadline: Bool = false
    ) -> String? {
        let description = PrecipitationCopy.description(waterEquivalent: sample.rate, temperature: temperature)
        guard let start = samples.firstIndex(of: sample) else {
            return precipitationDescription(description, temperature: temperature)
        }
        var last = sample
        for value in samples[start...] {
            guard value.rate >= 0.1,
                  value == sample || abs(value.time.timeIntervalSince(last.time) - interval) < 60
            else { break }
            last = value
        }
        let end = last.time.addingTimeInterval(interval)
        let seconds = max(0, end.timeIntervalSince(now ?? sample.time))
        let duration: String
        if seconds < 3_600 {
            let quarters = max(1, Int((seconds / (15 * 60)).rounded()))
            duration = "\(min(3, quarters) * 15) min"
        } else {
            let hours = max(1, Int((seconds / 3_600).rounded()))
            duration = hours == 1 ? "1 time" : "\(hours) timer"
        }
        if now != nil { return "\(description) i \(duration) til." }
        let startClock = startTimeAlreadyInHeadline ? "" : " fra kl. \(shortClockLabel(sample.time))"
        return "\(duration) \(description.lowercased())\(startClock)."
    }

    private static func precipitationDescription(_ description: String, temperature: Double) -> String? {
        let generic = temperature <= 1 ? description == "Snøfall" : description == "Regn"
        guard !generic else { return nil }
        return "\(description.lowercased())."
    }

}

struct RulesView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Rule?
    @State private var creating = false
    @State private var testAlertMessage: String?
    @State private var pushFilter: AlertType?
    @State private var expandedDisplayType: AlertType? = .temperatur
    @State private var showingLocalTemperatureSettings = false
    @State private var showingPushRules = false

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
                    Section {
                        DisclosureGroup(isExpanded: $showingLocalTemperatureSettings) {
                            if let hour = currentLocalTemperatureHour {
                                HStack(spacing: 8) {
                                    temperatureReading(
                                        label: "Fra Yr",
                                        value: hour.yrTemperature ?? hour.temp,
                                        color: .secondary
                                    )
                                    Image(systemName: "arrow.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                    temperatureReading(
                                        label: "Lokalt \(p.nameWithPreposition)",
                                        value: hour.temp,
                                        color: AlertType.temperatur.color
                                    )
                                }
                            } else {
                                Label("Ingen aktuell Yr-temperatur", systemImage: "cloud.sun")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Stepper(value: Binding(
                                get: { p.localTemperatureOffset },
                                set: { p.temperatureOffset = $0; store.update(p); Task { await store.replan() } }
                            ), in: -10...10, step: 0.5) {
                                HStack {
                                    Text("Lokal justering")
                                    Spacer(minLength: 6)
                                    Text(signedTemperatureOffset(p.localTemperatureOffset))
                                        .font(.subheadline.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(p.localTemperatureOffset == 0 ? Color.secondary : AlertType.temperatur.color)
                                }
                            }
                            Text("Minus gjør appens temperatur lavere enn Yr, pluss gjør den høyere. Justeringen gjelder bare dette stedet og påvirker også frost- og temperaturmarkeringer.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            NavigationLink {
                                LocalCalibrationView(placeID: p.id)
                            } label: {
                                Label("Registrer temperatur eller frost", systemImage: "thermometer.sun")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Lokal temperatur", systemImage: "thermometer.medium")
                                    .font(.body.weight(.semibold))
                                HStack(spacing: 5) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(AlertType.temperatur.color)
                                        .frame(width: 10, height: 7)
                                    Text(localTemperatureSummary(for: p))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 28)
                            }
                        }
                    }
                    Section {
                        Text("Velg hvilke rader Hjem skal vise. Trykk på en værtype for å endre markeringene. Pushvarsler styres separat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach([AlertType.regn, .dugg, .sno, .frost, .temperatur, .vind, .sol]) { type in
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedDisplayType == type },
                                set: { expandedDisplayType = $0 ? type : nil }
                            )) {
                                if [.temperatur, .dugg, .sol, .vind].contains(type) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            if type == .sol {
                                                markerSwatch(
                                                    AlertType.sol.color,
                                                    opacity: SolarCellMarkerStyle.solidFillOpacity,
                                                    size: CGSize(width: 14, height: 9)
                                                )
                                            } else if type == .temperatur {
                                                markerSwatch(AlertType.temperatur.color)
                                            } else {
                                                markerSwatch(type.color)
                                            }
                                            Text(type == .temperatur ? "Kaldere enn" : type == .dugg ? "Duggfare" : type == .vind ? "Vindkast fra" : "Helgul celle til")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                            Picker("Grense for \(displayTypeTitle(type))", selection: Binding(
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
                                            .labelsHidden()
                                            .pickerStyle(.menu)
                                        }

                                        if type == .temperatur {
                                            HStack(spacing: 6) {
                                                markerSwatch(.orange)
                                                Text("Varmere enn")
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(.secondary)
                                                Picker("Varmere enn", selection: Binding(
                                                    get: { p.resolvedDisplayTemperatureHighThreshold },
                                                    set: { p.displayTemperatureHighThreshold = $0; store.update(p) }
                                                )) {
                                                    ForEach(Array(stride(from: -10.0, through: 40.0, by: 1.0)), id: \.self) { value in
                                                        Text("\(value.formatted(.number.precision(.fractionLength(0...1))))°").tag(value)
                                                    }
                                                }
                                                .labelsHidden()
                                                .pickerStyle(.menu)
                                            }
                                        }

                                        if type == .sol {
                                            HStack(spacing: 6) {
                                                markerSwatch(
                                                    AlertType.sol.color,
                                                    opacity: SolarCellMarkerStyle.partialFillOpacity,
                                                    hatched: true,
                                                    size: CGSize(width: 14, height: 9)
                                                )
                                                Text("Skravert gul til")
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(.secondary)
                                                Picker("Øvre grense for skravert gul celle", selection: Binding(
                                                    get: { p.resolvedDisplaySunThreshold2 },
                                                    set: { p.displaySunThreshold2 = $0; store.update(p) }
                                                )) {
                                                    ForEach(Array(stride(from: 0.0, through: 90.0, by: 5.0).filter {
                                                        $0 >= p.displayThreshold(for: .sol)
                                                    }), id: \.self) { value in
                                                        Text("\(value.formatted(.number.precision(.fractionLength(0)))) % skydekke").tag(value)
                                                    }
                                                }
                                                .labelsHidden()
                                                .pickerStyle(.menu)
                                            }
                                        }
                                    }
                                    .padding(.leading, 32)
                                } else if type == .frost {
                                    HStack(spacing: 6) {
                                        Image(systemName: AlertType.frost.systemImage)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.blue)
                                        Text("Frostfare over grensen")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                        Picker("Frostfare over grensen", selection: Binding(
                                            get: { p.localFrostMargin },
                                            set: { p.frostMargin = $0; store.update(p); Task { await store.replan() } }
                                        )) {
                                            ForEach(Array(stride(from: 0.0, through: 5.0, by: 0.5)), id: \.self) { value in
                                                Text("+\(value.formatted())°C").tag(value)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                    }
                                    .padding(.leading, 32)
                                } else {
                                    HStack(spacing: 6) {
                                        markerSwatch(type.color)
                                        Text(displayThresholdSummary(for: type, place: p))
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.leading, 32)
                                }

                                Text(displayThresholdExplanation(for: type, place: p))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button {
                                    pushFilter = type
                                    showingPushRules = true
                                } label: {
                                    Label("Pushvarsler · \(p.rules.filter { $0.type == type }.count)", systemImage: "bell.badge")
                                        .font(.caption)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: type.systemImage)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(type.color)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayTypeTitle(type))
                                            .font(.subheadline.weight(.semibold))
                                        displayThresholdSummaryView(for: type, place: p)
                                    }
                                    Spacer(minLength: 2)
                                    Toggle("Vis \(displayTypeTitle(type))", isOn: Binding(
                                        get: { p.isAlertTypeVisible(type) },
                                        set: { visible in
                                            var hidden = p.hiddenAlertTypes ?? []
                                            if visible { hidden.remove(type) } else { hidden.insert(type) }
                                            p.hiddenAlertTypes = hidden
                                            store.update(p)
                                        }
                                    ))
                                    .labelsHidden()
                                    .fixedSize()
                                    .accessibilityLabel(HomeRowVisibilityAccessibilityCopy.label(
                                        for: type, languageStyle: store.alertLanguageStyle
                                    ))
                                }
                            }
                            .padding(.vertical, 3)
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
                        Text("Dette er visningsgrenser for radene på Hjem. De bestemmer når celler får markering, men slår ikke pushvarsler av eller på. Push-reglene redigeres under hver type.")
                    }
                    Section {
                        DisclosureGroup(isExpanded: $showingPushRules) {
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
                        } label: {
                            HStack {
                                Label("Pushvarsler", systemImage: "bell.badge")
                                Spacer()
                                Text("\(visibleRules.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Varsler for \(p.displayName)")
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

    private var currentLocalTemperatureHour: ForecastHour? {
        let now = Date()
        return store.selectedForecast.last(where: {
            $0.time <= now && $0.time > now.addingTimeInterval(-3_600)
        })
    }

    private func localTemperatureSummary(for place: Place) -> String {
        let offset = signedTemperatureOffset(place.localTemperatureOffset)
        guard let hour = currentLocalTemperatureHour else {
            return "Yr-temperaturen justeres her · \(offset)"
        }
        let yr = (hour.yrTemperature ?? hour.temp).formatted(.number.precision(.fractionLength(1)))
        let local = hour.temp.formatted(.number.precision(.fractionLength(1)))
        return "Yr \(yr)° → her \(local)° · \(offset)"
    }

    private func signedTemperatureOffset(_ value: Double) -> String {
        let number = value.formatted(.number.precision(.fractionLength(1)))
        return "\(value > 0 ? "+" : "")\(number)°C"
    }

    private func temperatureReading(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value.formatted(.number.precision(.fractionLength(1))))°")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func displayThresholdExplanation(for type: AlertType, place: Place) -> String {
        let number: (Double) -> String = {
            $0.formatted(.number.precision(.fractionLength(0...1)))
        }
        switch type {
        case .regn:
            return "Fargen viser nedbør i værbåndet. Push-regler og varselgrenser redigeres under."
        case .sno:
            return "Fargen viser snø i værbåndet; mengden er nedbør som Yr oppgir som snø. Pushregler redigeres under."
        case .dugg:
            return "Markeres når lufttemperaturen er høyst \(number(place.displayThreshold(for: .dugg)))°C fra duggpunktet. Yr-verdien endres ikke."
        case .frost:
            let threshold = place.rulesForDisplay.first(where: { $0.type == .frost })?.threshold ?? AlertType.frost.defaultThreshold
            return place.localFrostMargin == 0
                ? "Frost markeres ved \(number(threshold))°C eller kaldere."
                : "Frost markeres ved \(number(threshold))°C eller kaldere. Mulig frostfare regnes også opptil \(number(threshold + place.localFrostMargin))°C. Dette endrer ikke Yr-temperaturen."
        case .temperatur:
            return "Blå markering ved temperaturer under \(number(place.resolvedDisplayTemperatureThreshold))°C. Oransje markering ved temperaturer over \(number(place.resolvedDisplayTemperatureHighThreshold))°C. Dette endrer ikke pushvarslene."
        case .vind:
            let threshold = place.displayThreshold(for: .vind)
            return "Markeres ved vindkast fra \(number(threshold)) m/s (\(windStrengthLabel(for: threshold))). Middelvind brukes ikke."
        case .sol:
            return "Gule markeringer vises bare i dagslys. Disse grensene endrer ikke pushvarslene."
        }
    }

    private func displayThresholdSummary(for type: AlertType, place: Place) -> String {
        let number: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0...1))) }
        switch type {
        case .regn:
            let threshold = place.rulesForDisplay.first(where: { $0.type == .regn })?.threshold ?? AlertType.regn.defaultThreshold
            return "Nedbør fra \(number(threshold)) mm/t"
        case .sno:
            let threshold = place.rulesForDisplay.first(where: { $0.type == .sno })?.threshold ?? AlertType.sno.defaultThreshold
            return "Snø fra \(number(threshold)) mm vann/t"
        case .dugg:
            return "Duggfare ved avvik på \(number(place.displayThreshold(for: .dugg)))°C"
        case .frost:
            let threshold = place.rulesForDisplay.first(where: { $0.type == .frost })?.threshold ?? AlertType.frost.defaultThreshold
            let frostRiskLimit = threshold + place.localFrostMargin
            return "Frost ved \(number(threshold))°C · frostfare opptil \(number(frostRiskLimit))°C"
        case .temperatur:
            return "Blå under \(number(place.resolvedDisplayTemperatureThreshold))° · oransje over \(number(place.resolvedDisplayTemperatureHighThreshold))°"
        case .vind:
            return "Vindkast fra \(number(place.displayThreshold(for: .vind))) m/s"
        case .sol:
            return "Helgul: 0–\(number(place.displayThreshold(for: .sol)))% · skravert: >\(number(place.displayThreshold(for: .sol)))–\(number(place.resolvedDisplaySunThreshold2))%"
        }
    }

    @ViewBuilder
    private func displayThresholdSummaryView(for type: AlertType, place: Place) -> some View {
        HStack(spacing: 4) {
            switch type {
            case .temperatur:
                markerSwatch(AlertType.temperatur.color)
                Text("under \(place.resolvedDisplayTemperatureThreshold.formatted(.number.precision(.fractionLength(0...1))))°")
                markerSwatch(.orange)
                    .padding(.leading, 3)
                Text("over \(place.resolvedDisplayTemperatureHighThreshold.formatted(.number.precision(.fractionLength(0...1))))°")
            case .sol:
                markerSwatch(AlertType.sol.color, opacity: SolarCellMarkerStyle.solidFillOpacity)
                Text("0–\(place.displayThreshold(for: .sol).formatted(.number.precision(.fractionLength(0...1))))%")
                markerSwatch(
                    AlertType.sol.color,
                    opacity: SolarCellMarkerStyle.partialFillOpacity,
                    hatched: true
                )
                    .padding(.leading, 3)
                Text(">\(place.displayThreshold(for: .sol).formatted(.number.precision(.fractionLength(0...1))))–\(place.resolvedDisplaySunThreshold2.formatted(.number.precision(.fractionLength(0...1))))%")
            case .frost:
                Image(systemName: AlertType.frost.systemImage)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(displayThresholdSummary(for: type, place: place))
            default:
                markerSwatch(type.color)
                Text(displayThresholdSummary(for: type, place: place))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }

    private func displayTypeTitle(_ type: AlertType) -> String {
        type == .sol ? "Sollys / skydekke" : type.label
    }

    private func markerSwatch(
        _ color: Color,
        opacity: Double = 0.78,
        hatched: Bool = false,
        size: CGSize = CGSize(width: 12, height: 8)
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(opacity))
            if hatched {
                GeometryReader { proxy in
                    Path { path in
                        var x = -proxy.size.height
                        while x < proxy.size.width {
                            path.move(to: CGPoint(x: x, y: proxy.size.height))
                            path.addLine(to: CGPoint(x: x + proxy.size.height, y: 0))
                            x += SolarCellMarkerStyle.hatchSpacing
                        }
                    }
                    .stroke(
                        SolarCellMarkerStyle.hatchColor.opacity(SolarCellMarkerStyle.hatchOpacity),
                        lineWidth: SolarCellMarkerStyle.hatchLineWidth
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ContextHelpButton(topic: .alerts)
                }
            }
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
            frostMargin: item.place.localFrostMargin,
            latitude: item.place.lat,
            longitude: item.place.lon
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
    @EnvironmentObject var store: Store
    @StateObject private var loc = LocationManager()
    @State private var busy = false
    @State private var showingSearch = false
    @State private var locationError: String?
    @State private var showingExporter = false
    @State private var exportFailureMessage: String?
    @State private var editingPlaces = false
    @State private var placeExpansion = PlaceExpansionState()
    @AppStorage(PlaceOrderingSettings.homePlaceIDKey) private var homePlaceID = ""
    @AppStorage(PlaceOrderingSettings.cabinPlaceIDKey) private var cabinPlaceID = ""
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
                    Picker("Hytta", selection: $cabinPlaceID) {
                        Text("Ikke valgt").tag("")
                        ForEach(store.places) { place in
                            Text(place.displayName).tag(place.id.uuidString)
                        }
                    }
                    .accessibilityHint("Velg hvilket sted som skal ha en egen snarvei i hovedmenyen")
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
                                    let visibleForecast = ForecastDaySelection.hoursForVisibleDays(from: forecast)
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
                                        .accessibilityElement(children: .combine)
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityValue(
                                            PlaceForecastExpansionAccessibilityCopy.value(
                                                isExpanded: placeExpansion.expandedPlaceID == place.id,
                                                languageStyle: store.alertLanguageStyle
                                            )
                                        )
                                        .accessibilityHint(
                                            PlaceForecastExpansionAccessibilityCopy.hint(
                                                isExpanded: placeExpansion.expandedPlaceID == place.id,
                                                languageStyle: store.alertLanguageStyle
                                            )
                                        )
                                        .accessibilityAction(.default) {
                                            toggleExpansion(for: place.id)
                                        }
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
                                            toggleExpansion(for: place.id)
                                        }

                                        if placeExpansion.expandedPlaceID == place.id {
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
                    ContextHelpButton(topic: .places)
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
            ) { result in
                if case let .failure(error) = result {
                    exportFailureMessage = ConfigurationExportFailure.message(
                        for: error,
                        languageStyle: store.alertLanguageStyle
                    )
                } else {
                    exportFailureMessage = nil
                }
            }
            .alert(
                store.alertLanguageStyle == .english
                    ? "Could not export setup"
                    : WeatherLanguage.text("Kunne ikke eksportere oppsettet", style: store.alertLanguageStyle),
                isPresented: Binding(
                    get: { exportFailureMessage != nil },
                    set: { if !$0 { exportFailureMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { exportFailureMessage = nil }
            } message: {
                Text(exportFailureMessage ?? "")
            }
            .onChange(of: store.places.map(\.id)) { _, placeIDs in
                placeExpansion.reconcile(availablePlaceIDs: Set(placeIDs))
            }
        }
    }

    private func toggleExpansion(for placeID: UUID) {
        withAnimation(.easeInOut(duration: 0.22)) {
            placeExpansion.toggle(placeID)
        }
    }

    @ViewBuilder
    private func expandedForecast(for place: Place, forecast: [ForecastHour]) -> some View {
        ForecastVariantsView(
            forecast: forecast,
            rules: place.rulesForDisplay,
            languageStyle: store.alertLanguageStyle,
            frostMargin: place.localFrostMargin,
            mode: .weatherBands,
            sunThreshold: place.displayThreshold(for: .sol),
            sunThreshold2: place.resolvedDisplaySunThreshold2,
            temperatureLowThreshold: place.resolvedDisplayTemperatureThreshold,
            temperatureHighThreshold: place.resolvedDisplayTemperatureHighThreshold,
            displayDewThreshold: place.displayThreshold(for: .dugg),
            displayGustThreshold: place.displayThreshold(for: .vind),
            latitude: place.lat,
            longitude: place.lon,
            todayTitle: "Resten av i dag",
            updatedAt: store.forecastUpdatedAt(for: place.id),
            isRefreshing: store.isRefreshing,
            isStale: Store.isForecastStale(store.forecastUpdatedAt(for: place.id))
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
        if let cabinID = UUID(uuidString: cabinPlaceID), removedIDs.contains(cabinID) {
            cabinPlaceID = ""
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
                ToolbarItem(placement: .topBarTrailing) {
                    ContextHelpButton(topic: .settings)
                }
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
                            .accessibilityLabel(PlaceRoleAccessibilityCopy.label(
                                for: .home,
                                languageStyle: store.alertLanguageStyle
                            ))
                    }
                }
                Spacer()
                if let current = store.forecasts[place.id]?.first {
                    Image(systemName: current.cloud <= 20 ? "sun.max.fill" : (current.precipitationRiskRate >= 0.1 ? "cloud.rain.fill" : "cloud.fill"))
                        .foregroundStyle(current.cloud <= 20 ? .orange : .blue)
                    Text("\(Int(current.temp.rounded()))°").font(.title3.weight(.medium))
                }
                if place.id == store.selectedID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .accessibilityLabel(PlaceRoleAccessibilityCopy.label(
                            for: .selected,
                            languageStyle: store.alertLanguageStyle
                        ))
                }
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
                    .accessibilityLabel(FavoriteSlotAccessibilityCopy.label(
                        for: 1,
                        languageStyle: store.alertLanguageStyle
                    ))
                    .tint(isFavorite1 ? .orange : nil)
                    Button {
                        toggleFavorite(slot: 2)
                    } label: {
                        if compact { Image(systemName: isFavorite2 ? "star.fill" : "star") }
                        else { Label("Stjerne 2", systemImage: isFavorite2 ? "star.fill" : "star") }
                    }
                    .accessibilityLabel(FavoriteSlotAccessibilityCopy.label(
                        for: 2,
                        languageStyle: store.alertLanguageStyle
                    ))
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

enum LocalCalibrationCopy {
    static func text(_ bokmal: String, english: String, style: AlertLanguageStyle) -> String {
        style == .english ? english : WeatherLanguage.text(bokmal, style: style)
    }

    static func surface(_ bokmal: String, style: AlertLanguageStyle) -> String {
        guard style == .english else { return WeatherLanguage.text(bokmal, style: style) }
        switch bokmal {
        case "Gress": "grass"
        case "Bil/tak": "car/roof"
        case "Gress og bil/tak": "grass and car/roof"
        case "Annet": "other"
        default: bokmal
        }
    }
}

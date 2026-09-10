import SwiftUI

struct RuleEditorView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    let isNew: Bool
    var onSaved: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Huskelapp") {
                    TextField("Skriv en huskelapp", text: $rule.customName)
                    let suggestion = rule.memoSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !suggestion.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Forslag fra malen")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(suggestion)
                                    .font(.subheadline)
                            }
                            Spacer()
                            Button("Bruk forslaget") { rule.customName = suggestion }
                                .font(.caption.weight(.semibold))
                        }
                    }
                    Text("Valgfritt. Huskelappen vises bare som siste linje i pushvarselet når du har skrevet eller valgt den.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Varsle meg om") {
                    Picker("Type", selection: $rule.type) {
                        ForEach(AlertType.allCases) { t in Text(t.label).tag(t) }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: rule.type) { _, type in
                        rule.templateTitle = "\(type.label)varsel"
                        rule.threshold = type.defaultThreshold
                        rule.activeFromHour = type == .sol ? 7 : 0
                        rule.activeToHour = type == .sol ? 22 : 0
                    }

                    if rule.type == .vind {
                        Picker("Nivå", selection: windLevel) {
                            ForEach(WindGustLevel.allCases) { level in
                                Text("\(level.label) · \(level.rawValue) m/s").tag(level)
                            }
                        }
                        Text("Valgt nivå utløses av varslede vindkast, ikke middelvind. Orkan er derfor ikke brukt som nivånavn.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(rule.type.needsDuration ? "Maks skydekke" : (rule.type == .temperatur ? "Under" : "Terskel"))
                                Spacer()
                                Text("\(rule.threshold.formatted(.number.precision(.fractionLength(0...1)))) \(rule.type.unit)").bold()
                            }
                            Slider(value: $rule.threshold, in: rule.type.range, step: rule.type.step)
                        }
                    }
                    if rule.type.needsDuration {
                        Stepper("Sammenhengende \(rule.durationHours) timer", value: $rule.durationHours, in: 1...12)
                    }
                    if rule.type == .dugg {
                        Text("Varsler når lufttemperaturen nærmer seg duggpunktet – dvs. når dugg eller kondens ventes.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if rule.type == .temperatur {
                        Text("Varsler når temperaturen ventes å bli lavere enn valgt verdi.").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Varselområde") {
                    Picker("Fra kl.", selection: $rule.activeFromHour) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    Picker("Til kl.", selection: $rule.activeToHour) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    Text(rule.activeFromHour == rule.activeToHour
                         ? "Regelen gjelder hele døgnet."
                         : "Været vurderes bare \(rule.activeHoursLabel). Tidsrommet kan også gå over midnatt.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Hvor gjelder varselet?") {
                    Toggle("Bare når jeg er i nærheten", isOn: $rule.onlyWhenNearby)
                        .onChange(of: rule.onlyWhenNearby) { _, enabled in
                            if enabled { store.requestNearbyAuthorization() }
                        }
                    Text(rule.onlyWhenNearby
                         ? "Varsler bare når du er innen 5 km fra stedet. Tillat posisjon «Alltid» for at dette skal aktiveres automatisk når du kommer fram."
                         : "Varsler uansett hvor du befinner deg.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if rule.previousDayNotificationHour != nil {
                    Section("Når skal varselet komme?") {
                        HStack {
                            Spacer()
                            Image(systemName: "clock.fill")
                                .font(.title2)
                                .foregroundStyle(.blue)
                            Text("Fast varslingstid")
                                .font(.headline)
                            Spacer()
                        }
                        DatePicker("Varslingstid", selection: notificationTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        Picker("Varslingsdag", selection: fixedDaySelection) {
                            Text("Dagen før").tag("previous")
                            Text("Samme dag").tag("same")
                            ForEach(fullDayNames.indices, id: \.self) { day in
                                Text(fullDayNames[day].capitalized).tag("weekday-\(day)")
                            }
                        }
                        Text(rule.activeFromHour > rule.activeToHour
                             ? fixedScheduleHelp(nightRule: true)
                             : fixedScheduleHelp(nightRule: false))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Bruk vanlig forvarsel i stedet") {
                            rule.previousDayNotificationHour = nil
                            rule.notificationWeekday = nil
                            rule.notificationDayOffset = nil
                        }
                    }
                } else {
                    Section("Forvarsel") {
                        Picker("Forvarsel", selection: $rule.leadMinutes) {
                            ForEach(leadOptions, id: \.self) { Text(minutesLabel($0)).tag($0) }
                        }
                        Toggle("Ekstra påminnelser", isOn: $rule.repeatsEnabled)
                            .onChange(of: rule.repeatsEnabled) { _, enabled in
                                if enabled { rule.count = max(2, rule.count) }
                            }
                        if rule.repeatsEnabled {
                            Stepper("Antall varsler: \(rule.alertCount)", value: $rule.count, in: 2...10)
                            Picker("Mellomrom", selection: $rule.intervalMinutes) {
                                ForEach(intervalOptions, id: \.self) { Text(minutesLabel($0)).tag($0) }
                            }
                            Text("Alle gjelder samme værhendelse og stopper når den begynner.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Ett varsel per sammenhengende værhendelse.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Varsle på fast tidspunkt") {
                            rule.previousDayNotificationHour = 21
                            rule.previousDayNotificationMinute = 0
                            rule.notificationWeekday = nil
                            rule.notificationDayOffset = nil
                            rule.repeatsEnabled = false
                        }
                    }
                }

                Section("Stille tid") {
                    Toggle("Stille tid", isOn: $rule.quiet)
                    if rule.quiet {
                        Stepper("Fra kl. \(rule.quietFrom)", value: $rule.quietFrom, in: 18...23)
                        Stepper("Til kl. \(rule.quietTo)", value: $rule.quietTo, in: 5...10)
                        Text("Varsler i stille tid leveres uten lyd.").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Dager") {
                    HStack {
                        ForEach(0..<7, id: \.self) { d in
                            let on = rule.days.contains(d)
                            Text(dayNames[d])
                                .font(.footnote.bold())
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(on ? Color(red: 0.09, green: 0.14, blue: 0.23) : Color(white: 0.92))
                                .foregroundStyle(on ? .white : .primary)
                                .clipShape(Capsule())
                                .onTapGesture { if on { rule.days.remove(d) } else { rule.days.insert(d) } }
                        }
                    }
                    if rule.days.isEmpty {
                        Text("Velg minst én dag.").font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("Forhåndsvisning") {
                    let fc = store.selectedForecast
                    let plan = Planner.plan(
                        rule: rule,
                        forecast: fc,
                        placeName: store.selected?.displayName ?? "",
                        frostMargin: store.selected?.localFrostMargin ?? 0
                    )
                    if let e = plan.eventAt {
                        Text("Neste hendelse \(eventTimePhrase(e)). " + (plan.alerts.isEmpty ? "Ingen varsler rekker å gå ut." : "Varsel " + plan.alerts.map { eventTimePhrase($0.fireAt) }.joined(separator: ", ") + "."))
                            .font(.footnote)
                    } else {
                        Text(fc.isEmpty ? "Ingen prognose hentet ennå." : "Regelen slår ikke til i prognosen akkurat nå.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !fc.isEmpty {
                        TimelineView(
                            forecast: fc,
                            rules: [rule],
                            placeName: "",
                            frostMargin: store.selected?.localFrostMargin ?? 0,
                            height: 40
                        )
                    }
                }

                if !isNew {
                    Section {
                        Button("Slett regel", role: .destructive) {
                            if var p = store.selected { p.rules.removeAll { $0.id == rule.id }; store.update(p) }
                            Task { await store.replan() }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Ny regel" : "Rediger regel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Avbryt") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lagre") {
                        if var p = store.selected {
                            if let i = p.rules.firstIndex(where: { $0.id == rule.id }) { p.rules[i] = rule } else { p.rules.append(rule) }
                            store.update(p)
                        }
                        Task { await store.replan() }
                        onSaved?()
                        dismiss()
                    }
                    .disabled(rule.days.isEmpty)
                }
            }
        }
    }

    private var notificationTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: rule.previousDayNotificationHour ?? 21,
                    minute: rule.previousDayNotificationMinute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                rule.previousDayNotificationHour = Calendar.current.component(.hour, from: date)
                rule.previousDayNotificationMinute = Calendar.current.component(.minute, from: date)
            }
        )
    }

    private var windLevel: Binding<WindGustLevel> {
        Binding(
            get: { rule.windGustLevel },
            set: { level in rule.threshold = level.threshold }
        )
    }

    private var fixedDaySelection: Binding<String> {
        Binding(
            get: {
                if let weekday = rule.notificationWeekday { return "weekday-\(weekday)" }
                return rule.notificationDayOffset == 0 ? "same" : "previous"
            },
            set: { value in
                if value == "same" {
                    rule.notificationWeekday = nil
                    rule.notificationDayOffset = 0
                } else if value.hasPrefix("weekday-"), let weekday = Int(value.dropFirst("weekday-".count)) {
                    rule.notificationWeekday = weekday
                    rule.notificationDayOffset = nil
                } else {
                    rule.notificationWeekday = nil
                    rule.notificationDayOffset = nil
                }
            }
        )
    }

    private func fixedScheduleHelp(nightRule: Bool) -> String {
        let clock = "kl. \(hourLabel(rule.previousDayNotificationHour ?? 21)).\(String(format: "%02d", rule.previousDayNotificationMinute))"
        if let weekday = rule.notificationWeekday, fullDayNames.indices.contains(weekday) {
            return "Hvis regelen slår til, sendes varselet \(fullDayNames[weekday]) \(clock). Flere treff samles i samme ukesvarsel."
        }
        if rule.notificationDayOffset == 0 {
            return "Hvis regelen slår til, sendes varselet \(clock) samme dag."
        }
        return nightRule
            ? "Hvis regelen slår til i nattperioden, sendes varselet \(clock) samme kveld."
            : "Hvis regelen slår til neste dag, sendes varselet \(clock) kvelden før."
    }
}

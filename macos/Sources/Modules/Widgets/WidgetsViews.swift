import IsolaCore
import SwiftUI

// MARK: - Scheda

/// Tre colonne: fusi orari e concentrazione · meteo e Day · da fare.
struct WidgetsCard: View {
    @ObservedObject var vm: WidgetsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 8) {
                ClocksTile(vm: vm)
                FocusTile(vm: vm)
            }
            .frame(width: 176)
            VStack(spacing: 8) {
                WeatherTile(vm: vm)
                DayTile(vm: vm)
            }
            .frame(width: 150)
            TodoTile(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: IslandMetrics.card.width - 12, height: IslandMetrics.card.height - 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Una casella con il fondo dell'isola.
private struct Tile<Content: View>: View {
    var padding: CGFloat = 9
    @ViewBuilder var content: Content
    @Environment(\.island) private var theme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface))
    }
}

private struct TileTitle: View {
    let text: String
    @Environment(\.island) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(theme.muted)
    }
}

private struct ClocksTile: View {
    @ObservedObject var vm: WidgetsViewModel
    @Environment(\.island) private var theme

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 3) {
                TileTitle(text: "Fusi orari")
                if vm.clocks.isEmpty {
                    Text("Scegli i fusi nelle impostazioni.")
                        .font(IslandFont.small)
                        .foregroundStyle(theme.muted)
                } else {
                    ForEach(vm.clocks) { row in
                        HStack(spacing: 4) {
                            Text(row.city)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.foreground)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            if !row.dayHint.isEmpty {
                                Text(row.dayHint)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(theme.muted)
                            }
                            Text(row.time)
                                .font(IslandFont.mono(12))
                                .foregroundStyle(theme.foreground)
                        }
                        .frame(height: 15)
                    }
                }
            }
        }
        .frame(height: 98)
    }
}

private struct FocusTile: View {
    @ObservedObject var vm: WidgetsViewModel
    @Environment(\.island) private var theme

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 4) {
                TileTitle(text: vm.focusPhase)
                HStack(alignment: .center, spacing: 6) {
                    Group {
                        if vm.focusRunning {
                            Text(timerInterval: vm.focusInterval, countsDown: true)
                        } else {
                            Text(WidgetsViewModel.clockText(vm.focusRemaining))
                        }
                    }
                    .font(IslandFont.mono(20, weight: .semibold))
                    .foregroundStyle(vm.focusBreak ? IslandTheme.green : theme.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    IslandIconButton(vm.focusRunning ? "pause.fill" : "play.fill", size: 12,
                                     help: vm.focusRunning ? "Pausa" : "Avvia") { vm.module?.focusToggle() }
                    IslandIconButton("arrow.counterclockwise", size: 11, help: "Azzera") { vm.module?.focusReset() }
                }
                Group {
                    if vm.focusRunning {
                        ProgressView(timerInterval: vm.focusInterval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    } else {
                        ProgressView(value: max(0, min(1, 1 - vm.focusRemaining / max(1, vm.focusTotal))))
                    }
                }
                .progressViewStyle(.linear)
                .tint(vm.focusBreak ? IslandTheme.green : theme.accent)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
    }
}

private struct WeatherTile: View {
    @ObservedObject var vm: WidgetsViewModel
    @Environment(\.island) private var theme
    @FocusState private var cityFocused: Bool

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    TileTitle(text: vm.weatherCity.isEmpty ? "Meteo" : vm.weatherCity)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if vm.weatherBusy {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                    }
                    if !vm.editingCity {
                        Button {
                            vm.cityDraft = ""
                            vm.editingCity = true
                        } label: {
                            Image(systemName: "pencil").font(.system(size: 9.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.muted)
                        .help("Cambia città")
                    }
                }
                if vm.editingCity {
                    cityField
                } else if let w = vm.weather {
                    HStack(spacing: 6) {
                        Image(systemName: WeatherCodes.symbol(w.kind, isDay: w.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 22))
                        Text(w.temperatureText)
                            .font(.system(size: 24, weight: .light).monospacedDigit())
                            .foregroundStyle(theme.foreground)
                    }
                    Text(w.label)
                        .font(IslandFont.small)
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                    if let hi = w.max, let lo = w.min {
                        Text("Max \(Int(hi.rounded()))° · Min \(Int(lo.rounded()))°")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(theme.muted)
                    }
                } else {
                    Spacer(minLength: 0)
                    Text(vm.weatherStatus.isEmpty ? "Scegli una città" : vm.weatherStatus)
                        .font(IslandFont.small)
                        .foregroundStyle(theme.muted)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 98)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !vm.editingCity else { return }
            if vm.hasCity { vm.module?.weatherTapped() } else { vm.cityDraft = ""; vm.editingCity = true }
        }
        .help(vm.hasCity ? "Tocca per aggiornare" : "Tocca per scegliere la città")
    }

    private var cityField: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField("", text: $vm.cityDraft, prompt: Text("Città").foregroundStyle(theme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.foreground)
                .focused($cityFocused)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.surfaceHover))
                .simultaneousGesture(TapGesture().onEnded { vm.module?.requestKeyboardFocus(); cityFocused = true })
                .onSubmit { vm.module?.setCityName(vm.cityDraft) }
                .onExitCommand { vm.editingCity = false }
            HStack(spacing: 4) {
                Button("Annulla") { vm.editingCity = false }
                    .buttonStyle(IslandButtonStyle())
                Button("Ok") { vm.module?.setCityName(vm.cityDraft) }
                    .buttonStyle(IslandButtonStyle(prominent: true))
                    .disabled(vm.cityDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.system(size: 11))
        }
        .onAppear {
            vm.module?.requestKeyboardFocus()
            cityFocused = true
        }
    }
}

private struct DayTile: View {
    @ObservedObject var vm: WidgetsViewModel
    @Environment(\.island) private var theme

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    TileTitle(text: "Oggi")
                    Spacer(minLength: 0)
                    Button {
                        vm.module?.updateSettings { $0.day.pinned.toggle() }
                    } label: {
                        Image(systemName: vm.settings.day.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 10))
                            .foregroundStyle(vm.settings.day.pinned ? theme.accent : theme.muted)
                    }
                    .buttonStyle(.plain)
                    .help(vm.settings.day.pinned ? "Togli dal desktop" : "Mostra sul desktop")
                }
                Text(vm.weekday)
                    .font(.system(size: 16, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(vm.dateLine)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
        }
    }
}

private struct TodoTile: View {
    @ObservedObject var vm: WidgetsViewModel
    @Environment(\.island) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        Tile(padding: 8) {
            VStack(alignment: .leading, spacing: 5) {
                TileTitle(text: "Da fare").padding(.leading, 1)
                TextField("", text: $vm.todoDraft, prompt: Text("Aggiungi…").foregroundStyle(theme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.foreground)
                    .focused($focused)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.surfaceHover))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(focused ? theme.accent.opacity(0.7) : .clear, lineWidth: 1))
                    .simultaneousGesture(TapGesture().onEnded { vm.module?.requestKeyboardFocus(); focused = true })
                    .onChange(of: focused) { _, f in if f { vm.module?.requestKeyboardFocus() } }
                    .onSubmit {
                        if vm.module?.todoAdd(vm.todoDraft) == true { vm.todoDraft = "" }
                        focused = true
                    }
                if vm.todos.isEmpty {
                    Text("Niente da fare.")
                        .font(IslandFont.small)
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(vm.todos) { item in
                                TodoRow(item: item,
                                        onToggle: { vm.module?.todoToggle(item.id) },
                                        onDelete: { vm.module?.todoDelete(item.id) })
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let onToggle: () -> Void
    let onDelete: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? theme.accent : theme.muted)
            }
            .buttonStyle(.plain)
            .help(item.done ? "Da rifare" : "Fatto")
            Text(item.text)
                .font(.system(size: 12.5))
                .strikethrough(item.done)
                .foregroundStyle(item.done ? theme.muted : theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            IslandIconButton("xmark", size: 9, help: "Elimina", action: onDelete)
                .opacity(hover ? 1 : 0)
        }
        .padding(.leading, 3)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? theme.surfaceHover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Pillola e peek

struct WidgetsFaceLeading: View {
    @ObservedObject var vm: WidgetsViewModel
    @Environment(\.island) private var theme

    var body: some View {
        Group {
            if vm.faceMode == .focus {
                Image(systemName: vm.focusBreak ? "cup.and.saucer.fill" : "timer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(vm.focusBreak ? IslandTheme.green : theme.accent)
            } else if let w = vm.weather {
                Image(systemName: WeatherCodes.symbol(w.kind, isDay: w.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
    }
}

struct WidgetsFaceTrailing: View {
    @ObservedObject var vm: WidgetsViewModel
    @Environment(\.island) private var theme

    var body: some View {
        Group {
            if vm.faceMode == .focus {
                if vm.focusRunning {
                    Text(timerInterval: vm.focusInterval, countsDown: true)
                } else {
                    Text(vm.alertActive ? "Fine" : WidgetsViewModel.clockText(vm.focusRemaining))
                }
            } else if let w = vm.weather {
                Text(w.temperatureText)
            }
        }
        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(theme.foreground)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 10)
    }
}

struct WidgetsPeek: View {
    @ObservedObject var vm: WidgetsViewModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: vm.focusBreak ? "cup.and.saucer.fill" : "timer")
                .font(.system(size: 15))
                .foregroundStyle(vm.focusBreak ? IslandTheme.green : theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.alertTitle)
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text(vm.alertText)
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if vm.focusRunning {
                Text(timerInterval: vm.focusInterval, countsDown: true)
                    .font(IslandFont.mono(12))
                    .foregroundStyle(theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: IslandMetrics.peek.width, height: IslandMetrics.peek.height)
    }
}

// MARK: - Impostazioni

struct WidgetsSettingsView: View {
    @ObservedObject var vm: WidgetsViewModel
    @State private var query = ""
    @State private var results: [GeoPlace] = []
    @State private var searching = false
    @State private var message: String?
    @State private var size: Double = 120

    private var s: WidgetsSettings { vm.settings }

    var body: some View {
        Form {
            weatherSection
            zonesSection
            daySection
        }
        .onAppear { size = s.day.size }
    }

    // Meteo

    private var weatherSection: some View {
        Section {
            LabeledContent("Città") {
                if s.hasPlace || !s.city.isEmpty {
                    HStack {
                        Text(s.cityLabel ?? s.city).foregroundStyle(.secondary)
                        Button("Rimuovi") { vm.module?.clearPlace(); results = [] }
                    }
                } else {
                    Text("Nessuna").foregroundStyle(.secondary)
                }
            }
            HStack {
                TextField("Cerca una città", text: $query)
                    .onSubmit(search)
                Button("Cerca", action: search)
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if searching {
                ProgressView().controlSize(.small)
            }
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
            ForEach(results) { place in
                Button {
                    vm.module?.setPlace(place)
                    results = []
                    query = ""
                    message = nil
                } label: {
                    HStack {
                        Text(place.label)
                        Spacer()
                        Image(systemName: "plus.circle")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Picker("Nella pillola, a riposo", selection: Binding(
                get: { s.restingFace },
                set: { v in vm.module?.updateSettings { $0.restingFace = v } })) {
                Text("Orologio").tag(WidgetsFace.clock)
                Text("Meteo").tag(WidgetsFace.weather)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Meteo")
        } footer: {
            Text("I dati arrivano da Open-Meteo, senza account. Escono dal Mac solo il nome della città che cerchi e le sue coordinate. Con «Meteo» la pillola mostra temperatura e icona e si aggiorna ogni 30 minuti; altrimenti il meteo si aggiorna solo quando apri la scheda.")
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !searching, let module = vm.module else { return }
        searching = true
        message = nil
        Task {
            let r = await module.searchPlaces(q)
            searching = false
            switch r {
            case .success(let places):
                results = places
                message = places.isEmpty ? "Nessuna città trovata." : nil
            case .failure:
                results = []
                message = "Ricerca non riuscita. Controlla la connessione."
            }
        }
    }

    // Fusi orari

    private var zonesSection: some View {
        Section {
            ForEach(s.timeZones, id: \.self) { id in
                HStack {
                    Text(Zones.name(id))
                    Spacer()
                    if let tz = TimeZone(identifier: id) {
                        Text(Zones.offsetText(tz)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button {
                        vm.module?.updateSettings { $0.timeZones.removeAll { $0 == id } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Togli")
                }
            }
            Menu("Aggiungi un fuso") {
                ForEach(Zones.known.filter { !s.timeZones.contains($0.id) }, id: \.id) { z in
                    Button(z.name) {
                        vm.module?.updateSettings { if $0.timeZones.count < 4 { $0.timeZones.append(z.id) } }
                    }
                }
            }
            .disabled(s.timeZones.count >= 4)
        } header: {
            Text("Fusi orari")
        } footer: {
            Text("Fino a 4 città nella scheda.")
        }
    }

    // Day sul desktop

    private var daySection: some View {
        Section {
            Toggle("Orologio Day sul desktop", isOn: Binding(
                get: { s.day.pinned },
                set: { v in vm.module?.updateSettings { $0.day.pinned = v } }))
            LabeledContent("Colore") {
                HStack(spacing: 6) {
                    ForEach(HexColor.swatches, id: \.hex) { sw in
                        Button {
                            vm.module?.updateSettings { $0.day.color = sw.hex }
                        } label: {
                            Circle()
                                .fill(HexColor.color(sw.hex) ?? .white)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                                .overlay(Circle().strokeBorder(Color.accentColor,
                                                               lineWidth: s.day.color.uppercased() == sw.hex ? 2 : 0)
                                    .padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help(sw.name)
                    }
                    ColorPicker("", selection: Binding(
                        get: { HexColor.color(s.day.color) ?? .white },
                        set: { c in
                            if let hex = HexColor.hex(c) { vm.module?.updateSettings { $0.day.color = hex } }
                        }), supportsOpacity: false)
                        .labelsHidden()
                }
            }
            LabeledContent("Grandezza") {
                HStack {
                    Slider(value: $size, in: 60...240, step: 10) { editing in
                        if !editing { vm.module?.updateSettings { $0.day.size = size } }
                    }
                    .frame(maxWidth: 220)
                    Text("\(Int(size)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            Picker("In verticale", selection: Binding(
                get: { s.day.vertical },
                set: { v in vm.module?.updateSettings { $0.day.vertical = v } })) {
                Text("In alto").tag(DayVertical.top)
                Text("Al centro").tag(DayVertical.center)
                Text("In basso").tag(DayVertical.bottom)
            }
            Picker("In orizzontale", selection: Binding(
                get: { s.day.horizontal },
                set: { v in vm.module?.updateSettings { $0.day.horizontal = v } })) {
                Text("A sinistra").tag(DayHorizontal.left)
                Text("Al centro").tag(DayHorizontal.center)
                Text("A destra").tag(DayHorizontal.right)
            }
        } header: {
            Text("Sul desktop")
        } footer: {
            Text("Il giorno della settimana grande e la data, dietro le finestre e sopra lo sfondo, sullo schermo principale. Non riceve i clic.")
        }
    }
}

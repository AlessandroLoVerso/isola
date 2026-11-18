import IsolaCore
import SwiftUI

// MARK: - Scheda

/// La scheda "Promemoria": in alto il banner del promemoria scaduto o lo spazio per scriverne uno,
/// sotto la lista dei prossimi.
struct RemindersCard: View {
    @ObservedObject var vm: RemindersViewModel
    @Environment(\.island) private var theme

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                // Il composer resta (invisibile) sotto il banner: l'altezza non salta.
                Composer(vm: vm)
                    .opacity(vm.bannerId == nil ? 1 : 0)
                    .allowsHitTesting(vm.bannerId == nil)
                if vm.bannerId != nil {
                    FiringBanner(vm: vm)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: vm.bannerId)

            if vm.upcoming.isEmpty && vm.bannerId == nil {
                Text("Nessun promemoria. Scrivi qui sopra e scegli quando.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.upcoming) { row in
                            ReminderRowView(row: row, editing: vm.editingId == row.id,
                                            onEdit: { vm.beginEdit(row.id) },
                                            onDelete: { vm.delete(row.id) })
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .frame(width: IslandMetrics.card.width - 16, height: IslandMetrics.card.height - 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Composer: View {
    @ObservedObject var vm: RemindersViewModel
    @Environment(\.island) private var theme
    @FocusState private var focus: Field?

    enum Field { case text, time, date }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                field(.text, text: $vm.text, prompt: vm.editingId == nil ? "Ricordami di…" : "Testo del promemoria",
                      error: vm.textError, height: 30, size: 13) { vm.submitText() }
                if vm.editingId != nil {
                    IslandIconButton("xmark", size: 11, help: "Annulla la modifica") { vm.cancelEdit() }
                }
                Button { vm.cycleRepeat() } label: {
                    Label(vm.repeats.label, systemImage: "repeat")
                        .font(.system(size: 12))
                        .foregroundStyle(vm.repeats == .none ? theme.foreground : theme.accent)
                }
                .buttonStyle(IslandButtonStyle())
                .help("Ripeti")
                .fixedSize()
            }
            HStack(spacing: 6) {
                chip("+10 min") { vm.quick(.tenMinutes) }
                chip("+1 h") { vm.quick(.oneHour) }
                if vm.showTonight { chip("Stasera 20:00") { vm.quick(.tonight) } }
                chip("Domani 9:00") { vm.quick(.tomorrow) }
                Button { vm.setCustom(!vm.showCustom) } label: {
                    Label("Altro", systemImage: "calendar")
                        .font(.system(size: 12))
                        .foregroundStyle(vm.showCustom ? theme.accent : theme.foreground)
                }
                .buttonStyle(IslandButtonStyle())
                .help("Scegli ora e data")
                Spacer(minLength: 0)
            }
            if vm.showCustom {
                HStack(spacing: 6) {
                    label("Alle")
                    field(.time, text: $vm.customTime, prompt: "20:00", error: vm.timeError, height: 26, size: 12.5) { vm.addCustom() }
                        .frame(width: 62)
                    label("il")
                    field(.date, text: $vm.customDate, prompt: "oggi, domani, 24/12", error: vm.dateError, height: 26, size: 12.5) { vm.addCustom() }
                        .frame(width: 120)
                    Button(vm.editingId == nil ? "Aggiungi" : "Salva") { vm.addCustom() }
                        .buttonStyle(IslandButtonStyle(prominent: true))
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: vm.showCustom)
        .onChange(of: vm.focusText) { _, _ in focus = .text }
        .onChange(of: focus) { _, f in if f != nil { vm.requestKeyboardFocus() } }
    }

    private func field(_ which: Field, text: Binding<String>, prompt: String, error: Bool,
                       height: CGFloat, size: CGFloat, submit: @escaping () -> Void) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(theme.muted))
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .foregroundStyle(theme.foreground)
            .focused($focus, equals: which)
            .onSubmit(submit)
            .padding(.horizontal, 9)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(error ? IslandTheme.red : (focus == which ? theme.accent.opacity(0.7) : .clear), lineWidth: 1))
            .simultaneousGesture(TapGesture().onEnded { vm.requestKeyboardFocus(); focus = which })
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12)) }
            .buttonStyle(IslandButtonStyle())
            .fixedSize()
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(theme.muted)
    }
}

private struct FiringBanner: View {
    @ObservedObject var vm: RemindersViewModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.system(size: 18))
                .foregroundStyle(theme.accent)
                .symbolEffect(.bounce, value: vm.bannerId)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.bannerText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text(vm.bannerSub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Rimanda 10 min") { vm.snooze() }
                .buttonStyle(IslandButtonStyle())
                .fixedSize()
            Button("Fatto") { vm.done() }
                .buttonStyle(IslandButtonStyle(prominent: true))
                .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.accent.opacity(0.16)))
    }
}

private struct ReminderRowView: View {
    let row: ReminderRow
    let editing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            Text(row.when)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(row.soon ? theme.accent : theme.muted)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            Text(row.text)
                .font(IslandFont.body)
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.repeats != .none {
                Image(systemName: "repeat")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.muted)
                    .padding(.horizontal, 5)
                    .help(row.repeats.label)
            }
            IslandIconButton("xmark", size: 10, help: "Elimina", action: onDelete)
                .opacity(hover ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(editing ? theme.accent.opacity(0.18) : (hover ? theme.surface : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: onEdit)
        .help("Tocca per modificare")
    }
}

// MARK: - Pillola e peek

struct ReminderFaceLeading: View {
    @ObservedObject var vm: RemindersViewModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: vm.faceFiring ? "bell.fill" : "bell")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(vm.faceFiring ? theme.accent : theme.muted)
            Text(vm.faceText)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
    }
}

struct ReminderFaceTrailing: View {
    @ObservedObject var vm: RemindersViewModel
    @Environment(\.island) private var theme

    var body: some View {
        Text(vm.faceTime)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(vm.faceFiring ? theme.accent : theme.muted)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 8)
    }
}

struct ReminderPeek: View {
    @ObservedObject var vm: RemindersViewModel
    @Environment(\.island) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.system(size: 15))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.bannerText.isEmpty ? vm.faceText : vm.bannerText)
                    .font(IslandFont.bodyBold)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                Text("Passa qui sopra per Fatto o Rimanda 10 min")
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(vm.faceTime)
                .font(IslandFont.mono(12))
                .foregroundStyle(theme.muted)
        }
        .padding(.horizontal, 12)
        .frame(width: IslandMetrics.peek.width, height: IslandMetrics.peek.height)
    }
}

// MARK: - Impostazioni

struct RemindersSettingsView: View {
    @State var notifications: Bool
    let onChange: (Bool, @escaping (Bool, String?) -> Void) -> Void
    @State private var message: String?
    @State private var syncing = false

    var body: some View {
        Form {
            Section {
                Toggle("Anche una notifica di macOS", isOn: $notifications)
                    .onChange(of: notifications) { _, on in
                        guard !syncing else { syncing = false; return }
                        message = nil
                        onChange(on) { granted, text in
                            message = text
                            if granted != notifications { syncing = true; notifications = granted }
                        }
                    }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quando un promemoria scade l'isola si allarga, anche sopra i giochi e i video a schermo intero. Con questa opzione arriva anche nel Centro notifiche. Il permesso viene chiesto solo ora.")
                    if let message { Text(message).foregroundStyle(.red) }
                }
            }
        }
    }
}

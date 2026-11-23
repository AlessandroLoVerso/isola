import AppKit
import IsolaCore
import SwiftUI

/// La scheda "Appunti": filtri, ricerca, l'elenco, il riscontro "Copiato".
struct ClipboardCard: View {
    @ObservedObject var model: ClipboardHistory
    @Environment(\.island) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            header
            content
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(width: IslandMetrics.card.width, height: IslandMetrics.card.height, alignment: .top)
        .overlay(alignment: .bottom) { toast }
    }

    // MARK: in alto

    private var header: some View {
        HStack(spacing: 4) {
            ForEach(ClipboardHistory.Filter.allCases) { f in
                Chip(title: f.label, selected: model.filter == f) { model.filter = f }
            }
            Spacer(minLength: 6)
            searchField
            clearButton
        }
        .frame(height: 26)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.muted)
            TextField("", text: $model.query, prompt: Text("Cerca").foregroundStyle(theme.muted))
                .textFieldStyle(.plain)
                .font(IslandFont.small)
                .foregroundStyle(theme.foreground)
                .focused($searchFocused)
                .onExitCommand { model.query = ""; searchFocused = false }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .help("Cancella ricerca")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 132, height: 24)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(searchFocused ? theme.accent : .clear, lineWidth: 1))
        )
        .overlay {
            // Finché il campo non ha il fuoco, un clic qui fa prendere la tastiera all'isola
            // (che non è la finestra attiva) e poi dà il fuoco al campo.
            if !searchFocused {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.requestKeyboardFocus()
                        DispatchQueue.main.async { searchFocused = true }
                    }
            }
        }
        .onChange(of: searchFocused) { _, focused in
            if focused { model.requestKeyboardFocus() }
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        let hasUnpinned = model.items.contains { !$0.pinned }
        Button {
            if model.clearArmed { model.clearUnpinned() } else { model.armClear() }
        } label: {
            Text(model.clearArmed ? "Conferma" : "Svuota").font(IslandFont.small)
        }
        .buttonStyle(IslandButtonStyle(prominent: model.clearArmed))
        .disabled(!hasUnpinned)
        .opacity(hasUnpinned ? 1 : 0.4)
        .help("Svuota la cronologia, i fissati restano")
    }

    // MARK: elenco

    @ViewBuilder
    private var content: some View {
        let visible = model.visibleItems
        if visible.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(visible) { item in
                        ClipRow(model: model, item: item)
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.settings.enabled && model.items.isEmpty {
            IslandEmptyState("pause.circle", title: "Cronologia in pausa",
                             subtitle: "Riattivala da Impostazioni › Appunti.")
        } else if model.items.isEmpty {
            IslandEmptyState("doc.on.clipboard", title: "Niente negli appunti",
                             subtitle: "Copia qualcosa: lo ritrovi qui.")
        } else {
            IslandEmptyState("magnifyingglass", title: "Nessun risultato",
                             subtitle: model.query.isEmpty ? "Niente di questo tipo, per ora." : "Prova con un'altra parola.")
        }
    }

    // MARK: riscontro

    @ViewBuilder
    private var toast: some View {
        if let t = model.toast {
            HStack(spacing: 6) {
                Image(systemName: t.ok ? "checkmark" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(t.ok ? IslandTheme.green : IslandTheme.orange)
                Text(t.text).font(IslandFont.small.weight(.semibold))
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.isGlass ? Color.black.opacity(0.55) : Color(white: 0.18)))
            .padding(.bottom, 12)
            .transition(.opacity.combined(with: .offset(y: 6)))
            .id(t.id)
            .allowsHitTesting(false)
        }
    }
}

/// Un filtro tondo ("Tutto", "Testo"…).
private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(IslandFont.small.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? theme.foreground : theme.muted)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(selected ? theme.surfaceHover : (hover ? theme.surface : .clear)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Una riga della cronologia: clic = copia, a destra fissa ed elimina.
private struct ClipRow: View {
    @ObservedObject var model: ClipboardHistory
    let item: ClipItem
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        let missing = isMissing
        HStack(spacing: 9) {
            leadingIcon
                .frame(width: 30, height: 24)
            Text(title)
                .font(IslandFont.body)
                .foregroundStyle(item.kind == .link ? theme.accent : theme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(missing ? 0.5 : 1)
            Spacer(minLength: 4)
            if hover {
                IslandIconButton(item.pinned ? "pin.slash" : "pin", size: 10,
                                 help: item.pinned ? "Togli dai fissati" : "Fissa") { model.togglePin(item) }
                IslandIconButton("trash", size: 10, help: "Elimina") { model.delete(item) }
            } else {
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.muted)
                }
                Text(Self.when(item.time, now: model.now))
                    .font(IslandFont.small)
                    .foregroundStyle(theme.muted)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover ? theme.surfaceHover : theme.surface.opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.restore(item) }
        .onHover { hover = $0 }
        .help(tooltip)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch item.kind {
        case .image:
            if let img = model.thumbnail(item) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                symbol("photo")
            }
        case .files:
            if let icon = model.fileIcon(item) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                symbol("doc")
            }
        case .link:
            symbol("link")
        case .text:
            symbol("text.alignleft")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.muted)
    }

    private var isMissing: Bool {
        guard item.kind == .files, let files = item.files else { return false }
        return !files.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private var title: String {
        switch item.kind {
        case .image: return "Immagine \(item.imageWidth) × \(item.imageHeight)"
        case .files:
            let files = item.files ?? []
            guard let first = files.first else { return "File" }
            let name = (first as NSString).lastPathComponent
            return files.count == 1 ? name : "\(name) e altri \(files.count - 1)"
        case .link: return item.text ?? ""
        case .text: return Self.oneLine(item.text ?? "", max: 220)
        }
    }

    private var tooltip: String {
        switch item.kind {
        case .files:
            let files = item.files ?? []
            var s = files.prefix(12).joined(separator: "\n")
            if files.count > 12 { s += "\n…" }
            return s
        case .image: return "Clic per copiare l'immagine"
        default:
            let t = item.text ?? ""
            return t.count <= 600 ? t : String(t.prefix(600)) + "…"
        }
    }

    static func oneLine(_ s: String, max: Int) -> String {
        var out = ""
        var space = false
        for c in s {
            if c.isWhitespace { space = !out.isEmpty; continue }
            if space { out.append(" "); space = false }
            out.append(c)
            if out.count >= max { out.append("…"); break }
        }
        return out
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM yy"
        return f
    }()

    static func when(_ t: Date, now: Date) -> String {
        let d = now.timeIntervalSince(t)
        let cal = Calendar.current
        if d < 60 { return "ora" }
        if d < 3600 { return "\(Int(d / 60)) min" }
        if cal.isDate(t, inSameDayAs: now) { return timeFormatter.string(from: t) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(t, inSameDayAs: y) { return "ieri" }
        if cal.component(.year, from: t) == cal.component(.year, from: now) {
            return dayFormatter.string(from: t).replacingOccurrences(of: ".", with: "")
        }
        return yearFormatter.string(from: t).replacingOccurrences(of: ".", with: "")
    }
}

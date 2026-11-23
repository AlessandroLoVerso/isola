import AppKit
import IsolaCore
import SwiftUI
import UniformTypeIdentifiers

/// La scheda "Mensola": riquadri dei file, barra delle azioni, zona di rilascio su tutta la scheda.
struct ShelfCard: View {
    @ObservedObject var model: ShelfModel
    @Environment(\.island) private var theme

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 96), spacing: 6)]

    var body: some View {
        ZStack {
            if model.items.isEmpty {
                IslandEmptyState("tray.and.arrow.down", title: "Trascina qui i file",
                                 subtitle: "Restano qui finché non li trascini fuori. Non vengono copiati.")
                    .opacity(model.dropTargeted ? 0 : 1)
            } else {
                VStack(spacing: 6) {
                    ShelfActionBar(model: model)
                    ScrollView(.vertical) {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(model.items) { item in
                                ShelfTile(model: model, item: item)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .scrollIndicators(.never)
                }
                .opacity(model.dropTargeted ? 0.25 : 1)
            }
            if model.dropTargeted { dropZone.transition(.opacity) }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(width: IslandMetrics.card.width, height: IslandMetrics.card.height, alignment: .top)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], delegate: ShelfDropDelegate(model: model))
        .animation(.easeOut(duration: 0.15), value: model.dropTargeted)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(theme.accent)
            Text("Rilascia per mettere sulla mensola")
                .font(IslandFont.bodyBold)
                .foregroundStyle(theme.foreground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.accent.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
        )
        .allowsHitTesting(false)
    }
}

/// Accetta solo file, e solo in copia: non dice mai "sposta" (la sorgente cancellerebbe l'originale).
struct ShelfDropDelegate: DropDelegate {
    let model: ShelfModel

    func validateDrop(info: DropInfo) -> Bool {
        !model.draggingOut && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { model.dropTargeted = true }
    }

    func dropExited(info: DropInfo) { model.dropTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dropTargeted = false
        guard validateDrop(info: info) else { return false }
        return model.add(providers: info.itemProviders(for: [.fileURL]))
    }
}

// MARK: - Barra delle azioni

private struct ShelfActionBar: View {
    @ObservedObject var model: ShelfModel
    @Environment(\.island) private var theme

    var body: some View {
        let n = model.items.count
        let sel = model.selection.count
        let targets = model.targetItems
        let offline = model.offline.count

        HStack(spacing: 4) {
            Text(summary(n: n, sel: sel, offline: offline))
                .font(IslandFont.small)
                .foregroundStyle(theme.muted)
                .lineLimit(1)
            Spacer(minLength: 6)

            Button { model.toggleSelectAll() } label: {
                Text(sel > 0 ? "Deseleziona" : "Seleziona tutto").font(IslandFont.small)
            }
            .buttonStyle(IslandButtonStyle())

            IslandIconButton("eye", size: 11, help: "Anteprima") { model.quickLook(targets) }
                .disabled(targets.isEmpty)
            AirDropButton { model.airDrop(targets) }
                .disabled(targets.isEmpty)
            if !targets.isEmpty {
                ShareLink(items: targets.map(\.url)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .frame(width: 23, height: 23)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Condividi")
            }
            IslandIconButton("folder", size: 11, help: "Mostra nel Finder") { model.reveal(targets) }
                .disabled(targets.isEmpty)

            Button {
                if sel > 0 { model.remove(model.selection) } else { model.clear() }
            } label: {
                Text(sel > 0 ? "Togli" : "Svuota").font(IslandFont.small)
            }
            .buttonStyle(IslandButtonStyle())
            .help(sel > 0 ? "Togli i selezionati dalla mensola" : "Svuota la mensola (i file restano dove sono)")
        }
        .frame(height: 26)
    }

    private func summary(n: Int, sel: Int, offline: Int) -> String {
        if sel > 0 { return sel == n ? "Tutti selezionati (\(n))" : "\(sel) selezionati su \(n)" }
        var s = n == 1 ? "1 file" : "\(n) file"
        if offline > 0 { s += " · \(offline) non raggiungibili" }
        return s
    }
}

/// Il pulsante AirDrop con l'icona di sistema.
private struct AirDropButton: View {
    let action: () -> Void
    @Environment(\.island) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if let img = ShelfModel.airDrop?.image {
                    Image(nsImage: img).resizable().scaledToFit().frame(width: 15, height: 15)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                }
            }
            .frame(width: 23, height: 23)
            .background(Circle().fill(hover ? theme.surfaceHover : .clear))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Invia con AirDrop")
    }
}

// MARK: - Riquadro

/// Un file: clic = seleziona, doppio clic = apri, trascina = porta fuori (il gruppo se selezionato).
private struct ShelfTile: View {
    @ObservedObject var model: ShelfModel
    let item: ShelfItem
    @Environment(\.island) private var theme
    @State private var hover = false

    var body: some View {
        let selected = model.selection.contains(item.id)
        let offline = model.offline.contains(item.id)

        ZStack(alignment: .topTrailing) {
            VStack(spacing: 3) {
                Image(nsImage: model.thumbnails[item.id] ?? model.icon(item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                Text(item.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .opacity(offline ? 0.4 : 1)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? theme.accent.opacity(0.28) : (hover ? theme.surfaceHover : theme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? theme.accent : .clear, lineWidth: 1.2)
            )

            TileMouseArea(
                onHover: { hover = $0 },
                onClick: { model.toggleSelection(item) },
                onDoubleClick: { model.open(item) },
                dragURLs: { model.dragURLs(from: item) },
                dragImage: { url in NSWorkspace.shared.icon(forFile: url.path) },
                dragSource: model.dragSource,
                menu: { contextMenu() }
            )

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white, theme.accent)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
            }
            if hover {
                Button { model.remove([item.id]) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.foreground)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(theme.surfaceHover))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Togli dalla mensola")
            }
        }
        .help(offline ? item.path + "\nDisco non collegato" : item.path)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let group = model.selection.contains(item.id) ? model.selectedItems : [item]
        let reachable = !model.offline.contains(item.id)
        menu.addItem(ClosureMenuItem("Apri") { [model, item] in model.open(item) }.enabled(reachable))
        menu.addItem(ClosureMenuItem("Anteprima") { [model] in model.quickLook(group) }.enabled(reachable))
        menu.addItem(ClosureMenuItem("Mostra nel Finder") { [model] in model.reveal(group) }.enabled(reachable))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Invia con AirDrop") { [model] in model.airDrop(group) }
            .enabled(reachable && ShelfModel.airDrop != nil))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(group.count > 1 ? "Togli \(group.count) dalla mensola" : "Togli dalla mensola") {
            [model] in model.remove(Set(group.map(\.id)))
        })
        return menu
    }
}

/// Voce di menu con un blocco al posto di target/azione.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) non usato") }

    @objc private func run() { handler() }

    func enabled(_ on: Bool) -> ClosureMenuItem {
        if !on { action = nil }
        return self
    }
}

// MARK: - Mouse in AppKit

/// SwiftUI su macOS trascina un solo elemento alla volta e non dice quando il trascinamento
/// finisce: questa vista trasparente gestisce clic, doppio clic, menu e trascinamento multiplo.
private struct TileMouseArea: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void
    var dragURLs: () -> [URL]
    var dragImage: (URL) -> NSImage
    var dragSource: ShelfDragSource
    var menu: () -> NSMenu

    func makeNSView(context: Context) -> TileMouseView {
        let v = TileMouseView()
        v.config = self
        return v
    }

    func updateNSView(_ v: TileMouseView, context: Context) { v.config = self }

    static func dismantleNSView(_ v: TileMouseView, coordinator: ()) {
        v.config?.onHover(false)
        v.config = nil
    }
}

private final class TileMouseView: NSView {
    var config: TileMouseArea?
    private var downEvent: NSEvent?
    private var dragStarted = false
    private var wasDouble = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { config?.onHover(true) }
    override func mouseExited(with event: NSEvent) { config?.onHover(false) }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragStarted = false
        wasDouble = event.clickCount >= 2
        if wasDouble { config?.onDoubleClick() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let down = downEvent, let config else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        dragStarted = true
        let urls = config.dragURLs()
        guard !urls.isEmpty else { return }

        let start = convert(down.locationInWindow, from: nil)
        let side: CGFloat = 44
        let items: [NSDraggingItem] = urls.enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(i, 4)) * 4
            let frame = NSRect(x: start.x - side / 2 + offset, y: start.y - side / 2 - offset, width: side, height: side)
            item.setDraggingFrame(frame, contents: config.dragImage(url))
            return item
        }
        config.dragSource.urls = urls
        let session = beginDraggingSession(with: items, event: down, source: config.dragSource)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragStarted, !wasDouble, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        config?.onClick()
    }

    override func menu(for event: NSEvent) -> NSMenu? { config?.menu() }
}

import SwiftUI

/// I colori dell'isola. Arrivano a ogni vista con `@Environment(\.island)` e cambiano a caldo.
public struct IslandTheme: Equatable, Sendable {
    public var background: Color
    public var foreground: Color
    public var muted: Color
    public var accent: Color
    public var surface: Color
    public var surfaceHover: Color
    /// `true` per Vetro e Liquido: lo sfondo è traslucido.
    public var isGlass: Bool

    public init(background: Color, foreground: Color, muted: Color, accent: Color,
                surface: Color, surfaceHover: Color, isGlass: Bool) {
        self.background = background
        self.foreground = foreground
        self.muted = muted
        self.accent = accent
        self.surface = surface
        self.surfaceHover = surfaceHover
        self.isGlass = isGlass
    }

    public static let nero = IslandTheme(
        background: .black,
        foreground: .white,
        muted: Color(white: 0.62),
        accent: Color(red: 0.04, green: 0.52, blue: 1.0),
        surface: Color.white.opacity(0.08),
        surfaceHover: Color.white.opacity(0.14),
        isGlass: false)

    public static let grafite = IslandTheme(
        background: Color(red: 0x2A / 255, green: 0x2B / 255, blue: 0x30 / 255),
        foreground: .white,
        muted: Color(white: 0.66),
        accent: Color(red: 0.04, green: 0.52, blue: 1.0),
        surface: Color.white.opacity(0.09),
        surfaceHover: Color.white.opacity(0.16),
        isGlass: false)

    public static let vetro = IslandTheme(
        background: Color.black.opacity(0.28),
        foreground: .white,
        muted: Color.white.opacity(0.7),
        accent: Color(red: 0.25, green: 0.62, blue: 1.0),
        surface: Color.white.opacity(0.12),
        surfaceHover: Color.white.opacity(0.2),
        isGlass: true)

    /// Colori fissi per gli stati: lavoro, fatto, attenzione, errore.
    public static let orange = Color(red: 1.0, green: 0.62, blue: 0.04)
    public static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    public static let red = Color(red: 1.0, green: 0.27, blue: 0.23)
}

private struct IslandThemeKey: EnvironmentKey {
    static let defaultValue = IslandTheme.nero
}

public extension EnvironmentValues {
    var island: IslandTheme {
        get { self[IslandThemeKey.self] }
        set { self[IslandThemeKey.self] = newValue }
    }
}

// MARK: - Testo

public enum IslandFont {
    public static let small = Font.system(size: 11)
    public static let body = Font.system(size: 13)
    public static let bodyBold = Font.system(size: 13, weight: .semibold)
    public static let title = Font.system(size: 16, weight: .semibold)
    /// Numeri che non ballano (ore, timer, percentuali).
    public static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

// MARK: - Stili pronti per le schede

/// Pulsante dell'isola: superficie tenue, si illumina al passaggio.
public struct IslandButtonStyle: ButtonStyle {
    public var prominent: Bool
    public init(prominent: Bool = false) { self.prominent = prominent }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, prominent: prominent)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.island) private var theme
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(IslandFont.body)
                .foregroundStyle(prominent ? Color.white : theme.foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? theme.accent : (hover ? theme.surfaceHover : theme.surface))
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hover = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// Pulsante tondo con sola icona (comandi della musica, chiudi, ecc.).
public struct IslandIconButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @Environment(\.island) private var theme
    @State private var hover = false

    public init(_ symbol: String, size: CGFloat = 14, help: String = "", action: @escaping () -> Void) {
        self.symbol = symbol
        self.size = size
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(theme.foreground)
                .frame(width: size * 2.1, height: size * 2.1)
                .background(Circle().fill(hover ? theme.surfaceHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Superficie arrotondata per raggruppare righe dentro una scheda.
public struct IslandSurface<Content: View>: View {
    let content: Content
    let padding: CGFloat
    @Environment(\.island) private var theme

    public init(padding: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
    }

    public var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface))
    }
}

/// Messaggio per una scheda vuota: icona, titolo, sottotitolo.
public struct IslandEmptyState: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Environment(\.island) private var theme

    public init(_ symbol: String, title: String, subtitle: String = "") {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(theme.muted)
            Text(title).font(IslandFont.bodyBold).foregroundStyle(theme.foreground)
            if !subtitle.isEmpty {
                Text(subtitle).font(IslandFont.small).foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

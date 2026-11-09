import SwiftUI
import AppKit

/// Material Design 3 (m3.material.io) odwzorowany w SwiftUI.
///
/// Bez biblioteki, tak samo jak HeroUI w rozszerzeniu: bierzemy wygląd design
/// systemu (role kolorów, skalę kształtów, typografię, warstwy stanu),
/// a nie zależność. Paleta to schemat Google Workspace (Gmail, Kalendarz,
/// Dysk), czyli M3 wygenerowany z niebieskiego #0B57D0, w wersji jasnej
/// i ciemnej. Kolory przełączają się same za wyglądem systemu.
enum M3 {
    // MARK: - kolory

    /// Role kolorów M3. Nazwy 1:1 z m3.material.io/styles/color/roles.
    enum color {
        // Branding Breydaqs (breydaqs.com): papier #e8e8e3 i atrament #080807,
        // w ciemnym #161614 i #e8e8e3; akcent #ff7a59 tylko tam, gdzie coś
        // „żyje" (nagrywanie, wypowiedź w trakcie). Nazwy ról zostały z M3,
        // żeby nie ruszać widoków — zmieniły się wartości.
        static let accent = dyn(0xFF7A59, 0xFF7A59)
        static let dark = dyn(0x0D0D0C, 0x0D0D0C)
        static let light = dyn(0xE8E8E3, 0xE8E8E3)

        static let primary = dyn(0x080807, 0xE8E8E3)
        static let onPrimary = dyn(0xE8E8E3, 0x0D0D0C)
        static let primaryContainer = dyn(0xD6D6D0, 0x2A2A27)
        static let onPrimaryContainer = dyn(0x080807, 0xE8E8E3)
        static let secondaryContainer = dyn(0x080807, 0xE8E8E3)
        static let onSecondaryContainer = dyn(0xE8E8E3, 0x161614)
        static let tertiary = dyn(0x2F7D4F, 0x6FCF97)
        static let tertiaryContainer = dyn(0xC9DCCB, 0x1F3A2A)
        static let onTertiaryContainer = dyn(0x17432A, 0xC9F0D9)
        static let error = dyn(0xC2361B, 0xFF8A6E)
        /// Stan „nagrywam" (aktywny przycisk główny): akcent z ciemnym tekstem.
        static let errorContainer = dyn(0xFF7A59, 0xFF7A59)
        static let onErrorContainer = dyn(0x0D0D0C, 0x0D0D0C)

        static let surface = dyn(0xE8E8E3, 0x161614)
        static let surfaceContainerLowest = dyn(0xEFEFEA, 0x121210)
        static let surfaceContainerLow = dyn(0xE3E3DD, 0x1A1A18)
        static let surfaceContainer = dyn(0xE0E0DA, 0x1C1C1A)
        static let surfaceContainerHigh = dyn(0xDCDCD5, 0x22221F)
        static let surfaceContainerHighest = dyn(0xD6D6D0, 0x2A2A27)
        static let onSurface = dyn(0x080807, 0xE8E8E3)
        static let onSurfaceVariant = dyn(0x5A5A55, 0xA4A49E)
        static let outline = dyn(0x8A8A84, 0x6E6E69)
        static let outlineVariant = dyn(0xC6C6BF, 0x3A3A36)

        /// Strona i karty jak sekcje papieru na stronie: karta o ton ciemniejsza.
        static let page = dyn(0xE8E8E3, 0x161614)
        static let card = dyn(0xE1E1DB, 0x1F1F1C)
        static let cardInset = dyn(0xE8E8E3, 0x161614)
        static let cardField = dyn(0xE8E8E3, 0x161614)

        /// Kolor zależny od wyglądu systemu, bez katalogu zasobów (SwiftPM
        /// go nie ma, a my nie chcemy kroku build).
        private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                               green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
        }
    }

    // MARK: - kształty

    /// Rogi jak na stronie Breydaqs (`rounded-[0.15rem]`): prawie kwadrat.
    enum shape {
        static let extraSmall: CGFloat = 2
        static let small: CGFloat = 3
        static let medium: CGFloat = 3
        static let large: CGFloat = 4
        static let extraLarge: CGFloat = 6
    }

    // MARK: - typografia

    /// Typografia Breydaqs: Geist do tytułów, Inter Tight do tekstu,
    /// JetBrains Mono do małych etykiet. Fonty w paczce (`BrandFonts`);
    /// bez nich SwiftUI spada na krój systemowy.
    enum type {
        static let headlineSmall = Font.custom(BrandFonts.display, size: 28).weight(.semibold)
        static let titleLarge = Font.custom(BrandFonts.display, size: 22).weight(.semibold)
        static let titleMedium = Font.custom(BrandFonts.sans, size: 16).weight(.semibold)
        static let titleSmall = Font.custom(BrandFonts.sans, size: 14).weight(.semibold)
        static let bodyLarge = Font.custom(BrandFonts.sans, size: 16).weight(.medium)
        static let bodyMedium = Font.custom(BrandFonts.sans, size: 14).weight(.medium)
        static let bodySmall = Font.custom(BrandFonts.sans, size: 12).weight(.medium)
        static let labelLarge = Font.custom(BrandFonts.sans, size: 14).weight(.semibold)
        static let labelMedium = Font.custom(BrandFonts.mono, size: 10.5).weight(.medium)
        static let labelSmall = Font.custom(BrandFonts.mono, size: 10).weight(.medium)
    }

    // MARK: - warstwy stanu

    /// Krycie warstwy stanu: najechanie 8 %, wciśnięcie 10 %
    /// (m3.material.io/foundations/interaction/states/state-layers).
    static func stateOpacity(hovered: Bool, pressed: Bool) -> Double {
        pressed ? 0.10 : (hovered ? 0.08 : 0)
    }
}

// MARK: - przyciski

/// Wspólna mechanika przycisków M3: kapsuła, wysokość 40, warstwa stanu
/// w kolorze treści, przygaszenie wyłączonego do 38 %.
struct M3ButtonStyle: ButtonStyle {
    enum Kind { case filled, tonal, outlined, text, error }
    var kind: Kind = .filled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        M3ButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct M3ButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: M3ButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    private var container: Color {
        switch kind {
        case .filled: return M3.color.primary
        case .tonal: return M3.color.secondaryContainer
        case .error: return M3.color.errorContainer
        case .outlined, .text: return .clear
        }
    }

    private var content: Color {
        switch kind {
        case .filled: return M3.color.onPrimary
        case .tonal: return M3.color.onSecondaryContainer
        case .error: return M3.color.onErrorContainer
        case .outlined, .text: return M3.color.primary
        }
    }

    var body: some View {
        configuration.label
            .font(M3.type.labelLarge)
            .labelStyle(M3LabelStyle())
            .foregroundStyle(isEnabled ? content : M3.color.onSurface.opacity(0.38))
            .padding(.horizontal, kind == .text ? 12 : (compact ? 16 : 24))
            .frame(height: compact ? 32 : 40)
            .background {
                RoundedRectangle(cornerRadius: M3.shape.small).fill(isEnabled ? container
                               : (kind == .outlined || kind == .text ? .clear : M3.color.onSurface.opacity(0.12)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: M3.shape.small)
                    .fill(content.opacity(M3.stateOpacity(hovered: hovered, pressed: configuration.isPressed)))
            }
            .overlay {
                if kind == .outlined {
                    RoundedRectangle(cornerRadius: M3.shape.small)
                        .strokeBorder(isEnabled ? M3.color.onSurface : M3.color.onSurface.opacity(0.12))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: M3.shape.small))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Ikona 18 pt i 8 pt odstępu, jak w przyciskach M3 z ikoną.
struct M3LabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 16, weight: .medium))
            configuration.title
        }
    }
}

/// Przycisk-ikona M3: okrąg 40 pt, warstwa stanu w kolorze ikony.
/// `selected` daje wariant przełącznika (tonalne wypełnienie).
struct M3IconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        M3IconButtonBody(configuration: configuration, selected: selected)
    }
}

private struct M3IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let tint = selected ? M3.color.onSecondaryContainer : M3.color.onSurfaceVariant
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(isEnabled ? tint : M3.color.onSurface.opacity(0.38))
            .frame(width: 38, height: 38)
            .background(RoundedRectangle(cornerRadius: M3.shape.small).fill(selected ? M3.color.secondaryContainer : .clear))
            .overlay(RoundedRectangle(cornerRadius: M3.shape.small)
                .fill(tint.opacity(M3.stateOpacity(hovered: hovered, pressed: configuration.isPressed))))
            .contentShape(RoundedRectangle(cornerRadius: M3.shape.small))
            .onHover { hovered = $0 }
    }
}

/// Rozszerzony FAB M3: główna akcja ekranu. Kontener primary w wersji
/// „primary container", róg 16, wysokość 56, uniesienie poziomu 3.
struct M3FABStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        M3FABBody(configuration: configuration, active: active)
    }
}

private struct M3FABBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        // Przycisk jak na stronie Breydaqs: atrament, tekst i kwadrat ze
        // strzałką, który przy najechaniu lekko się kurczy. Nagrywanie = akcent.
        let container = active ? M3.color.errorContainer : M3.color.primary
        let content = active ? M3.color.onErrorContainer : M3.color.onPrimary
        HStack(spacing: 12) {
            configuration.label
                .labelStyle(.titleOnly)
                .font(.custom(BrandFonts.sans, size: 17).weight(.semibold))
            Text(active ? "■" : "↗")
                .font(.system(size: active ? 13 : 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: M3.shape.small)
                    .fill(active ? M3.color.dark.opacity(0.18) : M3.color.onPrimary.opacity(0.16)))
                .scaleEffect(hovered ? 0.84 : 1)
        }
        .foregroundStyle(content)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: M3.shape.small).fill(container))
        .overlay(RoundedRectangle(cornerRadius: M3.shape.small)
            .fill(content.opacity(configuration.isPressed ? 0.08 : 0)))
        .opacity(isEnabled ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: M3.shape.small))
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: hovered)
    }
}

/// Przycisk szyny nawigacji M3: ikona we wskaźniku 56×32 (kapsuła), pod nią
/// etykieta. `selected` daje wypełnienie secondary container.
struct M3RailButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        M3RailButtonBody(configuration: configuration, selected: selected)
    }
}

private struct M3RailButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .labelStyle(M3RailLabelStyle(selected: selected,
                                         overlayOpacity: M3.stateOpacity(hovered: hovered, pressed: configuration.isPressed)))
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { hovered = $0 }
    }
}

/// Wygląd pozycji szyny; osobno, bo etykieta `Menu` nie przechodzi przez
/// `ButtonStyle`.
struct M3RailLabelStyle: LabelStyle {
    var selected = false
    var overlayOpacity: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(selected ? M3.color.onSecondaryContainer : M3.color.onSurfaceVariant)
                .frame(width: 52, height: 32)
                .background(RoundedRectangle(cornerRadius: M3.shape.small).fill(selected ? M3.color.secondaryContainer : .clear))
                .overlay(RoundedRectangle(cornerRadius: M3.shape.small)
                    .fill((selected ? M3.color.onSecondaryContainer : M3.color.onSurfaceVariant).opacity(overlayOpacity)))
            configuration.title
                .font(M3.type.labelSmall)
                .textCase(.uppercase)
                .foregroundStyle(selected ? M3.color.onSurface : M3.color.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
    }
}

// MARK: - powierzchnie

extension View {
    /// Karta M3. `filled` = surface container highest, `outlined` = obrys
    /// outline variant na surface, `elevated` = low + cień poziomu 1.
    func m3Card(_ style: M3CardStyle = .filled, radius: CGFloat = M3.shape.medium) -> some View {
        modifier(M3CardModifier(style: style, radius: radius))
    }
}

enum M3CardStyle { case filled, outlined, elevated }

private struct M3CardModifier: ViewModifier {
    let style: M3CardStyle
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        switch style {
        case .filled:
            content.background(M3.color.surfaceContainerHighest, in: shape)
        case .outlined:
            content.background(M3.color.surface, in: shape)
                .overlay(shape.strokeBorder(M3.color.outlineVariant))
        case .elevated:
            content.background(M3.color.surfaceContainerLow, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

/// Chip M3 (asystujący / informacyjny): róg 8, wysokość 32, obrys albo
/// tonalne wypełnienie, gdy wybrany.
struct M3Chip: View {
    var text: String
    var systemImage: String?
    var selected = false
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint ?? (selected ? M3.color.onSecondaryContainer : M3.color.primary))
            }
            Text(text).font(M3.type.labelLarge)
                .foregroundStyle(selected ? M3.color.onSecondaryContainer : M3.color.onSurfaceVariant)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: M3.shape.small)
            .fill(selected ? M3.color.secondaryContainer : .clear))
        .overlay(RoundedRectangle(cornerRadius: M3.shape.small)
            .strokeBorder(selected ? .clear : M3.color.outlineVariant))
    }
}

/// Pole tekstowe M3 w wariancie „filled": tło surface container highest,
/// górne rogi 4, dolna linia aktywna w kolorze primary.
struct M3FieldBackground: ViewModifier {
    var focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(M3.color.cardField, in: RoundedRectangle(cornerRadius: M3.shape.small))
            .overlay {
                RoundedRectangle(cornerRadius: M3.shape.small)
                    .strokeBorder(focused ? M3.color.onSurface : M3.color.outlineVariant)
            }
    }
}

/// Wskaźnik liniowy M3: tor secondary container, wskaźnik primary.
///
/// Animowany przez Core Animation, nie SwiftUI. `repeatForever` w SwiftUI
/// to aktualizacja grafu co klatkę (120 Hz), a w oknie z ukrytym paskiem
/// tytułu każda klatka przelicza też regiony przeciągania całego okna.
/// Zmierzone 2026-11-09: jeden taki pasek przy odpowiedzi „w toku" = ~55% CPU
/// głównego wątku, także przy oknie na innym pulpicie. Animacja warstwy
/// chodzi w render serverze i główny wątek jej nie widzi.
struct M3LinearProgress: View {
    var body: some View {
        IndeterminateBar().frame(height: 4)
    }
}

private struct IndeterminateBar: NSViewRepresentable {
    func makeNSView(context: Context) -> IndeterminateBarView { IndeterminateBarView() }
    func updateNSView(_ nsView: IndeterminateBarView, context: Context) {}
}

final class IndeterminateBarView: NSView {
    private let indicator = CALayer()
    private var animatedWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(indicator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nie jest używane") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(M3.color.secondaryContainer).cgColor
            indicator.backgroundColor = NSColor(M3.color.primary).cgColor
        }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        layer?.cornerRadius = size.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.frame = CGRect(x: 0, y: 0, width: size.width * 0.4, height: size.height)
        indicator.cornerRadius = size.height / 2
        CATransaction.commit()
        // Animacja zależy od szerokości — podmieniamy ją tylko, gdy ta się zmieni.
        guard size.width != animatedWidth else { return }
        animatedWidth = size.width
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = -size.width * 0.4
        slide.toValue = size.width
        slide.duration = 1.4
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .linear)
        indicator.add(slide, forKey: "slide")
    }
}

/// Wskaźnik liniowy M3 z wartością (import, pobieranie modelu).
struct M3ProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(M3.color.secondaryContainer)
                Capsule().fill(M3.color.primary)
                    .frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

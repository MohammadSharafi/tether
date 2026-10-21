import SwiftUI

/// The app's look: Claude's clay orange (AccentColor in the asset catalog) and per-project colors.
enum Theme {
    static let appearanceKey = "appearance"   // dark | light | system

    static func scheme(_ appearance: String) -> ColorScheme? {
        switch appearance {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }

    /// Warm gradient for your own messages and buttons that should stand out.
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.93, green: 0.56, blue: 0.40), Color(red: 0.80, green: 0.39, blue: 0.27)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private static let palette: [Color] = [
        Color(red: 0.85, green: 0.47, blue: 0.34), Color(red: 0.36, green: 0.55, blue: 0.95),
        Color(red: 0.55, green: 0.42, blue: 0.90), Color(red: 0.25, green: 0.68, blue: 0.55),
        Color(red: 0.90, green: 0.40, blue: 0.55), Color(red: 0.90, green: 0.66, blue: 0.25),
        Color(red: 0.30, green: 0.66, blue: 0.80), Color(red: 0.55, green: 0.60, blue: 0.68),
    ]

    /// The same project always gets the same color (Swift's hashValue changes per launch, so sum the characters).
    static func color(for project: String) -> Color {
        palette[project.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % palette.count]
    }
}

/// A rounded square with the project's first letter, in the project's color.
struct ProjectBadge: View {
    let name: String
    var size: CGFloat = 38

    var body: some View {
        let color = Theme.color(for: name)
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// A soft rounded panel for grouped content on the plain chat background.
struct CardBackground: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .background((tint?.opacity(0.10)).map(AnyShapeStyle.init) ?? AnyShapeStyle(.background.secondary), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder((tint ?? .primary).opacity(0.12)))
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(CardBackground(tint: tint)) }
}

import SwiftUI

enum TidDesign {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedCard = Color(uiColor: .systemBackground)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let accent = Color(red: 0.10, green: 0.38, blue: 0.85)
    static let softAccent = accent.opacity(0.12)
    static let mutedAccent = Color(red: 0.43, green: 0.58, blue: 0.76)
    static let success = Color(red: 0.13, green: 0.58, blue: 0.32)
    static let error = Color(red: 0.74, green: 0.16, blue: 0.16)
    static let outline = Color.black.opacity(0.07)
    static let cornerRadius: CGFloat = 28
    static let compactCornerRadius: CGFloat = 18
}

struct TidPrimaryButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(isDestructive ? TidDesign.error : TidDesign.accent, in: Capsule())
            .shadow(color: (isDestructive ? TidDesign.error : TidDesign.accent).opacity(configuration.isPressed ? 0.08 : 0.18), radius: 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.86), value: configuration.isPressed)
    }
}

struct TidIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(TidDesign.textSecondary)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(TidDesign.outline, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

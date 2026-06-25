import SwiftUI

enum TidTheme {
    static let background = Color(hex: 0xFAF9FE)
    static let groupedBackground = Color(hex: 0xF2F2F7)
    static let card = Color.white
    static let cardDark = Color(hex: 0x1D1D20)
    static let primary = Color(hex: 0x007AFF)
    static let primaryDeep = Color(hex: 0x0058BC)
    static let success = Color(hex: 0x34C759)
    static let error = Color(hex: 0xD11B1B)
    static let text = Color(hex: 0x1A1B1F)
    static let secondaryText = Color(hex: 0x414755)
    static let outline = Color(hex: 0xC6C6C8)
}

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

struct PressableScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: configuration.isPressed)
    }
}

struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(TidTheme.primary, in: Capsule())
            .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.12), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.86), value: configuration.isPressed)
    }
}

struct WaveformView: View {
    var active: Bool = true
    var compact: Bool = false

    private let heights: [CGFloat] = [24, 34, 52, 34, 46, 58, 40, 54, 30]
    private let colors: [Color] = [
        TidTheme.primary,
        TidTheme.primary,
        .white,
        Color(hex: 0xFFD1D1),
        Color(hex: 0xE12A2A),
        .white,
        TidTheme.primary,
        .white,
        Color(hex: 0xFFD1D1)
    ]

    var body: some View {
        HStack(spacing: compact ? 4 : 9) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(colors[index])
                    .frame(width: compact ? 4 : 8, height: compact ? heights[index] * 0.45 : heights[index])
                    .scaleEffect(y: active ? 1 : 0.55, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.05),
                        value: active
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

struct SoftAuroraBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(hex: 0xEAF5FA),
                Color(hex: 0xF7E6EA),
                Color(hex: 0xE7F6F7),
                Color(hex: 0xF7F5F9)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [TidTheme.primary.opacity(0.16), .clear],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 360
            )
        )
        .ignoresSafeArea()
    }
}


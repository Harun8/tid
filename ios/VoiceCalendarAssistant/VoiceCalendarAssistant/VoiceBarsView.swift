import SwiftUI

struct VoiceBarsView: View {
    var isRecording: Bool
    var level: CGFloat?

    private let barCount = 27

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(color(for: index))
                        .frame(width: 4, height: height(for: index, time: time))
                        .animation(.easeInOut(duration: 0.18), value: isRecording)
                }
            }
            .frame(height: 86)
            .accessibilityHidden(true)
        }
    }

    private func height(for index: Int, time: TimeInterval) -> CGFloat {
        let baseline = CGFloat(10 + ((index * 7) % 16))
        guard isRecording else {
            return baseline * 0.46
        }

        let normalizedLevel = max(0.08, min(level ?? 0.42, 1))
        let phase = Double(index) * 0.43
        let wave = (sin((time * 4.4) + phase) + 1) / 2
        let secondaryWave = (sin((time * 2.2) + phase * 1.8) + 1) / 2
        let pulse = CGFloat((wave * 0.72) + (secondaryWave * 0.28))
        let shapeBias = CGFloat(0.55 + (sin(Double(index) * 0.72) + 1) * 0.22)

        return 8 + (normalizedLevel * 54 * pulse * shapeBias) + baseline * 0.35
    }

    private func color(for index: Int) -> Color {
        if !isRecording {
            return TidDesign.mutedAccent.opacity(0.34)
        }

        let center = Double(abs(index - (barCount / 2))) / Double(barCount / 2)
        return TidDesign.accent.opacity(0.52 + ((1 - center) * 0.35))
    }
}

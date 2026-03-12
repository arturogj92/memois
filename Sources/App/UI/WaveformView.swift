import SwiftUI

struct WaveformView: View {
    let level: Float
    var barCount: Int = 16
    var barWidth: CGFloat = 2.5
    var barSpacing: CGFloat = 1.5
    var maxHeight: CGFloat = 20
    var minHeight: CGFloat = 3
    var style: WaveformStyle = .bars

    enum WaveformStyle {
        case bars
        case wave
    }

    var body: some View {
        switch style {
        case .bars:
            barsView
        case .wave:
            waveView
        }
    }

    // MARK: - Bars style

    private var barsView: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(.white)
                        .frame(width: barWidth, height: barHeight(index: index, date: timeline.date))
                }
            }
        }
    }

    private func barHeight(index: Int, date: Date) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        let phase = Double(index) * 0.5
        let wave1 = (sin(time * 5.0 + phase) + 1.0) / 2.0
        let wave2 = (sin(time * 3.2 + phase * 1.3) + 1.0) / 2.0
        let combined = (wave1 * 0.6 + wave2 * 0.4)

        let center = Double(barCount) / 2.0
        let distance = abs(Double(index) - center) / center
        let envelope = 1.0 - distance * 0.4

        let normalized = CGFloat(level) * CGFloat(combined * envelope)
        return minHeight + (maxHeight - minHeight) * max(0.08, normalized)
    }

    // MARK: - Wave style (logo-like)

    private var waveView: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height / 2
                let amplitude = size.height * 0.4 * CGFloat(max(level, 0.05))
                let steps = Int(size.width / 1.5)

                var path = Path()

                for i in 0...steps {
                    let x = CGFloat(i) / CGFloat(steps) * size.width
                    let progress = Double(i) / Double(steps)

                    // Envelope: peaks in the middle, tapers at edges
                    let envelope = sin(progress * .pi)

                    // Multiple wave layers for organic feel
                    let w1 = sin(progress * 4.0 * .pi + time * 4.5) * 0.6
                    let w2 = sin(progress * 6.0 * .pi + time * 3.0) * 0.25
                    let w3 = sin(progress * 2.5 * .pi + time * 5.5) * 0.15

                    let wave = (w1 + w2 + w3) * envelope
                    let y = midY - CGFloat(wave) * amplitude

                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                let gradient = Gradient(colors: [
                    Color(red: 0.0, green: 0.8, blue: 0.95),
                    Color(red: 0.2, green: 0.9, blue: 0.5),
                    Color(red: 0.95, green: 0.9, blue: 0.1),
                    Color(red: 1.0, green: 0.5, blue: 0.2),
                    Color(red: 1.0, green: 0.3, blue: 0.6)
                ])

                context.stroke(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: 0, y: midY),
                        endPoint: CGPoint(x: size.width, y: midY)
                    ),
                    lineWidth: 2.5
                )
            }
        }
    }
}

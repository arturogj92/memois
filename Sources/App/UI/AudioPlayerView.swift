import SwiftUI

private extension Color {
    static let brandCyan = Color(red: 0.0, green: 0.85, blue: 0.95)
    static let surfaceCard = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surfaceInput = Color(red: 0.14, green: 0.14, blue: 0.16)
}

struct AudioPlayerView: View {
    let audioURL: URL
    @StateObject private var player = AudioPlayerService()
    @State private var waveformSamples: [Float] = []
    @State private var isDragging = false
    @State private var dragFraction: Double = 0

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return isDragging ? dragFraction : player.currentTime / player.duration
    }

    var body: some View {
        VStack(spacing: 10) {
            // Waveform
            waveformView
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Controls
            HStack(spacing: 14) {
                // Play/Pause button
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(Color.brandCyan.opacity(0.25))
                        )
                }
                .buttonStyle(.plain)

                // Rewind 10s
                Button {
                    player.seek(to: player.currentTime - 10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                // Forward 10s
                Button {
                    player.seek(to: player.currentTime + 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Spacer()

                // Time display
                HStack(spacing: 4) {
                    Text(formatTime(player.currentTime))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("/")
                        .foregroundStyle(.white.opacity(0.3))
                    Text(formatTime(player.duration))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.surfaceCard)
        )
        .onAppear {
            player.load(url: audioURL)
            Task {
                waveformSamples = await WaveformExtractor.extract(from: audioURL)
            }
        }
        .onDisappear {
            player.stop()
        }
    }

    // MARK: - Waveform

    private var waveformView: some View {
        GeometryReader { geo in
            let barCount = waveformSamples.count
            guard barCount > 0 else {
                return AnyView(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.surfaceInput)
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                )
            }

            let barWidth: CGFloat = max(geo.size.width / CGFloat(barCount) * 0.7, 1.5)
            let spacing = geo.size.width / CGFloat(barCount)

            return AnyView(
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.surfaceInput)

                    // Waveform bars
                    Canvas { context, size in
                        let midY = size.height / 2

                        for (i, sample) in waveformSamples.enumerated() {
                            let x = CGFloat(i) * spacing + spacing / 2
                            let barHeight = max(CGFloat(sample) * (size.height * 0.85), 2)
                            let fraction = Double(i) / Double(max(barCount - 1, 1))
                            let played = fraction <= progress

                            let rect = CGRect(
                                x: x - barWidth / 2,
                                y: midY - barHeight / 2,
                                width: barWidth,
                                height: barHeight
                            )
                            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                            context.fill(
                                path,
                                with: .color(played ? Color.brandCyan : .white.opacity(0.2))
                            )
                        }
                    }

                    // Playhead line
                    Rectangle()
                        .fill(.white.opacity(0.6))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * progress)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            dragFraction = max(0, min(Double(value.location.x / geo.size.width), 1))
                        }
                        .onEnded { value in
                            let fraction = max(0, min(Double(value.location.x / geo.size.width), 1))
                            player.seek(fraction: fraction)
                            isDragging = false
                        }
                )
            )
        }
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = Int(max(time, 0))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

import SwiftUI

struct FloatingPanelView: View {
    @ObservedObject var model: AppModel

    private var isRecording: Bool {
        model.sessionState == .recording
    }

    private var symbolName: String {
        switch model.sessionState {
        case .idle:
            return "waveform"
        case .recording:
            return "mic.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var accentColor: Color {
        switch model.sessionState {
        case .recording:
            return Color(red: 1.0, green: 0.3, blue: 0.35)
        case .error:
            return .red
        default:
            return Color(red: 0.3, green: 0.95, blue: 0.4)
        }
    }

    private var formattedDuration: String {
        let hours = Int(model.recordingDuration) / 3600
        let minutes = (Int(model.recordingDuration) % 3600) / 60
        let seconds = Int(model.recordingDuration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isRecording {
                // Recording mode: big timer + audio capture indicator
                VStack(spacing: 12) {
                    // Pulsing record indicator + label
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .scaleEffect(isRecording ? 1.2 : 1.0)
                            .opacity(isRecording ? 0.5 : 1.0)
                            .animation(
                                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                value: isRecording
                            )
                        Text("RECORDING")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(.red.opacity(0.9))
                        Spacer()
                        Text(model.settings.shortcutDescription)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    // Big timer
                    Text(formattedDuration)
                        .font(.system(size: 36, weight: .light, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // Audio level visualizer - horizontal bar
                    AudioCaptureBar(level: model.audioLevel)
                        .frame(height: 6)

                    // Capture sources
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green.opacity(0.7))
                            Text("Mic")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.cyan.opacity(0.7))
                            Text("System Audio")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .padding(16)
            } else {
                // Idle mode
                HStack(spacing: 10) {
                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(accentColor.opacity(0.15)))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.statusMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(model.settings.shortcutDescription)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
            }
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
        )
        .padding(6)
    }
}

// Horizontal audio level bar with gradient
struct AudioCaptureBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.08))

                // Active level
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.3, green: 0.95, blue: 0.4),
                                Color(red: 0.0, green: 0.85, blue: 0.95),
                                Color(red: 1.0, green: 0.85, blue: 0.1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(max(0.02, level)))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }
}

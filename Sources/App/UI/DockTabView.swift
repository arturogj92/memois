import SwiftUI

struct DockTabView: View {
    @ObservedObject var model: AppModel
    var onStop: @MainActor () -> Void
    var onExpandChanged: @MainActor (Bool) -> Void

    @State private var isExpanded = false

    private var isRecording: Bool {
        model.sessionState == .recording
    }

    private var isError: Bool {
        if case .error = model.sessionState { return true }
        return false
    }

    private var errorMessage: String? {
        if case .error(let msg) = model.sessionState { return msg }
        return nil
    }

    private let darkPill = AnyShapeStyle(Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.97))

    private var pillFill: AnyShapeStyle {
        switch model.sessionState {
        case .error:
            return AnyShapeStyle(Color(red: 0.85, green: 0.15, blue: 0.15).opacity(0.95))
        default:
            return darkPill
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            pillView
        }
        .frame(width: 280, height: 240, alignment: .bottom)
        .onChange(of: isRecording) { _, recording in
            if !recording {
                isExpanded = false
                onExpandChanged(false)
            }
        }
    }

    private var formattedDuration: String {
        let minutes = Int(model.recordingDuration) / 60
        let seconds = Int(model.recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var pillView: some View {
        VStack(spacing: 0) {
            if isError {
                errorContent
            } else if isRecording && isExpanded {
                expandedContent
            } else if isRecording {
                compactRecordingContent
            } else {
                IdleWaveView()
            }
        }
        .padding(.horizontal, isExpanded ? 12 : (isError ? 10 : (isRecording ? 10 : 8)))
        .padding(.vertical, isExpanded ? 10 : 5)
        .background(
            RoundedRectangle(cornerRadius: isExpanded ? 14 : 8, style: .continuous)
                .fill(pillFill)
                .overlay(
                    RoundedRectangle(cornerRadius: isExpanded ? 14 : 8, style: .continuous)
                        .strokeBorder(
                            isRecording
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [
                                        Color(red: 0.0, green: 0.85, blue: 0.95),
                                        Color(red: 0.3, green: 0.95, blue: 0.4),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                  ))
                                : isError
                                    ? AnyShapeStyle(Color.white.opacity(0.2))
                                    : AnyShapeStyle(.white.opacity(0.1)),
                            lineWidth: isRecording ? 1 : 0.5
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        )
        .frame(maxWidth: isExpanded ? 260 : (isError ? 260 : nil))
        .contentShape(RoundedRectangle(cornerRadius: isExpanded ? 14 : 8))
        .onTapGesture {
            if isRecording && !isExpanded {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded = true
                }
                onExpandChanged(true)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isRecording)
        .animation(.easeInOut(duration: 0.3), value: isError)
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    // MARK: - Compact recording pill (dot + timer + screenshot + dual level dots)

    private var compactRecordingContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .scaleEffect(isRecording ? 1.3 : 1.0)
                .opacity(isRecording ? 0.6 : 1.0)
                .animation(
                    .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                    value: isRecording
                )
            Text(formattedDuration)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))

            // Screenshot button
            screenshotButton

            // Dual level indicators
            VStack(spacing: 2) {
                // Mic level dot
                Circle()
                    .fill(Color.green.opacity(Double(max(0.15, model.micLevel))))
                    .frame(width: 5, height: 5)
                // System level dot
                Circle()
                    .fill(Color.cyan.opacity(Double(max(0.15, model.systemLevel))))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(height: 18)
    }

    // MARK: - Screenshot button

    private var screenshotButton: some View {
        Button {
            model.captureScreenshot()
        } label: {
            ZStack {
                Image(systemName: "camera.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))

                if model.screenshotCount > 0 {
                    Text("\(model.screenshotCount)")
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.65, green: 0.55, blue: 0.98))
                        )
                        .offset(x: 8, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded: name field + screenshot + stop button

    private var expandedContent: some View {
        VStack(spacing: 8) {
            // Top row: dot + timer + screenshot + collapse arrow
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .scaleEffect(1.3)
                    .opacity(0.6)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isRecording
                    )
                Text(formattedDuration)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()

                // Screenshot button
                screenshotButton

                // Collapse chevron
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded = false
                    }
                    onExpandChanged(false)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            // Name field + stop button row
            HStack(spacing: 8) {
                TextField("Recording name...", text: $model.recordingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )

                // Stop button
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded = false
                    }
                    onExpandChanged(false)
                    onStop()
                } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.red)
                        .frame(width: 16, height: 16)
                        .padding(6)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Error content

    private var errorContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: 18)
    }

    private func barHeight(index: Int) -> CGFloat {
        let base: CGFloat = 3
        let maxH: CGFloat = 12
        let level = CGFloat(max(model.micLevel, model.systemLevel))
        let offsets: [CGFloat] = [0.3, 0.0, 0.6]
        let h = base + (maxH - base) * max(0.1, level + offsets[index] * level * 0.5)
        return min(maxH, h)
    }
}

struct IdleWaveView: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let midY = h / 2

            let points: [(CGFloat, CGFloat)] = [
                (0.00, 0.50),
                (0.12, 0.50),
                (0.20, 0.30),
                (0.28, 0.65),
                (0.36, 0.15),
                (0.44, 0.80),
                (0.52, 0.08),
                (0.60, 0.88),
                (0.68, 0.20),
                (0.76, 0.62),
                (0.84, 0.38),
                (0.92, 0.50),
                (1.00, 0.50),
            ]

            var path = Path()
            for (i, pt) in points.enumerated() {
                let p = CGPoint(x: pt.0 * w, y: pt.1 * h)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }

            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.0, green: 0.85, blue: 0.95),
                        Color(red: 0.3, green: 0.95, blue: 0.4),
                        Color(red: 1.0, green: 0.85, blue: 0.1),
                        Color(red: 1.0, green: 0.3, blue: 0.6),
                    ]),
                    startPoint: CGPoint(x: 0, y: midY),
                    endPoint: CGPoint(x: w, y: midY)
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 44, height: 16)
    }
}

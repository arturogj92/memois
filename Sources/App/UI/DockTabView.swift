import SwiftUI

struct DockTabView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var liveTranscription: LiveTranscriptionService
    var onStop: @MainActor () -> Void
    var onStartFromPreflight: @MainActor () -> Void
    var onCancelPreflight: @MainActor () -> Void
    var onExpandChanged: @MainActor (Bool) -> Void

    @State private var isExpanded = false
    @State private var availableDevices: [AudioDevice] = []
    @FocusState private var nameFocused: Bool

    private var isRecording: Bool {
        model.sessionState == .recording
    }

    private var isPreflight: Bool {
        model.sessionState == .preparing
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
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            pillView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isRecording) { _, recording in
            if !recording {
                isExpanded = false
                onExpandChanged(false)
            }
        }
        .onChange(of: isPreflight) { _, preflight in
            if preflight {
                refreshDevices()
                nameFocused = true
            }
        }
    }

    private func refreshDevices() {
        availableDevices = AudioDevice.inputDevices()
        if let uid = model.settings.selectedMicrophoneUID,
           !availableDevices.contains(where: { $0.uid == uid }) {
            model.settings.selectedMicrophoneUID = nil
        }
    }

    private var formattedDuration: String {
        let minutes = Int(model.recordingDuration) / 60
        let seconds = Int(model.recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var bigPill: Bool { isPreflight || (isRecording && isExpanded) }

    private var pillView: some View {
        VStack(spacing: 0) {
            if isError {
                errorContent
            } else if isPreflight {
                preflightContent
            } else if isRecording && isExpanded {
                expandedContent
            } else if isRecording {
                compactRecordingContent
            } else {
                IdleWaveView()
            }
        }
        .padding(.horizontal, bigPill ? 12 : (isError ? 10 : (isRecording ? 10 : 8)))
        .padding(.vertical, bigPill ? 10 : 5)
        .background(
            RoundedRectangle(cornerRadius: bigPill ? 14 : 8, style: .continuous)
                .fill(pillFill)
                .overlay(
                    RoundedRectangle(cornerRadius: bigPill ? 14 : 8, style: .continuous)
                        .strokeBorder(
                            (isRecording || isPreflight)
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
                            lineWidth: (isRecording || isPreflight) ? 1 : 0.5
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        )
        .frame(maxWidth: bigPill ? .infinity : (isError ? 260 : nil))
        .contentShape(RoundedRectangle(cornerRadius: bigPill ? 14 : 8))
        .onTapGesture {
            if isRecording && !isExpanded {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isExpanded = true
                }
                onExpandChanged(true)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isRecording)
        .animation(.easeInOut(duration: 0.3), value: isPreflight)
        .animation(.easeInOut(duration: 0.3), value: isError)
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }

    // MARK: - Preflight content (mic picker + level bars + name + Start/Cancel)

    private var preflightContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.3, green: 0.95, blue: 0.4))
                Text("Ready to record")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Text(model.settings.shortcutDescription)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Picker("", selection: Binding(
                get: { model.settings.selectedMicrophoneUID ?? "" },
                set: { model.changePreflightMic(uid: $0.isEmpty ? nil : $0) }
            )) {
                Text("System Default").tag("")
                ForEach(availableDevices) { d in
                    Text(d.name).tag(d.uid)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)

            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(model.micLevel > 0.05 ? .green : .green.opacity(0.3))
                        .frame(width: 12)
                    AudioCaptureBar(level: model.micLevel, color: .green)
                        .frame(height: 5)
                    Text("Mic")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 32, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(model.systemLevel > 0.05 ? .cyan : .cyan.opacity(0.3))
                        .frame(width: 12)
                    AudioCaptureBar(level: model.systemLevel, color: .cyan)
                        .frame(height: 5)
                    Text("System")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 32, alignment: .trailing)
                }
            }

            preflightCaptionsRow

            TextField("Recording name (optional)…", text: $model.recordingName)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                )
                .focused($nameFocused)
                .onSubmit { onStartFromPreflight() }

            HStack(spacing: 8) {
                Button { onCancelPreflight() } label: {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Button { onStartFromPreflight() } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 7, height: 7)
                        Text("Start Recording")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(red: 0.85, green: 0.18, blue: 0.22))
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 240)
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

            if settings.liveSubtitlesEnabled {
                liveBadge
            }

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

    private var liveBadge: some View {
        let isLive = liveTranscription.status == .live
        let isError: Bool = {
            if case .error = liveTranscription.status { return true }
            return false
        }()
        let dotColor: Color = isError ? .red : (isLive ? .green : .yellow)
        return HStack(spacing: 3) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text("CC")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.white.opacity(0.12)))
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

            // Live audio level bars (mic + system)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(model.micLevel > 0.05 ? .green : .green.opacity(0.3))
                        .frame(width: 12)
                    AudioCaptureBar(level: model.micLevel, color: .green)
                        .frame(height: 4)
                }
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(model.systemLevel > 0.05 ? .cyan : .cyan.opacity(0.3))
                        .frame(width: 12)
                    AudioCaptureBar(level: model.systemLevel, color: .cyan)
                        .frame(height: 4)
                }
            }

            captionsToggleRow

            if settings.liveSubtitlesEnabled {
                SubtitlesPanelView(service: liveTranscription, settings: settings)
                    .frame(maxHeight: .infinity)
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

    // MARK: - Live subtitles toggles

    private var preflightCaptionsRow: some View {
        Toggle(isOn: Binding(
            get: { settings.liveSubtitlesEnabled },
            set: { settings.liveSubtitlesEnabled = $0 }
        )) {
            HStack(spacing: 6) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(settings.liveSubtitlesEnabled ? Color.accentColor : .white.opacity(0.6))
                Text("Live subtitles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .toggleStyle(.switch)
        .tint(Color.accentColor)
        .controlSize(.small)
    }

    private var captionsToggleRow: some View {
        let on = settings.liveSubtitlesEnabled
        return Button {
            let willTurnOn = !on
            settings.liveSubtitlesEnabled = willTurnOn
            if willTurnOn && isRecording && !model.settings.assemblyAIKey.isEmpty {
                liveTranscription.start(apiKey: model.settings.assemblyAIKey)
            } else if !willTurnOn && isRecording {
                liveTranscription.stop()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 11, weight: .semibold))
                Text(on ? "Subtitles ON" : "Enable subtitles")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let lang = liveTranscription.detectedLanguage {
                    Text(lang.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
            }
            .foregroundStyle(on ? .white : .white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Color.accentColor : Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
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

import Sparkle
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Brand palette (from icon gradient)

private extension Color {
    static let brandCyan = Color(red: 0.0, green: 0.85, blue: 0.95)
    static let brandGreen = Color(red: 0.3, green: 0.95, blue: 0.4)
    static let brandYellow = Color(red: 1.0, green: 0.85, blue: 0.1)
    static let brandPink = Color(red: 1.0, green: 0.3, blue: 0.6)

    // Dark surface colors
    static let surfaceBase = Color(red: 0.07, green: 0.07, blue: 0.08)       // #121214 main bg
    static let surfaceSidebar = Color(red: 0.09, green: 0.09, blue: 0.10)    // #171719 sidebar
    static let surfaceCard = Color(red: 0.11, green: 0.11, blue: 0.13)       // #1c1c21 cards
    static let surfaceInput = Color(red: 0.14, green: 0.14, blue: 0.16)      // #242429 inputs
}

private let brandGradient = LinearGradient(
    colors: [.brandCyan, .brandGreen, .brandYellow, .brandPink],
    startPoint: .leading,
    endPoint: .trailing
)

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    let updater: SPUUpdater
    @State private var selectedTab: SidebarTab = .recordings
    @State private var isRecordingShortcut = false
    @State private var isRecordingScreenshotShortcut = false
    @State private var availableDevices: [AudioDevice] = []
    @State private var searchText = ""
    @State private var displayLimit = 10
    @State private var sidebarCollapsed = false
    @State private var isEditingAPIKey = false
    @State private var selectedRecording: Recording?
    @State private var editingNameID: UUID?
    @State private var editingNameText = ""
    @State private var sendingClaudeCodeID: UUID?

    private enum SidebarTab: String, CaseIterable, Identifiable {
        case recordings = "Recordings"
        case stats = "Usage"
        case settings = "Settings"
        case permissions = "Permissions"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .recordings: "waveform.circle"
            case .stats: "chart.bar"
            case .settings: "gearshape"
            case .permissions: "lock.shield"
            }
        }
    }

    private func refreshMicrophoneList() {
        availableDevices = AudioDevice.inputDevices()
        if let uid = settings.selectedMicrophoneUID,
           !availableDevices.contains(where: { $0.uid == uid }) {
            settings.selectedMicrophoneUID = nil
        }
    }

    private var maskedAPIKey: String {
        let key = settings.assemblyAIKey
        if key.count <= 8 { return String(repeating: "\u{2022}", count: key.count) }
        return key.prefix(4) + String(repeating: "\u{2022}", count: key.count - 8) + key.suffix(4)
    }

    private var filteredRecordings: [Recording] {
        if searchText.isEmpty { return model.recordings }
        return model.recordings.filter { recording in
            let dateStr = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
            if dateStr.localizedCaseInsensitiveContains(searchText) ||
                recording.transcriptionStatus.rawValue.localizedCaseInsensitiveContains(searchText) ||
                (recording.folderName ?? "").localizedCaseInsensitiveContains(searchText) ||
                (recording.name ?? "").localizedCaseInsensitiveContains(searchText) ||
                recording.formattedDuration.contains(searchText) {
                return true
            }
            // Search in transcript content
            if let text = model.readTranscript(for: recording) {
                return text.localizedCaseInsensitiveContains(searchText)
            }
            return false
        }
    }

    private var visibleRecordings: [Recording] {
        Array(filteredRecordings.prefix(displayLimit))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            contentArea
        }
        .frame(minWidth: 700, minHeight: 600)
        .background(Color.surfaceBase)
        .sheet(isPresented: $isRecordingShortcut) {
            ShortcutRecorderSheet(settings: settings, isPresented: $isRecordingShortcut)
        }
        .sheet(isPresented: $isRecordingScreenshotShortcut) {
            ShortcutRecorderSheet(
                title: "Record Screenshot Shortcut",
                currentDescription: settings.screenshotShortcutDescription,
                onSave: { keyCode, flags in settings.updateScreenshotShortcut(keyCode: keyCode, modifierFlags: flags) },
                onReset: { settings.resetScreenshotShortcutToDefault() },
                isPresented: $isRecordingScreenshotShortcut
            )
        }
        .sheet(item: $selectedRecording) { recording in
            RecordingDetailView(recording: recording, model: model)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Collapse toggle
            HStack {
                if !sidebarCollapsed {
                    Spacer()
                }
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        sidebarCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sidebarCollapsed ? "Expand" : "Collapse")
                if sidebarCollapsed {
                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            // App logo area — hidden when collapsed
            if !sidebarCollapsed {
                VStack(spacing: 5) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("Memois")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text(v)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .padding(.bottom, 16)
            }

            // Gradient line
            Rectangle()
                .fill(brandGradient)
                .frame(height: 1)
                .padding(.horizontal, sidebarCollapsed ? 10 : 20)
                .opacity(0.4)

            // Tabs
            VStack(spacing: 2) {
                ForEach(SidebarTab.allCases) { tab in
                    sidebarButton(tab)
                }
            }
            .padding(.horizontal, sidebarCollapsed ? 8 : 10)
            .padding(.top, 14)

            Spacer()

            // Status
            statusBar
        }
        .frame(width: sidebarCollapsed ? 54 : 200)
        .background(Color.surfaceSidebar)
    }

    @ViewBuilder
    private func sidebarButton(_ tab: SidebarTab) -> some View {
        let isSelected = selectedTab == tab

        Button {
            withAnimation(.easeInOut(duration: 0.12)) { selectedTab = tab }
        } label: {
            Group {
                if sidebarCollapsed {
                    Image(systemName: tab.icon)
                        .font(.system(size: 15))
                        .frame(width: 36, height: 34)
                        .help(tab.rawValue)
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12))
                            .frame(width: 18)
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        if tab == .recordings && !model.recordings.isEmpty {
                            Text("\(model.recordings.count)")
                                .font(.system(size: 10, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? .white.opacity(0.08) : .clear)
            )
            .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
        }
        .buttonStyle(.plain)
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                if !sidebarCollapsed {
                    Text(model.statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, sidebarCollapsed ? 0 : 14)
            .padding(.vertical, 10)
        }
    }

    private var statusColor: Color {
        switch model.sessionState {
        case .idle: .brandGreen
        case .recording: .brandYellow
        case .error: .brandPink
        }
    }

    // MARK: - Content Area

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch selectedTab {
                case .recordings: recordingsContent
                case .stats: statsContent
                case .settings: settingsContent
                case .permissions: permissionsContent
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceBase)
    }

    // MARK: - Recordings

    private var recordingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recordings")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                if !filteredRecordings.isEmpty {
                    Text("\(filteredRecordings.count)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Spacer()
                if !model.recordings.isEmpty {
                    Button("Clear All", role: .destructive) {
                        for recording in model.recordings {
                            model.deleteRecording(id: recording.id)
                        }
                    }
                    .controlSize(.small)
                }
            }

            // Actions
            HStack(spacing: 8) {
                Button {
                    model.handleShortcutPressed()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.sessionState == .recording ? "stop.fill" : "circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(model.sessionState == .recording ? .white : .red)
                        Text(model.sessionState == .recording ? "Stop" : "Record")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(model.sessionState == .recording ? Color.brandPink.opacity(0.3) : .white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)

                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio, .movie]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.message = "Select an audio file to import"
                    if panel.runModal() == .OK, let url = panel.url {
                        model.importAudio(from: url)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10))
                        Text("Import Audio")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)

                Spacer()
            }

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.surfaceCard)
            )
            .onChange(of: searchText) { displayLimit = 10 }

            if model.isSavingRecording {
                savingSkeletonRow()
            }

            if filteredRecordings.isEmpty && !model.isSavingRecording {
                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? "No recordings yet" : "No results")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
            } else if !filteredRecordings.isEmpty {
                LazyVStack(spacing: 8) {
                    ForEach(visibleRecordings) { recording in
                        recordingRow(recording)
                    }

                    if visibleRecordings.count < filteredRecordings.count {
                        Button {
                            displayLimit += 10
                        } label: {
                            Text("Show more (\(filteredRecordings.count - visibleRecordings.count))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recordingRow(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Recording name — editable inline
            HStack(spacing: 4) {
                if editingNameID == recording.id {
                    TextField("Recording name...", text: $editingNameText, onCommit: {
                        model.renameRecording(id: recording.id, name: editingNameText)
                        editingNameID = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.surfaceInput)
                    )

                    Button {
                        model.renameRecording(id: recording.id, name: editingNameText)
                        editingNameID = nil
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brandGreen)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(recording.name ?? recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(recording.name != nil ? 0.9 : 0.6))

                    Button {
                        editingNameText = recording.name ?? ""
                        editingNameID = recording.id
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                if recording.name != nil {
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                // Duration badge
                Text(recording.formattedDuration)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.08)))

                // Status badge
                statusBadge(for: recording.transcriptionStatus)
            }

            // Show error message if failed
            if recording.transcriptionStatus == .failed, let error = recording.transcriptionError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brandPink.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Progress bar for transcription in progress
            if recording.transcriptionStatus == .uploading || recording.transcriptionStatus == .processing {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.transcriptionStatus == .uploading ? "Uploading audio..." : "Transcribing...")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.brandCyan)
                }
            }

            HStack(spacing: 8) {
                // Show in Finder button
                Button {
                    model.showInFinder(recording: recording)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text("Finder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.06))
                )

                Spacer()

                if recording.needsRepair {
                    Button {
                        model.repairRecording(id: recording.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wrench")
                                .font(.system(size: 10))
                            Text("Repair")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.brandYellow.opacity(0.2))
                    )
                }

                if recording.transcriptionStatus == .none || recording.transcriptionStatus == .failed || recording.transcriptionStatus == .processing {
                    Button {
                        model.transcribe(recordingID: recording.id)
                    } label: {
                        Text(recording.transcriptionStatus == .processing ? "Retry" : "Transcribe")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.brandCyan.opacity(0.2))
                    )
                }

                if recording.transcriptionStatus == .completed {
                    Button {
                        if let text = model.buildCopyText(for: recording) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.brandYellow.opacity(0.15))
                    )

                    // Send to Claude Code
                    sendToClaudeCodeMenu(for: recording)

                    Button {
                        selectedRecording = recording
                    } label: {
                        Text("Open")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.brandGreen.opacity(0.2))
                    )
                }

                Button {
                    model.deleteRecording(id: recording.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.brandPink.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.surfaceCard)
        )
    }

    private func savingSkeletonRow() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .frame(width: 140, height: 14)

                Spacer()

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(width: 50, height: 12)
            }

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .frame(width: 100, height: 12)

                Spacer()

                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)

                Text("Saving…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.surfaceCard)
        )
        .opacity(0.7)
        .shimmering()
    }

    private func statusBadge(for status: Recording.TranscriptionStatus) -> some View {
        let (label, color): (String, Color) = {
            switch status {
            case .none: return ("Recorded", .brandYellow)
            case .uploading, .processing: return ("Transcribing", .brandCyan)
            case .completed: return ("Transcribed", .brandGreen)
            case .failed: return ("Failed", .brandPink)
            }
        }()

        return Text(label)
            .font(.system(size: 10, weight: .bold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(color.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    // MARK: - Stats

    private var statsContent: some View {
        let stats = model.transcriptionStats.stats

        return VStack(alignment: .leading, spacing: 20) {
            Text("Usage & Statistics")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))

            // Overview card
            card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Transcription Usage")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    HStack(spacing: 24) {
                        statItem(value: "\(stats.totalTranscriptions)", label: "Transcriptions")
                        statItem(value: stats.formattedTotalDuration, label: "Total Transcribed")
                        statItem(
                            value: stats.estimatedCostUSD < 50.0 ? "$0.00" : String(format: "$%.2f", stats.estimatedCostUSD - 50.0),
                            label: stats.estimatedCostUSD < 50.0 ? "Cost (Free Tier)" : "Cost (Paid)"
                        )
                    }

                    if let lastDate = stats.lastTranscriptionDate {
                        Divider().opacity(0.3)
                        HStack {
                            Text("Last transcription")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                            Spacer()
                            Text(lastDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }

            // Per-model breakdown
            if !stats.totalByModel.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By Model")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))

                        ForEach(stats.totalByModel.keys.sorted(), id: \.self) { model in
                            let count = stats.totalByModel[model] ?? 0
                            let duration = stats.formattedDuration(for: model)
                            let modelLabel = model == "best" ? "Universal-3 Pro" : model == "nano" ? "Nano" : model

                            HStack {
                                Circle()
                                    .fill(model == "best" ? Color.brandCyan : Color.brandYellow)
                                    .frame(width: 8, height: 8)
                                Text(modelLabel)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                Spacer()
                                Text("\(count) runs")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.4))
                                Text(duration)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                }
            }

            // Recording stats
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recordings")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    let totalRecorded = model.recordings.reduce(0.0) { $0 + $1.durationSeconds }
                    let transcribed = model.recordings.filter { $0.transcriptionStatus == .completed }.count
                    let pending = model.recordings.filter { $0.transcriptionStatus == .none }.count

                    HStack(spacing: 24) {
                        statItem(value: "\(model.recordings.count)", label: "Total")
                        statItem(value: formatRecordingDuration(totalRecorded), label: "Recorded")
                        statItem(value: "\(transcribed)", label: "Transcribed")
                        if pending > 0 {
                            statItem(value: "\(pending)", label: "Pending")
                        }
                    }
                }
            }

            // Free tier info
            card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "gift")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brandGreen)
                        Text("AssemblyAI Free Tier")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Text("$50 in free credits (~185 hours of transcription). No credit card required.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))

                    let usedPct = min(stats.estimatedCostUSD / 50.0, 1.0)
                    let remaining = max(50.0 - stats.estimatedCostUSD, 0)
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: usedPct)
                            .tint(usedPct < 0.8 ? Color.brandGreen : Color.brandPink)
                        HStack {
                            Text(String(format: "$%.2f remaining", remaining))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(remaining > 10 ? Color.brandGreen.opacity(0.8) : Color.brandPink.opacity(0.8))
                            Spacer()
                            Text(String(format: "$%.4f of $50.00 used", stats.estimatedCostUSD))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
            }
        }
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func formatRecordingDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        }
        return String(format: "%dm", minutes)
    }

    // MARK: - Settings

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            // General
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("General")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start at login")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("Launch Memois automatically when you log in")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.startAtLogin },
                            set: { settings.startAtLogin = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hide Dock icon")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("Only show in the menu bar")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.hideDockIcon },
                            set: { settings.hideDockIcon = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
            }

            // API Key
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AssemblyAI API Key")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    if settings.assemblyAIKey.isEmpty || isEditingAPIKey {
                        SecureField("Paste your AssemblyAI key", text: Binding(
                            get: { settings.assemblyAIKey },
                            set: { settings.assemblyAIKey = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.surfaceInput)
                        )

                        if isEditingAPIKey && !settings.assemblyAIKey.isEmpty {
                            HStack {
                                Spacer()
                                Button("Done") { isEditingAPIKey = false }
                                    .controlSize(.small)
                            }
                        }
                    } else {
                        HStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Text(maskedAPIKey)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.surfaceInput)
                            )

                            Button("Edit") { isEditingAPIKey = true }
                                .controlSize(.small)
                        }
                    }

                    Text("[Get a free API key at assemblyai.com](https://www.assemblyai.com/dashboard)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            // Shortcut
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recording Shortcut")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    HStack(spacing: 12) {
                        keycapRow(settings.shortcutDescription)
                        Spacer()
                        Button("Record") { isRecordingShortcut = true }
                        Button("Reset") { settings.resetShortcutToDefault() }
                    }
                }
            }

            // Screenshot Shortcut
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Screenshot Shortcut")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("Capture a screen region while recording")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                    HStack(spacing: 12) {
                        keycapRow(settings.screenshotShortcutDescription)
                        Spacer()
                        Button("Record") { isRecordingScreenshotShortcut = true }
                        Button("Reset") { settings.resetScreenshotShortcutToDefault() }
                    }
                }
            }

            // Microphone
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Microphone")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    HStack {
                        Picker("", selection: Binding(
                            get: { settings.selectedMicrophoneUID ?? "" },
                            set: { settings.selectedMicrophoneUID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("System Default").tag("")
                            ForEach(availableDevices) { d in
                                Text(d.name).tag(d.uid)
                            }
                        }
                        .labelsHidden()
                        Button("Refresh") { refreshMicrophoneList() }
                    }
                }
            }
            .onAppear { refreshMicrophoneList() }

            // Transcription
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcription")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    HStack {
                        Text("Model")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.transcriptionModel },
                            set: { settings.transcriptionModel = $0 }
                        )) {
                            ForEach(SettingsStore.availableModels, id: \.id) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }

                    Divider().opacity(0.3)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Speaker Diarization")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("Identify different speakers in the transcript")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.speakerDiarization },
                            set: { settings.speakerDiarization = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
            }

            // Claude Code Projects
            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Claude Code Projects")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Button {
                            addClaudeCodeProject()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 9))
                                Text("Add")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .controlSize(.small)
                    }

                    Text("Saved directories for sending transcripts to Claude Code")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.3))

                    if settings.claudeCodeProjects.isEmpty {
                        Text("No projects configured")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.2))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(settings.claudeCodeProjects) { project in
                            claudeCodeProjectRow(project)
                        }
                    }
                }
            }

            // Sounds
            card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Sound Effects")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.soundEffectsEnabled },
                            set: { settings.soundEffectsEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    if settings.soundEffectsEnabled {
                        Divider().opacity(0.3)

                        soundRow(
                            "Start recording",
                            selection: Binding(
                                get: { settings.startRecordingSound },
                                set: { settings.startRecordingSound = $0 }
                            )
                        )
                        soundRow(
                            "Stop recording",
                            selection: Binding(
                                get: { settings.stopRecordingSound },
                                set: { settings.stopRecordingSound = $0 }
                            )
                        )
                    }
                }
            }

            // Recording Indicator
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recording Indicator")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow free positioning")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("Drag the indicator anywhere on screen")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { settings.floatingPanelFreePosition },
                            set: { settings.floatingPanelFreePosition = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }

                    if settings.floatingPanelFreePosition && settings.floatingPanelX != nil {
                        HStack {
                            Spacer()
                            Button("Reset to default") {
                                settings.resetFloatingPanelPosition()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            // Updates
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Updates")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for updates")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("Download and install the latest version")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                        Button {
                            updater.checkForUpdates()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10))
                                Text("Check Now")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func soundRow(_ label: String, selection: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Picker("", selection: selection) {
                ForEach(SoundEffectPlayer.availableSounds, id: \.self) { s in
                    Text(s).tag(s)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Button {
                SoundEffectPlayer().preview(selection.wrappedValue)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.surfaceInput)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Preview")
        }
    }

    private func addClaudeCodeProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        if panel.runModal() == .OK, let url = panel.url {
            let name = url.lastPathComponent
            let project = ClaudeCodeProject(name: name, directoryPath: url.path)
            settings.claudeCodeProjects.append(project)
        }
    }

    private func claudeCodeProjectRow(_ project: ClaudeCodeProject) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(project.directoryPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                settings.claudeCodeProjects.removeAll { $0.id == project.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Send to Claude Code (from recording list)

    private func sendToClaudeCodeMenu(for recording: Recording) -> some View {
        let isSending = sendingClaudeCodeID == recording.id
        let wasSent = recording.claudeCodeSentAt != nil

        return Menu {
            if !settings.claudeCodeProjects.isEmpty {
                ForEach(settings.claudeCodeProjects) { project in
                    Button {
                        sendRecordingToClaudeCode(recording, directory: project.directoryPath, projectName: project.name)
                    } label: {
                        Label(project.name, systemImage: "folder")
                    }
                }
                Divider()
            }

            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.message = "Select directory for Claude Code"
                if panel.runModal() == .OK, let url = panel.url {
                    sendRecordingToClaudeCode(recording, directory: url.path, projectName: url.lastPathComponent)
                }
            } label: {
                Label("Choose Directory...", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                } else {
                    Image("ClaudeCode")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 10, height: 10)
                }
                Text(isSending ? "Sending..." : wasSent ? "Sent" : "Claude")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(wasSent ? Color.brandCyan.opacity(0.15) : .white.opacity(0.06))
        )
        .disabled(isSending)
        .help(wasSent ? "Sent to \(recording.claudeCodeProject ?? "Claude Code")" : "Send to Claude Code")
    }

    private func sendRecordingToClaudeCode(_ recording: Recording, directory: String, projectName: String) {
        guard sendingClaudeCodeID == nil else { return }
        sendingClaudeCodeID = recording.id

        // Build prompt
        let speakerNames = model.loadSpeakerNames(for: recording)
        let rawTranscript = model.readTranscript(for: recording) ?? ""
        let transcript = model.applyingSpeakerNames(speakerNames, to: rawTranscript)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let dateStr = dateFormatter.string(from: recording.createdAt)
        let recordingName = recording.name ?? "Untitled Recording"
        let speakerList = speakerNames.values.filter { !$0.isEmpty }.joined(separator: ", ")

        var prompt = "Here is the transcript from a meeting recorded on \(dateStr), titled '\(recordingName)'.\n\n"
        if !speakerList.isEmpty {
            prompt += "Speakers: \(speakerList)\n\n"
        }
        prompt += transcript

        let recordingId = recording.id

        Task.detached(priority: .userInitiated) {
            let paths = ["\(NSHomeDirectory())/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(NSHomeDirectory())/.claude/local/claude"]
            guard let execPath = paths.first(where: { FileManager.default.fileExists(atPath: $0) }),
                  FileManager.default.fileExists(atPath: directory) else {
                await MainActor.run { sendingClaudeCodeID = nil }
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = ["--dangerously-skip-permissions", "-p", prompt]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                await MainActor.run {
                    if process.terminationStatus == 0 {
                        model.saveClaudeCodeResponse(output, projectName: projectName, for: recordingId)
                    }
                    sendingClaudeCodeID = nil
                }
            } catch {
                await MainActor.run { sendingClaudeCodeID = nil }
            }
        }
    }

    // MARK: - Permissions

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Permissions")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Refresh") { model.refreshPermissions() }
                    .controlSize(.small)
            }

            card {
                VStack(spacing: 0) {
                    // Microphone
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.permissionStatus.microphoneGranted ? Color.brandGreen : Color.brandYellow)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Microphone")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(microphoneDetail)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                        if !model.permissionStatus.microphoneGranted {
                            if model.permissionStatus.microphoneStatus == .undetermined {
                                Button("Enable") { model.requestMicrophonePermission() }.controlSize(.small)
                            } else {
                                Button("Settings") { model.openMicrophoneSettings() }.controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Divider().opacity(0.2).padding(.vertical, 4)

                    // Screen Recording
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.permissionStatus.screenRecordingGranted ? Color.brandGreen : Color.brandYellow)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Screen Recording")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(model.permissionStatus.screenRecordingGranted ? "Granted" : "Required for system audio capture")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                        if !model.permissionStatus.screenRecordingGranted {
                            Button("Enable") { model.requestScreenRecordingPermission() }.controlSize(.small)
                            Button("Settings") { model.openScreenRecordingSettings() }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)

                    Divider().opacity(0.2).padding(.vertical, 4)

                    // Input Monitoring
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.permissionStatus.inputMonitoringGranted ? Color.brandGreen : Color.brandYellow)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Input Monitoring")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                            Text(model.permissionStatus.inputMonitoringGranted ? "Granted" : "Enable in System Settings")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                        Spacer()
                        if !model.permissionStatus.inputMonitoringGranted {
                            Button("Enable") { model.requestInputMonitoringPermission() }.controlSize(.small)
                            Button("Settings") { model.openInputMonitoringSettings() }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var microphoneDetail: String {
        switch model.permissionStatus.microphoneStatus {
        case .granted: "Granted"
        case .undetermined: "Click to allow"
        case .denied: "Denied -- open Settings"
        }
    }

    // MARK: - Keycap helpers

    /// Map key names to SF Symbol / glyph equivalents
    private static let keySymbols: [String: String] = [
        "Command": "\u{2318}",
        "Control": "\u{2303}",
        "Option": "\u{2325}",
        "Shift": "\u{21E7}",
        "Fn": "fn",
        "Return": "\u{21A9}",
        "Tab": "\u{21E5}",
        "Delete": "\u{232B}",
        "Escape": "\u{238B}",
        "Space": "\u{2423}",
        "Left Arrow": "\u{2190}",
        "Right Arrow": "\u{2192}",
        "Up Arrow": "\u{2191}",
        "Down Arrow": "\u{2193}",
        "ISO Section": "\u{00A7}",
    ]

    private func keycapRow(_ description: String) -> some View {
        let keys = description
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        return HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                keycap(key)
            }
        }
    }

    private func keycap(_ key: String) -> some View {
        let display = Self.keySymbols[key] ?? key
        let isSymbol = Self.keySymbols[key] != nil && key != "Fn"

        return Text(display)
            .font(.system(
                size: isSymbol ? 14 : 11,
                weight: .medium,
                design: isSymbol ? .default : .rounded
            ))
            .foregroundStyle(.white.opacity(0.8))
            .frame(minWidth: 28, minHeight: 26)
            .padding(.horizontal, isSymbol ? 4 : 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.surfaceInput)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.08), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
            )
            .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
    }

    // MARK: - Shared components

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.surfaceCard)
        )
    }
}

// MARK: - Shimmer effect

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.08), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase)
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 400
                }
            }
    }
}

extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}

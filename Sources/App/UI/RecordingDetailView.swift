import SwiftUI

private extension Color {
    static let surfaceBase = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surfaceCard = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surfaceInput = Color(red: 0.14, green: 0.14, blue: 0.16)
    static let brandCyan = Color(red: 0.0, green: 0.85, blue: 0.95)
}

struct RecordingDetailView: View {
    let recording: Recording
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlayerService()
    @State private var rawTranscript: String = ""
    @State private var speakerNames: [String: String] = [:]
    @State private var detectedSpeakers: [String] = []
    @State private var screenshots: [Screenshot] = []
    @State private var selectedScreenshot: Screenshot?
    @State private var utterances: [TranscriptUtterance] = []
    @State private var editingSpeakerNames: [String: String] = [:]
    @State private var searchText: String = ""
    @State private var searchMatchIndex: Int = 0
    @State private var showingSendToClaudeCode = false
    @State private var sendingToClaudeCode = false
    @State private var claudeCodeSent = false
    @State private var claudeCodeResponse = ""
    @State private var showingClaudeCodeResponse = false
    @State private var newProjectName = ""
    @State private var showingNewProjectForm = false

    private var hasUtterances: Bool { !utterances.isEmpty }

    private var displayTranscript: String {
        guard !rawTranscript.isEmpty else { return "" }
        return model.applyingSpeakerNames(speakerNames, to: rawTranscript)
    }

    private var copyText: String {
        model.buildCopyText(for: recording) ?? ""
    }

    /// Utterances filtered by search text
    private var filteredUtterances: [TranscriptUtterance] {
        guard !searchText.isEmpty else { return utterances }
        let query = searchText.lowercased()
        return utterances.filter { $0.text.lowercased().contains(query) }
    }

    /// Total search match count
    private var searchMatchCount: Int {
        filteredUtterances.count
    }

    /// The currently active utterance based on audio playback time
    private var activeUtteranceID: UUID? {
        let currentMs = Int(player.currentTime * 1000)
        return utterances.last(where: { $0.startMs <= currentMs })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording Transcript")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()

                if recording.transcriptionStatus == .completed {
                    sendToClaudeCodeButton
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            // Audio player (shared)
            AudioPlayerView(audioURL: recording.audioURL, player: player)

            // Speaker renaming section
            if !detectedSpeakers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speakers")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ], spacing: 8) {
                        ForEach(detectedSpeakers, id: \.self) { speaker in
                            HStack(spacing: 6) {
                                Text("\(speaker)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(width: 14)

                                TextField("Name", text: Binding(
                                    get: { editingSpeakerNames[speaker] ?? "" },
                                    set: { editingSpeakerNames[speaker] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .onSubmit {
                                    commitSpeakerNames()
                                }
                            }
                        }
                    }
                    .onDisappear {
                        commitSpeakerNames()
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.surfaceCard)
                )
            }

            // Search bar
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                    TextField("Search transcript...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchMatchIndex = 0
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.surfaceInput)
                )

                if !searchText.isEmpty {
                    Text("\(searchMatchCount) match\(searchMatchCount == 1 ? "" : "es")")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))

                    if searchMatchCount > 1 {
                        Button {
                            searchMatchIndex = (searchMatchIndex - 1 + searchMatchCount) % searchMatchCount
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)

                        Button {
                            searchMatchIndex = (searchMatchIndex + 1) % searchMatchCount
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Transcript content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if hasUtterances {
                            // Structured utterance view with timestamps
                            ForEach(utterancesForDisplay) { utterance in
                                utteranceRow(utterance, isCurrentMatch: isCurrentSearchMatch(utterance))
                                    .id(utterance.id)
                            }
                        } else {
                            // Fallback: plain text (legacy recordings without utterance data)
                            Text(displayTranscript.isEmpty ? "No transcript available" : displayTranscript)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundStyle(displayTranscript.isEmpty ? .white.opacity(0.3) : .white.opacity(0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Screenshots section
                        if !screenshots.isEmpty {
                            Divider()
                                .background(Color.white.opacity(0.1))
                                .padding(.vertical, 8)

                            Text("Screenshots (\(screenshots.count))")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))

                            LazyVGrid(columns: [
                                GridItem(.adaptive(minimum: 120), spacing: 10),
                            ], spacing: 10) {
                                ForEach(screenshots) { screenshot in
                                    screenshotThumbnail(screenshot)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.surfaceCard)
                    )
                }
                .onChange(of: searchText) { _, _ in
                    searchMatchIndex = 0
                    scrollToCurrentMatch(proxy: proxy)
                }
                .onChange(of: searchMatchIndex) { _, _ in
                    scrollToCurrentMatch(proxy: proxy)
                }
            }

            // Actions
            HStack(spacing: 12) {
                Spacer()

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(copyText, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .disabled(displayTranscript.isEmpty && screenshots.isEmpty)

                Button {
                    if let url = recording.transcriptionURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("Open in Finder")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .disabled(recording.transcriptionURL == nil)
            }
        }
        .padding(24)
        .frame(width: 600, height: 700)
        .background(Color.surfaceBase)
        .task {
            let rec = recording
            let loadedTranscript = await Task.detached(priority: .userInitiated) {
                (try? String(contentsOf: rec.transcriptionURL ?? rec.folderURL, encoding: .utf8)) ?? ""
            }.value
            let loadedUtterances = await Task.detached(priority: .userInitiated) {
                let url = rec.utterancesURL
                guard let data = try? Data(contentsOf: url),
                      let u = try? JSONDecoder().decode([TranscriptUtterance].self, from: data) else { return [TranscriptUtterance]() }
                return u
            }.value

            rawTranscript = loadedTranscript
            speakerNames = model.loadSpeakerNames(for: recording)
            editingSpeakerNames = speakerNames
            detectedSpeakers = extractSpeakers(from: loadedTranscript)
            screenshots = model.loadScreenshots(for: recording)
            utterances = loadedUtterances
            // Load persisted Claude Code response
            if let savedResponse = model.loadClaudeCodeResponse(for: recording) {
                claudeCodeResponse = savedResponse
                claudeCodeSent = true
            }
        }
        .sheet(item: $selectedScreenshot) { screenshot in
            ScreenshotPreviewView(
                image: NSImage(contentsOf: recording.screenshotURL(for: screenshot)),
                timestamp: screenshot.formattedTimestamp
            )
        }
    }

    // MARK: - Speaker Names

    private func commitSpeakerNames() {
        guard editingSpeakerNames != speakerNames else { return }
        speakerNames = editingSpeakerNames
        model.saveSpeakerNames(speakerNames, for: recording)
    }

    // MARK: - Utterances

    /// Which utterances to show (filtered if searching, all otherwise)
    private var utterancesForDisplay: [TranscriptUtterance] {
        if searchText.isEmpty {
            return utterances
        }
        return filteredUtterances
    }

    private func isCurrentSearchMatch(_ utterance: TranscriptUtterance) -> Bool {
        guard !searchText.isEmpty, searchMatchIndex < filteredUtterances.count else { return false }
        return filteredUtterances[searchMatchIndex].id == utterance.id
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard !searchText.isEmpty, searchMatchIndex < filteredUtterances.count else { return }
        let targetID = filteredUtterances[searchMatchIndex].id
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }

    private func speakerDisplayName(_ speaker: String) -> String {
        if let name = speakerNames[speaker], !name.isEmpty {
            return name
        }
        return "Speaker \(speaker)"
    }

    private func utteranceRow(_ utterance: TranscriptUtterance, isCurrentMatch: Bool) -> some View {
        let isActive = activeUtteranceID == utterance.id && player.isPlaying
        let matchesSearch = !searchText.isEmpty && utterance.text.lowercased().contains(searchText.lowercased())

        return Button {
            player.seek(to: utterance.startSeconds)
            if !player.isPlaying {
                player.play()
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // Timestamp
                Text(utterance.formattedStart)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isActive ? Color.brandCyan : .white.opacity(0.35))
                    .frame(width: 36, alignment: .trailing)

                // Speaker + text
                VStack(alignment: .leading, spacing: 2) {
                    Text(speakerDisplayName(utterance.speaker))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? Color.brandCyan : .white.opacity(0.5))

                    if matchesSearch {
                        highlightedText(utterance.text, query: searchText)
                    } else {
                        Text(utterance.text)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isCurrentMatch ? Color.brandCyan.opacity(0.15) :
                        isActive ? Color.brandCyan.opacity(0.08) :
                        Color.clear
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// Highlights search matches in yellow within the text using AttributedString
    private func highlightedText(_ text: String, query: String) -> some View {
        var attributed = AttributedString(text)
        attributed.foregroundColor = .white.opacity(0.85)
        attributed.font = .system(size: 13, weight: .regular, design: .rounded)

        let lower = text.lowercased()
        let queryLower = query.lowercased()
        var searchStart = lower.startIndex

        while let range = lower.range(of: queryLower, range: searchStart..<lower.endIndex) {
            let attrRange = AttributedString.Index(range.lowerBound, within: attributed)!
                ..< AttributedString.Index(range.upperBound, within: attributed)!
            attributed[attrRange].foregroundColor = .black
            attributed[attrRange].backgroundColor = .yellow.opacity(0.8)
            searchStart = range.upperBound
        }

        return Text(attributed)
            .textSelection(.enabled)
    }

    // MARK: - Screenshots

    private func screenshotThumbnail(_ screenshot: Screenshot) -> some View {
        let url = recording.screenshotURL(for: screenshot)
        return Button {
            selectedScreenshot = screenshot
        } label: {
            VStack(spacing: 4) {
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 80)
                        .cornerRadius(6)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 80)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundStyle(.white.opacity(0.2))
                        )
                }

                HStack(spacing: 3) {
                    Image(systemName: "clock")
                        .font(.system(size: 8))
                    Text(screenshot.formattedTimestamp)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Send to Claude Code

    /// The default target directory: first saved project, or nil
    private var defaultSendDirectory: String? {
        model.settings.claudeCodeProjects.first?.directoryPath
    }

    private var sendToClaudeCodeButton: some View {
        HStack(spacing: 0) {
            // Main button: sends directly to first project (or opens picker if none)
            Button {
                if let dir = defaultSendDirectory {
                    sendToClaudeCode(directory: dir)
                } else {
                    // No projects saved - open folder picker
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Select directory for Claude Code"
                    if panel.runModal() == .OK, let url = panel.url {
                        sendToClaudeCode(directory: url.path)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if sendingToClaudeCode {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else if claudeCodeSent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                    } else {
                        Image("ClaudeCode")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    if let project = model.settings.claudeCodeProjects.first, !sendingToClaudeCode && !claudeCodeSent {
                        Text("Send to \(project.name)")
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Text(sendingToClaudeCode ? "Sending..." : claudeCodeSent ? "Sent" : "Send to Claude Code")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(claudeCodeSent ? Color.brandCyan : .white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(claudeCodeSent ? Color.brandCyan.opacity(0.15) : .white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(sendingToClaudeCode)

            // Dropdown arrow: choose different project
            Menu {
                if !model.settings.claudeCodeProjects.isEmpty {
                    Section("Saved Projects") {
                        ForEach(model.settings.claudeCodeProjects) { project in
                            Button {
                                sendToClaudeCode(directory: project.directoryPath)
                            } label: {
                                Label(project.name, systemImage: "terminal")
                            }
                        }
                    }
                }

                Section {
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Select directory for Claude Code"
                        if panel.runModal() == .OK, let url = panel.url {
                            sendToClaudeCode(directory: url.path)
                        }
                    } label: {
                        Label("Choose Directory...", systemImage: "folder")
                    }

                    Button {
                        showingNewProjectForm = true
                    } label: {
                        Label("New Project...", systemImage: "plus")
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(sendingToClaudeCode)

            // View Response button
            if !sendingToClaudeCode && !claudeCodeResponse.isEmpty {
                Button {
                    showingClaudeCodeResponse = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.system(size: 11))
                        Text("View Response")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.brandCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.brandCyan.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
            }
        }
        .sheet(isPresented: $showingNewProjectForm) {
            newProjectSheet
        }
        .sheet(isPresented: $showingClaudeCodeResponse) {
            claudeCodeResponseSheet
        }
    }

    private var claudeCodeResponseSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image("ClaudeCode")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text("Claude Code Response")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(claudeCodeResponse, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .controlSize(.small)

                Button("Close") { showingClaudeCodeResponse = false }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(claudeCodeResponse)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.surfaceCard)
            )
        }
        .padding(20)
        .frame(width: 700, height: 500)
        .background(Color.surfaceBase)
    }

    private var newProjectSheet: some View {
        VStack(spacing: 16) {
            Text("New Claude Code Project")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            TextField("Project name", text: $newProjectName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button("Cancel") {
                    showingNewProjectForm = false
                    newProjectName = ""
                }

                Button("Choose Directory & Create") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Select directory for '\(newProjectName)'"
                    if panel.runModal() == .OK, let url = panel.url {
                        let name = newProjectName.trimmingCharacters(in: .whitespaces).isEmpty
                            ? url.lastPathComponent
                            : newProjectName.trimmingCharacters(in: .whitespaces)
                        let project = ClaudeCodeProject(name: name, directoryPath: url.path)
                        model.settings.claudeCodeProjects.append(project)
                        showingNewProjectForm = false
                        newProjectName = ""
                        sendToClaudeCode(directory: url.path)
                    }
                }
                .disabled(false)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Color.surfaceBase)
    }

    private func sendToClaudeCode(directory: String) {
        guard !sendingToClaudeCode else { return }
        sendingToClaudeCode = true
        claudeCodeSent = false
        claudeCodeResponse = ""

        let projectName = model.settings.claudeCodeProjects.first(where: { $0.directoryPath == directory })?.name ?? URL(fileURLWithPath: directory).lastPathComponent
        let transcript = buildClaudeCodePrompt()
        let recordingId = recording.id
        Self.log("Send to Claude Code: directory=\(directory), prompt length=\(transcript.count)")

        Task.detached(priority: .userInitiated) {
            let (success, output) = await Self.runClaudeCode(prompt: transcript, directory: directory)
            Self.log("Claude Code result: success=\(success), output length=\(output.count)")
            if !success {
                Self.log("Claude Code error: \(output.prefix(1000))")
            } else {
                Self.log("Claude Code response: \(output.prefix(500))")
            }
            await MainActor.run {
                sendingToClaudeCode = false
                claudeCodeSent = success
                let response = output.isEmpty && !success ? "Error: Claude Code failed. Check that the directory exists and claude is installed." : output
                claudeCodeResponse = response
                if success {
                    model.saveClaudeCodeResponse(response, projectName: projectName, for: recordingId)
                }
            }
        }
    }

    private func buildClaudeCodePrompt() -> String {
        let applied = model.applyingSpeakerNames(speakerNames, to: rawTranscript)

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
        prompt += applied
        return prompt
    }

    private static func log(_ message: String) {
        let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Memois/claude_code_log.txt")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private static func runClaudeCode(prompt: String, directory: String) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let paths = ["\(NSHomeDirectory())/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(NSHomeDirectory())/.claude/local/claude"]
                guard let execPath = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                    log("ERROR: Claude binary not found. Searched: \(paths)")
                    continuation.resume(returning: (false, "Claude Code binary not found. Searched:\n\(paths.joined(separator: "\n"))"))
                    return
                }
                log("Found claude at: \(execPath)")

                guard FileManager.default.fileExists(atPath: directory) else {
                    log("ERROR: Directory not found: \(directory)")
                    continuation.resume(returning: (false, "Directory not found: \(directory)"))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = ["--dangerously-skip-permissions", "-p", prompt]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                log("Launching: \(execPath) --dangerously-skip-permissions -p <prompt(\(prompt.count) chars)> in \(directory)")

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                do {
                    try process.run()
                    log("Process launched, PID=\(process.processIdentifier). Waiting...")
                    // Read output before waitUntilExit to avoid pipe buffer deadlock
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    log("Process exited: status=\(process.terminationStatus), output bytes=\(data.count)")
                    continuation.resume(returning: (process.terminationStatus == 0, output))
                } catch {
                    log("ERROR launching process: \(error)")
                    continuation.resume(returning: (false, "Failed to launch: \(error.localizedDescription)"))
                }
            }
        }
    }

    // MARK: - Helpers

    private func extractSpeakers(from text: String) -> [String] {
        let pattern = #"Speaker ([A-Z]):"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            let speaker = nsString.substring(with: match.range(at: 1))
            if seen.insert(speaker).inserted {
                result.append(speaker)
            }
        }
        return result
    }
}

/// Preview sheet for viewing a screenshot at full size
struct ScreenshotPreviewView: View {
    let image: NSImage?
    let timestamp: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Screenshot at \(timestamp)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(8)
            } else {
                Text("Image not found")
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 300)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }
}

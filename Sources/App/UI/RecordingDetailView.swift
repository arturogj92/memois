import SwiftUI

private extension Color {
    static let surfaceBase = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surfaceCard = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surfaceInput = Color(red: 0.14, green: 0.14, blue: 0.16)
    static let brandCyan = Color(red: 0.0, green: 0.85, blue: 0.95)
    static let brandGreen = Color(red: 0.3, green: 0.95, blue: 0.4)
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
    @State private var sendingAgents: Set<HeadlessCodingAgent> = []
    @State private var sentAgents: Set<HeadlessCodingAgent> = []
    @State private var agentResponses: [HeadlessCodingAgent: String] = [:]
    @State private var responseAgent: HeadlessCodingAgent?
    @State private var newProjectName = ""
    @State private var newProjectAgent: HeadlessCodingAgent?
    @State private var filterBySpeaker: String?
    @State private var pendingSendRequest: PendingSendRequest?
    @State private var extraPromptText: String = ""

    struct PendingSendRequest: Identifiable {
        let id = UUID()
        let agent: HeadlessCodingAgent
        let project: HeadlessCodingProject?
        let directory: String?

        var targetName: String {
            if let project { return project.name }
            if let directory { return URL(fileURLWithPath: directory).lastPathComponent }
            return ""
        }
    }

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
                    HStack(spacing: 8) {
                        ForEach(HeadlessCodingAgent.allCases) { agent in
                            sendToAgentButton(agent)
                        }
                    }
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 16, height: 16)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Close transcript")
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
                                Button {
                                    if filterBySpeaker == speaker {
                                        filterBySpeaker = nil
                                    } else {
                                        filterBySpeaker = speaker
                                    }
                                } label: {
                                    Text("\(speaker)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(filterBySpeaker == speaker ? Color.brandCyan : .white.opacity(0.4))
                                        .frame(width: 14)
                                }
                                .buttonStyle(.plain)
                                .help("Filter by this speaker")

                                TextField("Name", text: Binding(
                                    get: { editingSpeakerNames[speaker] ?? "" },
                                    set: { newValue in
                                        editingSpeakerNames[speaker] = newValue
                                        speakerNames[speaker] = newValue
                                        model.saveSpeakerNames(speakerNames, for: recording)
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            }
                        }
                    }

                    if filterBySpeaker != nil {
                        Button {
                            filterBySpeaker = nil
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                Text("Clear filter")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.brandCyan.opacity(0.7))
                        }
                        .buttonStyle(.plain)
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
            for agent in HeadlessCodingAgent.allCases {
                if let savedResponse = model.loadHeadlessCodingResponse(for: recording, agent: agent) {
                    agentResponses[agent] = savedResponse
                    sentAgents.insert(agent)
                }
            }
        }
        .sheet(item: $selectedScreenshot) { screenshot in
            ScreenshotPreviewView(
                image: NSImage(contentsOf: recording.screenshotURL(for: screenshot)),
                timestamp: screenshot.formattedTimestamp
            )
        }
        .sheet(item: $responseAgent) { agent in
            responseSheet(for: agent)
        }
        .sheet(item: $newProjectAgent) { agent in
            newProjectSheet(for: agent)
        }
        .sheet(item: $pendingSendRequest) { request in
            extraPromptSheet(for: request)
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
        var result = utterances
        if let speaker = filterBySpeaker {
            result = result.filter { $0.speaker == speaker }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.text.lowercased().contains(query) }
        }
        return result
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

    // MARK: - Send To Agent

    private func sendToAgentButton(_ agent: HeadlessCodingAgent) -> some View {
        let isSending = sendingAgents.contains(agent)
        let wasSent = sentAgents.contains(agent)
        let response = agentResponses[agent] ?? ""
        let projectName = recording.projectName(for: agent) ?? agent.displayName

        return HStack(spacing: 0) {
            Menu {
                let projects = model.settings.projects(for: agent)

                if !projects.isEmpty {
                    ForEach(projects) { project in
                        Button {
                            requestSend(agent: agent, project: project, directory: nil)
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
                    panel.message = agent.chooseDirectoryMessage
                    if panel.runModal() == .OK, let url = panel.url {
                        requestSend(agent: agent, project: nil, directory: url.path)
                    }
                } label: {
                    Label("Choose Directory...", systemImage: "folder.badge.plus")
                }

                Button {
                    newProjectAgent = agent
                } label: {
                    Label("New Project...", systemImage: "plus")
                }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    agentIcon(agent, size: 16)
                        .opacity(isSending ? 0.35 : 1)

                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }

                    if wasSent {
                        Circle()
                            .fill(Color.brandGreen)
                            .frame(width: 11, height: 11)
                            .overlay {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundStyle(Color.surfaceBase)
                            }
                            .offset(x: 4, y: 4)
                    }
                }
                .frame(width: 16, height: 16)
                .foregroundStyle(wasSent ? Color.brandCyan : .white.opacity(0.8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(wasSent ? Color.brandCyan.opacity(0.15) : .white.opacity(0.08))
            )
            .disabled(isSending)
            .help(
                isSending
                    ? "Sending to \(agent.displayName)"
                    : wasSent
                        ? "Sent to \(projectName)"
                        : agent.buttonTitle
            )

            if !isSending && !response.isEmpty {
                Button {
                    responseAgent = agent
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16, height: 16)
                    .foregroundStyle(Color.brandCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.brandCyan.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("View \(agent.responseTitle)")
                .padding(.leading, 6)
            }
        }
    }

    private func agentIcon(_ agent: HeadlessCodingAgent, size: CGFloat) -> some View {
        Group {
            if let image = resizedAgentIcon(agent, size: size) {
                Image(nsImage: image)
                    .interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    private func resizedAgentIcon(_ agent: HeadlessCodingAgent, size: CGFloat) -> NSImage? {
        guard let sourceImage = NSImage(named: agent.iconAssetName) else { return nil }

        let targetSize = NSSize(width: size, height: size)
        let renderedImage = NSImage(size: targetSize)
        renderedImage.lockFocus()
        sourceImage.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceImage.size),
            operation: .copy,
            fraction: 1
        )
        renderedImage.unlockFocus()
        renderedImage.isTemplate = false
        return renderedImage
    }

    private func responseSheet(for agent: HeadlessCodingAgent) -> some View {
        let response = agentResponses[agent] ?? ""

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(agent.iconAssetName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text(agent.responseTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(response, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .controlSize(.small)

                Button("Close") { responseAgent = nil }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(response)
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

    private func newProjectSheet(for agent: HeadlessCodingAgent) -> some View {
        VStack(spacing: 16) {
            Text(agent.newProjectTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            TextField("Project name", text: $newProjectName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 12) {
                Button("Cancel") {
                    newProjectAgent = nil
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
                        let project = HeadlessCodingProject(name: name, directoryPath: url.path)
                        model.settings.addProject(project, for: agent)
                        newProjectAgent = nil
                        newProjectName = ""
                        requestSend(agent: agent, project: project, directory: nil)
                    }
                }
                .disabled(false)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(Color.surfaceBase)
    }

    private func requestSend(
        agent: HeadlessCodingAgent,
        project: HeadlessCodingProject?,
        directory: String?
    ) {
        extraPromptText = ""
        pendingSendRequest = PendingSendRequest(agent: agent, project: project, directory: directory)
    }

    private func extraPromptSheet(for request: PendingSendRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                agentIcon(request.agent, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to \(request.agent.displayName)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(request.targetName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Extra context (optional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text("Anything specific the agent should keep in mind for this transcript?")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))

                TextEditor(text: $extraPromptText)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.surfaceInput)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    pendingSendRequest = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Send") {
                    let extras = extraPromptText
                    let req = request
                    pendingSendRequest = nil
                    sendToAgent(
                        req.agent,
                        project: req.project,
                        directory: req.directory,
                        extraInstructions: extras
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Color.surfaceBase)
    }

    private func sendToAgent(
        _ agent: HeadlessCodingAgent,
        project: HeadlessCodingProject? = nil,
        directory: String? = nil,
        extraInstructions: String = ""
    ) {
        guard !sendingAgents.contains(agent) else { return }
        sendingAgents.insert(agent)
        sentAgents.remove(agent)
        agentResponses[agent] = ""

        let targetDirectory = project?.directoryPath ?? directory ?? ""
        guard !targetDirectory.isEmpty else {
            sendingAgents.remove(agent)
            agentResponses[agent] = "Error: Missing target directory."
            return
        }

        let projectName = project?.name ?? URL(fileURLWithPath: targetDirectory).lastPathComponent
        let transcript = model.buildHeadlessCodingPrompt(for: recording, project: project, extraInstructions: extraInstructions)
        let recordingId = recording.id
        let executablePathOverride = model.settings.executablePathOverride(for: agent)
        HeadlessCodingAgentRunner.log(
            "Send to \(agent.displayName): directory=\(targetDirectory), prompt length=\(transcript.count)",
            agent: agent
        )

        Task.detached(priority: .userInitiated) {
            let (success, output) = await HeadlessCodingAgentRunner.run(
                agent,
                prompt: transcript,
                directory: targetDirectory,
                executablePathOverride: executablePathOverride
            )
            HeadlessCodingAgentRunner.log(
                "\(agent.displayName) result: success=\(success), output length=\(output.count)",
                agent: agent
            )
            if !success {
                HeadlessCodingAgentRunner.log("\(agent.displayName) error: \(output.prefix(1000))", agent: agent)
            } else {
                HeadlessCodingAgentRunner.log("\(agent.displayName) response: \(output.prefix(500))", agent: agent)
            }
            await MainActor.run {
                sendingAgents.remove(agent)
                if success {
                    sentAgents.insert(agent)
                }
                let response = output.isEmpty && !success
                    ? "Error: \(agent.displayName) failed. \(agent.installHint)"
                    : output
                agentResponses[agent] = response
                if success {
                    model.saveHeadlessCodingResponse(response, projectName: projectName, for: recordingId, agent: agent)
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

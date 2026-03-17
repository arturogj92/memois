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
    @State private var searchText: String = ""
    @State private var searchMatchIndex: Int = 0

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
                                    get: { speakerNames[speaker] ?? "" },
                                    set: { newValue in
                                        speakerNames[speaker] = newValue
                                        model.saveSpeakerNames(speakerNames, for: recording)
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            }
                        }
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
                    VStack(alignment: .leading, spacing: 4) {
                        if hasUtterances {
                            // Structured utterance view with timestamps
                            ForEach(Array(utterancesForDisplay.enumerated()), id: \.element.id) { index, utterance in
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
        .onAppear {
            rawTranscript = model.readTranscript(for: recording) ?? ""
            speakerNames = model.loadSpeakerNames(for: recording)
            detectedSpeakers = extractSpeakers(from: rawTranscript)
            screenshots = model.loadScreenshots(for: recording)
            utterances = model.loadUtterances(for: recording)
        }
        .sheet(item: $selectedScreenshot) { screenshot in
            ScreenshotPreviewView(
                image: NSImage(contentsOf: recording.screenshotURL(for: screenshot)),
                timestamp: screenshot.formattedTimestamp
            )
        }
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

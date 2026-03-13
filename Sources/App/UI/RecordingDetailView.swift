import SwiftUI

private extension Color {
    static let surfaceBase = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surfaceCard = Color(red: 0.11, green: 0.11, blue: 0.13)
}

struct RecordingDetailView: View {
    let recording: Recording
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rawTranscript: String = ""
    @State private var speakerNames: [String: String] = [:]
    @State private var detectedSpeakers: [String] = []

    private var displayTranscript: String {
        guard !rawTranscript.isEmpty else { return "" }
        return model.applyingSpeakerNames(speakerNames, to: rawTranscript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            // Transcript content
            ScrollView {
                Text(displayTranscript.isEmpty ? "No transcript available" : displayTranscript)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(displayTranscript.isEmpty ? .white.opacity(0.3) : .white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.surfaceCard)
                    )
            }

            // Actions
            HStack(spacing: 12) {
                Spacer()

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(displayTranscript, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .disabled(displayTranscript.isEmpty)

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
        .frame(width: 560, height: 520)
        .background(Color.surfaceBase)
        .onAppear {
            rawTranscript = model.readTranscript(for: recording) ?? ""
            speakerNames = model.loadSpeakerNames(for: recording)
            detectedSpeakers = extractSpeakers(from: rawTranscript)
        }
    }

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

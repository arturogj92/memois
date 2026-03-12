import SwiftUI

private extension Color {
    static let surfaceBase = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surfaceCard = Color(red: 0.11, green: 0.11, blue: 0.13)
}

struct RecordingDetailView: View {
    let recording: Recording
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var transcriptText: String = ""

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

            // Transcript content
            ScrollView {
                Text(transcriptText.isEmpty ? "No transcript available" : transcriptText)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(transcriptText.isEmpty ? .white.opacity(0.3) : .white.opacity(0.85))
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
                    pasteboard.setString(transcriptText, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .disabled(transcriptText.isEmpty)

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
        .frame(width: 560, height: 480)
        .background(Color.surfaceBase)
        .onAppear {
            transcriptText = model.readTranscript(for: recording) ?? ""
        }
    }
}

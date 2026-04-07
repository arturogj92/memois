import Foundation

struct HeadlessCodingProject: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var directoryPath: String
    var customPrompt: String?

    init(id: UUID = UUID(), name: String, directoryPath: String, customPrompt: String? = nil) {
        self.id = id
        self.name = name
        self.directoryPath = directoryPath
        self.customPrompt = customPrompt
    }
}

typealias ClaudeCodeProject = HeadlessCodingProject
typealias CodexProject = HeadlessCodingProject

enum HeadlessCodingAgent: String, CaseIterable, Identifiable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var shortLabel: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        }
    }

    var buttonTitle: String {
        "Send to \(displayName)"
    }

    var iconAssetName: String {
        switch self {
        case .claudeCode: "ClaudeCode"
        case .codex: "Codex"
        }
    }

    var projectSettingsTitle: String {
        "\(displayName) Projects"
    }

    var projectSettingsDescription: String {
        "Saved directories and prompt templates for sending transcripts to \(displayName)"
    }

    var responseTitle: String {
        "\(displayName) Response"
    }

    var newProjectTitle: String {
        "New \(displayName) Project"
    }

    var chooseDirectoryMessage: String {
        "Select directory for \(displayName)"
    }

    var executableName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    var responseFileName: String {
        switch self {
        case .claudeCode: "claude_code_response.txt"
        case .codex: "codex_response.txt"
        }
    }

    var logFileName: String {
        switch self {
        case .claudeCode: "claude_code_log.txt"
        case .codex: "codex_log.txt"
        }
    }

    var installHint: String {
        switch self {
        case .claudeCode: "Check that the directory exists and claude is installed."
        case .codex: "Check that the directory exists and codex is installed and authenticated."
        }
    }
}

struct TranscriptUtterance: Codable, Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    /// Start time in milliseconds
    let startMs: Int
    /// End time in milliseconds
    let endMs: Int

    var startSeconds: TimeInterval { Double(startMs) / 1000.0 }
    var endSeconds: TimeInterval { Double(endMs) / 1000.0 }

    var formattedStart: String {
        let totalSeconds = startMs / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct Screenshot: Codable, Identifiable {
    let id: UUID
    let filename: String
    /// Seconds into the recording when this screenshot was taken
    let timestamp: TimeInterval

    var formattedTimestamp: String {
        let minutes = Int(timestamp) / 60
        let seconds = Int(timestamp) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct Recording: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let durationSeconds: Double
    let audioFileName: String

    /// Subfolder name inside Recordings/ (e.g. "2026-03-12_22-28-15"). Nil for legacy flat recordings.
    var folderName: String?

    var name: String?
    var transcriptionFileName: String?
    var transcriptionStatus: TranscriptionStatus
    var transcriptionModel: String?
    var speakerCount: Int?
    var transcriptionError: String?
    var claudeCodeSentAt: Date?
    var claudeCodeProject: String?
    var codexSentAt: Date?
    var codexProject: String?

    enum TranscriptionStatus: String, Codable {
        case none
        case uploading
        case processing
        case completed
        case failed
    }

    /// The folder where this recording's files live
    var folderURL: URL {
        if let folder = folderName {
            return Recording.recordingsDirectory.appendingPathComponent(folder, isDirectory: true)
        }
        return Recording.recordingsDirectory
    }

    var audioURL: URL {
        folderURL.appendingPathComponent(audioFileName)
    }

    var transcriptionURL: URL? {
        guard let name = transcriptionFileName else { return nil }
        return folderURL.appendingPathComponent(name)
    }

    var speakerNamesURL: URL {
        folderURL.appendingPathComponent("speaker_names.json")
    }

    var screenshotsURL: URL {
        folderURL.appendingPathComponent("screenshots.json")
    }

    var utterancesURL: URL {
        folderURL.appendingPathComponent("transcript_data.json")
    }

    var claudeCodeResponseURL: URL {
        responseURL(for: .claudeCode)
    }

    var hasClaudeCodeResponse: Bool {
        hasResponse(for: .claudeCode)
    }

    var codexResponseURL: URL {
        responseURL(for: .codex)
    }

    var hasCodexResponse: Bool {
        hasResponse(for: .codex)
    }

    /// Screenshot image URLs found in this recording's folder
    func screenshotURL(for screenshot: Screenshot) -> URL {
        folderURL.appendingPathComponent(screenshot.filename)
    }

    /// True when the audio file is missing but chunk files exist in the folder
    var needsRepair: Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: audioURL.path) else { return false }
        return !chunkURLs.isEmpty
    }

    /// Sorted chunk files found in this recording's folder
    var chunkURLs: [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil
        ) else { return [] }
        return contents
            .filter { $0.lastPathComponent.hasPrefix("chunk") && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    var formattedDuration: String {
        let minutes = Int(durationSeconds) / 60
        let seconds = Int(durationSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func responseURL(for agent: HeadlessCodingAgent) -> URL {
        folderURL.appendingPathComponent(agent.responseFileName)
    }

    func hasResponse(for agent: HeadlessCodingAgent) -> Bool {
        FileManager.default.fileExists(atPath: responseURL(for: agent).path)
    }

    func sentAt(for agent: HeadlessCodingAgent) -> Date? {
        switch agent {
        case .claudeCode: claudeCodeSentAt
        case .codex: codexSentAt
        }
    }

    func projectName(for agent: HeadlessCodingAgent) -> String? {
        switch agent {
        case .claudeCode: claudeCodeProject
        case .codex: codexProject
        }
    }

    static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("Memois/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

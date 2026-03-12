import Foundation

struct Recording: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let durationSeconds: Double
    let audioFileName: String

    /// Subfolder name inside Recordings/ (e.g. "2026-03-12_22-28-15"). Nil for legacy flat recordings.
    var folderName: String?

    var transcriptionFileName: String?
    var transcriptionStatus: TranscriptionStatus
    var transcriptionModel: String?
    var speakerCount: Int?
    var transcriptionError: String?

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

    var formattedDuration: String {
        let minutes = Int(durationSeconds) / 60
        let seconds = Int(durationSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("Memois/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

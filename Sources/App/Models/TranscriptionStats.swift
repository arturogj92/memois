import Foundation

struct TranscriptionStats: Codable {
    var totalTranscriptions: Int = 0
    var totalSecondsTranscribed: Double = 0
    var totalByModel: [String: Int] = [:]
    var totalSecondsByModel: [String: Double] = [:]
    var lastTranscriptionDate: Date?

    var formattedTotalDuration: String {
        formatDuration(totalSecondsTranscribed)
    }

    func formattedDuration(for model: String) -> String {
        formatDuration(totalSecondsByModel[model] ?? 0)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, secs)
        }
        return String(format: "%dm %02ds", minutes, secs)
    }

    /// Estimated cost based on AssemblyAI pricing ($0.15/hr best, $0.0265/hr nano)
    var estimatedCostUSD: Double {
        var cost = 0.0
        for (model, seconds) in totalSecondsByModel {
            let hours = seconds / 3600
            switch model {
            case "nano":
                cost += hours * 0.0265
            default:
                cost += hours * 0.15
            }
        }
        return cost
    }

    var formattedCost: String {
        String(format: "$%.4f", estimatedCostUSD)
    }
}

@MainActor
final class TranscriptionStatsStore: ObservableObject {
    @Published var stats: TranscriptionStats

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("Memois", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("transcription_stats.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(TranscriptionStats.self, from: data) {
            self.stats = loaded
        } else {
            self.stats = TranscriptionStats()
        }
    }

    func recordTranscription(durationSeconds: Double, model: String) {
        stats.totalTranscriptions += 1
        stats.totalSecondsTranscribed += durationSeconds
        stats.totalByModel[model, default: 0] += 1
        stats.totalSecondsByModel[model, default: 0] += durationSeconds
        stats.lastTranscriptionDate = Date()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stats) {
            try? data.write(to: fileURL)
        }
    }
}

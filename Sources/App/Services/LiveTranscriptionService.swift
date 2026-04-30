import AVFoundation
import Foundation

/// High-level orchestrator for the live subtitles feature.
///
/// Owns the audio pipeline + WebSocket client, exposes Combine-friendly
/// state for SwiftUI consumption.
@MainActor
final class LiveTranscriptionService: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case live
        case error(String)
        case stopped
    }

    struct Turn: Identifiable, Equatable {
        let id: Int          // turn_order
        let text: String
        let language: String?
    }

    @Published private(set) var committedTurns: [Turn] = []
    @Published private(set) var partial: String = ""
    @Published private(set) var status: Status = .idle
    @Published private(set) var detectedLanguage: String?
    @Published private(set) var bytesSent: Int = 0
    @Published private(set) var peakLevel: Float = 0
    @Published private(set) var lastEventType: String?
    @Published private(set) var audioFormatInfo: String?

    private let pipeline = LiveAudioPipeline()
    private var client: RealtimeTranscriptionClient?
    private var readTask: Task<Void, Never>?

    init() {
        pipeline.onChunk = { [weak self] data in
            self?.client?.send(data)
        }
        pipeline.onDiagnostics = { [weak self] total, peak in
            Task { @MainActor [weak self] in
                self?.bytesSent = total
                self?.peakLevel = peak
            }
        }
        pipeline.onFormatInfo = { [weak self] info in
            Task { @MainActor [weak self] in
                self?.audioFormatInfo = info
            }
        }
    }

    func start(apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .error("Missing AssemblyAI key")
            return
        }

        // Reset any previous state.
        readTask?.cancel()
        client?.terminate()
        pipeline.reset()
        committedTurns = []
        partial = ""
        detectedLanguage = nil
        bytesSent = 0
        status = .connecting

        let client = RealtimeTranscriptionClient()
        self.client = client

        do {
            let stream = try client.connect(apiKey: trimmed)
            readTask = Task { [weak self] in
                for await event in stream {
                    await self?.handle(event: event)
                }
                await self?.handleStreamFinished()
            }
        } catch {
            status = .error(error.localizedDescription)
            self.client = nil
        }
    }

    func ingestMic(_ buffer: AVAudioPCMBuffer) {
        pipeline.ingestMic(buffer)
    }

    func ingestSystem(_ sampleBuffer: CMSampleBuffer) {
        pipeline.ingestSystem(sampleBuffer)
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        client?.terminate()
        client = nil
        pipeline.reset()
        if case .error = status { return }
        status = .stopped
    }

    // MARK: - Private

    private func handle(event: LiveTranscriptionMessage) {
        switch event {
        case .begin: lastEventType = "Begin"
        case .turn: lastEventType = "Turn"
        case .termination: lastEventType = "Termination"
        case .speechStarted: lastEventType = "SpeechStarted"
        case .error: lastEventType = "Error"
        case .warning: lastEventType = "Warning"
        case .unknown: lastEventType = "Unknown"
        }
        switch event {
        case .begin:
            status = .live
        case .turn(let payload):
            if let lang = payload.languageCode { detectedLanguage = lang }
            if payload.endOfTurn {
                let turn = Turn(id: payload.turnOrder, text: payload.transcript, language: payload.languageCode)
                if let idx = committedTurns.firstIndex(where: { $0.id == payload.turnOrder }) {
                    committedTurns[idx] = turn
                } else {
                    committedTurns.append(turn)
                }
                partial = ""
            } else {
                partial = payload.transcript
            }
        case .termination:
            status = .stopped
        case .error(_, let msg):
            status = .error(msg)
        case .warning, .speechStarted, .unknown:
            break
        }
    }

    private func handleStreamFinished() {
        if case .live = status {
            status = .stopped
        } else if case .connecting = status {
            status = .stopped
        }
    }
}


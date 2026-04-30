import Foundation

/// Thin wrapper around `URLSessionWebSocketTask` that talks the AssemblyAI
/// Universal-Streaming v3 protocol.
///
/// Wire format (verified against the official Python SDK at
/// https://github.com/AssemblyAI/assemblyai-python-sdk/blob/master/assemblyai/streaming/v3/client.py):
/// - URL: `wss://streaming.assemblyai.com/v3/ws?<query-params>`
/// - Auth: `Authorization: <api_key>` header
/// - Required header: `AssemblyAI-Version: 2025-05-12`
/// - Audio: binary frames of raw PCM s16le, 50–1000 ms each
/// - Inbound JSON: `Begin`, `Turn`, `Termination`, `SpeechStarted`, `Error`, `Warning`
/// - Outbound text: `{"type":"Terminate"}` to close the session cleanly
final class RealtimeTranscriptionClient: NSObject {
    enum ConnectError: Error {
        case alreadyConnected
        case invalidURL
    }

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<LiveTranscriptionMessage>.Continuation?
    private var isFinished = false
    private let lock = NSLock()

    override init() {
        self.session = URLSession(configuration: .default)
        super.init()
    }

    /// Establishes the WebSocket and returns a stream of decoded server events.
    /// The stream finishes when the server closes the session, on error, or
    /// when `terminate()` is called.
    func connect(apiKey: String) throws -> AsyncStream<LiveTranscriptionMessage> {
        lock.lock()
        defer { lock.unlock() }

        guard task == nil else { throw ConnectError.alreadyConnected }

        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")
        components?.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "speech_model", value: "universal-streaming-multilingual"),
            URLQueryItem(name: "format_turns", value: "true"),
        ]
        guard let url = components?.url else { throw ConnectError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("2025-05-12", forHTTPHeaderField: "AssemblyAI-Version")
        request.setValue("Memois/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        let webSocketTask = session.webSocketTask(with: request)
        self.task = webSocketTask
        self.isFinished = false

        let (stream, continuation) = AsyncStream<LiveTranscriptionMessage>.makeStream()
        self.continuation = continuation

        webSocketTask.resume()
        startReadLoop()

        return stream
    }

    /// Sends a binary frame of PCM s16le bytes. Safe to call on any thread.
    func send(_ chunk: Data) {
        guard let task = self.task else { return }
        task.send(.data(chunk)) { error in
            if let error {
                MemoisDebugLog.shared.write("[ws send error] \(error)")
            }
        }
    }

    /// Sends `{"type":"Terminate"}` and closes the WebSocket.
    func terminate() {
        lock.lock()
        let task = self.task
        let alreadyFinished = isFinished
        isFinished = true
        lock.unlock()

        guard !alreadyFinished, let task else { return }

        let payload = LiveTranscriptionTerminate()
        if let json = try? JSONEncoder().encode(payload),
           let str = String(data: json, encoding: .utf8) {
            task.send(.string(str)) { [weak self] _ in
                task.cancel(with: .normalClosure, reason: nil)
                self?.finishStream()
            }
        } else {
            task.cancel(with: .normalClosure, reason: nil)
            finishStream()
        }
    }

    // MARK: - Private

    private func startReadLoop() {
        Task.detached { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        let decoder = JSONDecoder()
        while let task = self.task, !isFinishedSnapshot() {
            do {
                let message = try await task.receive()
                let data: Data?
                switch message {
                case .data(let d): data = d
                case .string(let s): data = s.data(using: .utf8)
                @unknown default: data = nil
                }

                guard let data else { continue }

                if let str = String(data: data, encoding: .utf8) {
                    MemoisDebugLog.shared.write("[ws recv] \(str)")
                }

                do {
                    let event = try decoder.decode(LiveTranscriptionMessage.self, from: data)
                    continuation?.yield(event)
                    if case .termination = event {
                        finishStream()
                        return
                    }
                } catch {
                    MemoisDebugLog.shared.write("[ws decode failed] \(error)")
                    continue
                }
            } catch {
                continuation?.yield(.error(code: nil, message: error.localizedDescription))
                finishStream()
                return
            }
        }
        finishStream()
    }

    private func isFinishedSnapshot() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    private func finishStream() {
        lock.lock()
        let cont = continuation
        continuation = nil
        let oldTask = task
        task = nil
        isFinished = true
        lock.unlock()

        cont?.finish()
        oldTask?.cancel(with: .normalClosure, reason: nil)
    }
}

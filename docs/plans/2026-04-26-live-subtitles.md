# Live Subtitles Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a toggle in the recording floating panel that, when enabled, streams audio to AssemblyAI Universal-Streaming Multilingual and shows real-time captions in a scrollable area below the indicator. Auto-detects spoken language. Independent of and additive to the existing post-recording batch transcription.

**Architecture:** New `LiveTranscriptionService` orchestrates (1) PCM buffer taps on `AudioRecorder` (mic + system), (2) mix-and-downsample pipeline 48 kHz Float32 → 16 kHz Int16 mono, (3) AssemblyAI v3 WebSocket session, (4) Codable decoder for Begin / Turn / Termination / Error events, (5) `@Published` committed turns + live partial. UI plugs into `FloatingPanelView` with a captions toggle and a scrollable subtitle area. Existing batch transcription is untouched.

**Tech Stack:** Swift 5.10, SwiftUI, AVFoundation, URLSession `WebSocketTask`, AssemblyAI Universal-Streaming v3 (`wss://streaming.assemblyai.com/v3/ws`).

**Project context:**
- No test target (`testTargets: []` in `project.yml`). Verification is manual; pre-existing convention.
- AssemblyAI key already stored in `SettingsStore.assemblyAIKey`.
- Audio captured at 48 kHz mono Float32 in `AudioRecorder.swift`.
- Recording lifecycle owned by `AppModel.swift`.
- Floating UI lives in `Sources/App/UI/FloatingPanelView.swift`.

**AssemblyAI v3 protocol cheat-sheet (verified against official Python SDK):**
- URL: `wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&encoding=pcm_s16le&speech_model=universal-streaming-multilingual&format_turns=true`
- Headers: `Authorization: <api_key>`, `AssemblyAI-Version: 2025-05-12`
- Audio: binary frames, raw PCM s16le, 50–1000 ms per frame
- Server JSON: `{type:"Begin"}`, `{type:"Turn", turn_order, end_of_turn, transcript, words, language_code}`, `{type:"Termination"}`, `{type:"Error", error_code, error}`, `{type:"SpeechStarted"}`
- Client text: `{"type":"Terminate"}` to close

---

## Task 1: Add settings flags

**Files:**
- Modify: `Sources/App/Services/SettingsStore.swift`

**Step 1:** Add two `@Published` properties next to `speakerDiarization`:

```swift
@Published var liveSubtitlesEnabled: Bool {
    didSet { userDefaults.set(liveSubtitlesEnabled, forKey: Keys.liveSubtitlesEnabled) }
}

@Published var liveSubtitlesPanelExpanded: Bool {
    didSet { userDefaults.set(liveSubtitlesPanelExpanded, forKey: Keys.liveSubtitlesPanelExpanded) }
}
```

**Step 2:** Initialise in `init` (defaults `false` and `true`):

```swift
self.liveSubtitlesEnabled = userDefaults.object(forKey: Keys.liveSubtitlesEnabled) as? Bool ?? false
self.liveSubtitlesPanelExpanded = userDefaults.object(forKey: Keys.liveSubtitlesPanelExpanded) as? Bool ?? true
```

**Step 3:** Add keys to `private enum Keys`:

```swift
static let liveSubtitlesEnabled = "settings.liveSubtitlesEnabled"
static let liveSubtitlesPanelExpanded = "settings.liveSubtitlesPanelExpanded"
```

**Step 4:** Build: `xcodebuild -project Memois.xcodeproj -scheme Memois -configuration Debug build` — expect success.

**Step 5:** Commit: `git add -A && git commit -m "feat(settings): add live subtitles toggle"`

---

## Task 2: Protocol message models

**Files:**
- Create: `Sources/App/Models/LiveTranscriptionMessage.swift`

**Step 1:** Write Codable types matching AssemblyAI v3 wire format:

```swift
import Foundation

enum LiveTranscriptionMessage: Decodable {
    case begin(BeginPayload)
    case turn(TurnPayload)
    case termination(TerminationPayload)
    case speechStarted
    case error(code: Int?, message: String)
    case warning(code: Int, message: String)
    case unknown

    private enum CodingKeys: String, CodingKey { case type }

    struct BeginPayload: Decodable {
        let id: String
        let expires_at: Date?
    }

    struct TurnPayload: Decodable {
        let turn_order: Int
        let turn_is_formatted: Bool
        let end_of_turn: Bool
        let transcript: String
        let end_of_turn_confidence: Double?
        let words: [Word]?
        let language_code: String?
        let language_confidence: Double?
    }

    struct TerminationPayload: Decodable {
        let audio_duration_seconds: Int?
        let session_duration_seconds: Int?
    }

    struct Word: Decodable {
        let start: Int
        let end: Int
        let confidence: Double
        let text: String
        let word_is_final: Bool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()
        switch type {
        case "Begin":        self = .begin(try single.decode(BeginPayload.self))
        case "Turn":         self = .turn(try single.decode(TurnPayload.self))
        case "Termination":  self = .termination(try single.decode(TerminationPayload.self))
        case "SpeechStarted": self = .speechStarted
        case "Error":
            struct E: Decodable { let error_code: Int?; let error: String }
            let e = try single.decode(E.self)
            self = .error(code: e.error_code, message: e.error)
        case "Warning":
            struct W: Decodable { let warning_code: Int; let warning: String }
            let w = try single.decode(W.self)
            self = .warning(code: w.warning_code, message: w.warning)
        default: self = .unknown
        }
    }
}

struct LiveTranscriptionTerminate: Encodable {
    let type = "Terminate"
}
```

**Step 2:** Build. Expect success.

**Step 3:** Commit: `git add -A && git commit -m "feat(live-subtitles): add v3 protocol message models"`

---

## Task 3: Expose PCM taps on AudioRecorder

**Files:**
- Modify: `Sources/App/Services/AudioRecorder.swift`

**Goal:** Without changing recording behaviour, add two optional callbacks invoked when a PCM `AVAudioPCMBuffer` is available for mic and for system audio. Both at 48 kHz Float32 mono.

**Step 1:** Add callback properties near `onMicLevel`/`onSystemLevel`:

```swift
var onMicPCM: ((AVAudioPCMBuffer) -> Void)?
var onSystemPCM: ((AVAudioPCMBuffer) -> Void)?
```

**Step 2:** In the mic `installTap` callback (the `converted` buffer at lines ~108–124), invoke `self.onMicPCM?(converted)` after the existing `handleMicAudio(...)` call. Do not block; the callback runs on the audio thread.

**Step 3:** In `handleSystemAudio(_ sampleBuffer: CMSampleBuffer)`, after writing to `systemAudioInput`, convert the `CMSampleBuffer` to `AVAudioPCMBuffer` (Float32 48 kHz mono — already that format per `SCStreamConfiguration`) and invoke `self.onSystemPCM?(buffer)`. Use `CMSampleBufferGetDataBuffer` + `AudioBufferList` extraction. If `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:)` is simpler, use it.

**Step 4:** Build. Expect success. Run app, start a recording briefly, confirm M4A file still records correctly.

**Step 5:** Commit: `git add -A && git commit -m "feat(audio): expose live PCM taps for mic and system"`

---

## Task 4: Mix + downsample pipeline

**Files:**
- Create: `Sources/App/Services/LiveAudioPipeline.swift`

**Behaviour:** Receives Float32 48 kHz mono buffers from mic and system; mixes them sample-by-sample (additive with -3 dB attenuation per source to avoid clipping); downsamples to 16 kHz with `AVAudioConverter`; converts to Int16 little-endian; emits `Data` chunks of ~100 ms (1600 samples × 2 bytes = 3200 bytes) via `onChunk`.

**Step 1:** Sketch the class:

```swift
import AVFoundation

final class LiveAudioPipeline {
    var onChunk: ((Data) -> Void)?

    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let mixedFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private lazy var converter = AVAudioConverter(from: mixedFormat, to: outFormat)!
    private let queue = DispatchQueue(label: "memois.live-audio-pipeline")
    private var pendingMic: AVAudioPCMBuffer?
    private var pendingSystem: AVAudioPCMBuffer?
    private var carry = Data()

    func ingestMic(_ buffer: AVAudioPCMBuffer) { queue.async { self.pendingMic = buffer; self.tryFlush() } }
    func ingestSystem(_ buffer: AVAudioPCMBuffer) { queue.async { self.pendingSystem = buffer; self.tryFlush() } }

    private func tryFlush() {
        // Mix whichever sources are available (add with 0.7 gain), downsample, encode, emit.
        // ...implementation...
    }
}
```

**Step 2:** Implement `tryFlush()`:
- If both pending buffers are present and same length: sum samples (`x[i] = mic[i]*0.7 + sys[i]*0.7`), clamp to [-1, 1].
- If only one is present: use it scaled by 0.85.
- Run through `converter.convert(to: outBuf, error: nil) { ... }` to produce Int16 16 kHz buffer.
- Append the resulting Int16 bytes to `carry`. While `carry.count >= 3200`, emit a 3200-byte slice and remove it.
- Reset `pendingMic` / `pendingSystem`.

**Step 3:** Build. Expect success.

**Step 4:** Commit: `git add -A && git commit -m "feat(live-subtitles): add mix + downsample audio pipeline"`

---

## Task 5: WebSocket client

**Files:**
- Create: `Sources/App/Services/RealtimeTranscriptionClient.swift`

**Behaviour:** Wraps `URLSessionWebSocketTask`. Connects, exposes an `AsyncStream<LiveTranscriptionMessage>` for incoming events, accepts binary frames via `send(_ chunk: Data)`, terminates cleanly with a JSON `Terminate` message + close.

**Step 1:** Skeleton:

```swift
import Foundation

final class RealtimeTranscriptionClient {
    private var task: URLSessionWebSocketTask?
    private var stream: AsyncStream<LiveTranscriptionMessage>?
    private var continuation: AsyncStream<LiveTranscriptionMessage>.Continuation?
    private let session = URLSession(configuration: .default)

    func connect(apiKey: String) -> AsyncStream<LiveTranscriptionMessage> {
        var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
        components.queryItems = [
            .init(name: "sample_rate", value: "16000"),
            .init(name: "encoding", value: "pcm_s16le"),
            .init(name: "speech_model", value: "universal-streaming-multilingual"),
            .init(name: "format_turns", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("2025-05-12", forHTTPHeaderField: "AssemblyAI-Version")

        let task = session.webSocketTask(with: request)
        self.task = task
        let (stream, continuation) = AsyncStream<LiveTranscriptionMessage>.makeStream()
        self.stream = stream
        self.continuation = continuation
        task.resume()
        Task { await self.readLoop() }
        return stream
    }

    func send(_ chunk: Data) {
        task?.send(.data(chunk)) { _ in }
    }

    func terminate() {
        let json = try? JSONEncoder().encode(LiveTranscriptionTerminate())
        if let json, let str = String(data: json, encoding: .utf8) {
            task?.send(.string(str)) { [weak self] _ in
                self?.task?.cancel(with: .normalClosure, reason: nil)
                self?.continuation?.finish()
            }
        } else {
            task?.cancel(with: .normalClosure, reason: nil)
            continuation?.finish()
        }
    }

    private func readLoop() async {
        guard let task else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        while task.closeCode == .invalid {
            do {
                let message = try await task.receive()
                let data: Data?
                switch message {
                case .data(let d): data = d
                case .string(let s): data = s.data(using: .utf8)
                @unknown default: data = nil
                }
                if let data, let event = try? decoder.decode(LiveTranscriptionMessage.self, from: data) {
                    continuation?.yield(event)
                }
            } catch {
                continuation?.yield(.error(code: nil, message: error.localizedDescription))
                continuation?.finish()
                return
            }
        }
        continuation?.finish()
    }
}
```

**Step 2:** Build. Expect success.

**Step 3:** Commit: `git add -A && git commit -m "feat(live-subtitles): add AssemblyAI v3 WebSocket client"`

---

## Task 6: Orchestrator service

**Files:**
- Create: `Sources/App/Services/LiveTranscriptionService.swift`

**Behaviour:** Owns the `RealtimeTranscriptionClient` and `LiveAudioPipeline`. Public API: `start(apiKey:)`, `ingestMic(_:)`, `ingestSystem(_:)`, `stop()`. `@Published` state: `committedTurns: [Turn]`, `partial: String`, `status: Status` (`.idle | .connecting | .live | .error(String) | .stopped`), `detectedLanguage: String?`.

**Step 1:** Create the file:

```swift
import Foundation
import AVFoundation

@MainActor
final class LiveTranscriptionService: ObservableObject {
    enum Status: Equatable { case idle, connecting, live, error(String), stopped }

    struct Turn: Identifiable, Equatable {
        let id: Int          // turn_order
        let text: String
        let language: String?
    }

    @Published private(set) var committedTurns: [Turn] = []
    @Published private(set) var partial: String = ""
    @Published private(set) var status: Status = .idle
    @Published private(set) var detectedLanguage: String?

    private let client = RealtimeTranscriptionClient()
    private let pipeline = LiveAudioPipeline()
    private var readTask: Task<Void, Never>?

    init() {
        pipeline.onChunk = { [weak self] data in
            self?.client.send(data)
        }
    }

    func start(apiKey: String) {
        guard !apiKey.isEmpty else { status = .error("Missing AssemblyAI key"); return }
        committedTurns = []
        partial = ""
        detectedLanguage = nil
        status = .connecting
        let stream = client.connect(apiKey: apiKey)
        readTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event: event)
            }
        }
    }

    func ingestMic(_ buffer: AVAudioPCMBuffer) { pipeline.ingestMic(buffer) }
    func ingestSystem(_ buffer: AVAudioPCMBuffer) { pipeline.ingestSystem(buffer) }

    func stop() {
        readTask?.cancel()
        client.terminate()
        status = .stopped
    }

    private func handle(event: LiveTranscriptionMessage) {
        switch event {
        case .begin: status = .live
        case .turn(let t):
            if let lang = t.language_code { detectedLanguage = lang }
            if t.end_of_turn {
                committedTurns.append(Turn(id: t.turn_order, text: t.transcript, language: t.language_code))
                partial = ""
            } else {
                partial = t.transcript
            }
        case .termination: status = .stopped
        case .error(_, let msg): status = .error(msg)
        case .warning, .speechStarted, .unknown: break
        }
    }
}
```

**Step 2:** Build. Expect success.

**Step 3:** Commit: `git add -A && git commit -m "feat(live-subtitles): add orchestrator service"`

---

## Task 7: Wire into AppModel

**Files:**
- Modify: `Sources/App/AppModel.swift`

**Step 1:** Add `@Published private(set) var liveTranscription = LiveTranscriptionService()` next to other services.

**Step 2:** In the recording start flow (where `audioRecorder.start(deviceUID:)` is awaited), after success and only if `settings.liveSubtitlesEnabled && !settings.assemblyAIKey.isEmpty`:
- Set `audioRecorder.onMicPCM = { [weak self] buf in Task { @MainActor in self?.liveTranscription.ingestMic(buf) } }`
- Same for `onSystemPCM` → `ingestSystem`
- Call `liveTranscription.start(apiKey: settings.assemblyAIKey)`

**Step 3:** In the recording stop flow, after `audioRecorder.stop(...)`:
- `audioRecorder.onMicPCM = nil`
- `audioRecorder.onSystemPCM = nil`
- `liveTranscription.stop()`

**Step 4:** Build. Expect success.

**Step 5:** Commit: `git add -A && git commit -m "feat(live-subtitles): wire service into recording lifecycle"`

---

## Task 8: Subtitles panel view

**Files:**
- Create: `Sources/App/UI/SubtitlesPanelView.swift`

**Step 1:** SwiftUI view bound to `LiveTranscriptionService`:

```swift
import SwiftUI

struct SubtitlesPanelView: View {
    @ObservedObject var service: LiveTranscriptionService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusDot
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
                if let lang = service.detectedLanguage {
                    Text(lang.uppercased()).font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule())
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(service.committedTurns) { turn in
                            Text(turn.text).id(turn.id).textSelection(.enabled)
                        }
                        if !service.partial.isEmpty {
                            Text(service.partial).foregroundStyle(.secondary).id("partial")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: service.committedTurns.count) { _ in
                    withAnimation { proxy.scrollTo("partial", anchor: .bottom) }
                }
                .onChange(of: service.partial) { _ in
                    proxy.scrollTo("partial", anchor: .bottom)
                }
            }
        }
        .padding(8)
        .frame(minHeight: 80, idealHeight: 140, maxHeight: 200)
    }

    private var statusDot: some View {
        Circle().fill(statusColor).frame(width: 6, height: 6)
    }

    private var statusColor: Color {
        switch service.status {
        case .live: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .stopped, .idle: return .gray
        }
    }

    private var statusLabel: String {
        switch service.status {
        case .idle: return "Subtitles off"
        case .connecting: return "Connecting…"
        case .live: return "Live"
        case .stopped: return "Stopped"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}
```

**Step 2:** Build. Expect success.

**Step 3:** Commit: `git add -A && git commit -m "feat(live-subtitles): add subtitles panel view"`

---

## Task 9: Toggle + integration in FloatingPanelView

**Files:**
- Modify: `Sources/App/UI/FloatingPanelView.swift`

**Step 1:** Inject `LiveTranscriptionService` and `SettingsStore` (likely already available via `AppModel` env object).

**Step 2:** Add a captions button (`Image(systemName: "captions.bubble")`) next to existing controls. Toggles `settings.liveSubtitlesEnabled`. Highlight when on.

**Step 3:** When `settings.liveSubtitlesEnabled && appModel.isRecording`, show `SubtitlesPanelView(service: appModel.liveTranscription)` below the indicator. Respect `settings.liveSubtitlesPanelExpanded` for collapsed/expanded.

**Step 4:** Add a chevron button to toggle `liveSubtitlesPanelExpanded`.

**Step 5:** Build. Expect success.

**Step 6:** Commit: `git add -A && git commit -m "feat(live-subtitles): expose toggle and panel in floating UI"`

---

## Task 10: Manual smoke test

**Step 1:** Run app from Xcode (Debug). Open Settings, confirm AssemblyAI key is set.

**Step 2:** Toggle the new captions button in the floating panel. Start a recording. Speak in Spanish: "Hola, esto es una prueba de subtítulos en vivo."

**Expected:**
- Status pill: `Connecting…` → `Live` within ~1 s
- Partial transcript appears as you speak (greyed)
- Final lines accumulate as you pause
- Language pill shows `ES`
- Switching to English speech updates the language pill
- Stopping the recording terminates the WebSocket cleanly (no spinner stuck)
- The post-recording batch transcription still runs and completes normally

**Step 3:** If issues, add `print` traces in `LiveTranscriptionService.handle(event:)` and `RealtimeTranscriptionClient.readLoop()` to inspect the wire protocol.

**Step 4:** Final commit if any tweaks: `git add -A && git commit -m "chore(live-subtitles): tweaks from smoke test"`

---

## Out of scope for this plan (do NOT implement)

- Live Q&A with `claude -p` against the partial transcript — separate iteration after subtitles ship.
- Persisting the live transcript into the recording folder (batch result is the source of truth post-recording).
- Subtitles in a separate floating window à la Apple Live Captions — keep it inside `FloatingPanelView` for v1.
- Speaker diarisation in the live stream — `universal-streaming-multilingual` does not provide speaker labels; batch flow already does.
- Settings UI for a global default — the floating panel toggle is the only entry point in v1.
- Reconnection / backoff — single attempt; on error show status pill and stop.

## Risks

- **Audio thread back-pressure:** `AudioRecorder` callbacks run on the audio thread. The pipeline must not block. `LiveAudioPipeline.queue.async` already offloads.
- **Sample rate of system audio:** assumes 48 kHz mono per `SCStreamConfiguration`; verify in Task 3 step 4 with a quick `print(buffer.format.sampleRate)`.
- **Throttling 4029 ("Audio too fast"):** chunks are 100 ms apart; should be safe.
- **Memory:** committedTurns array grows unbounded during long recordings. Acceptable for v1 (typical meetings < 2 h).

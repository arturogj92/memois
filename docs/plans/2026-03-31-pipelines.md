# Pipelines Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a configurable pipeline system that automatically executes steps (auto-transcribe, assign speakers, Claude Code headless) when a recording finishes.

**Architecture:** Pipelines are user-created ordered lists of steps. Each step is auto or manual. A PipelineEngine runs in AppModel, advancing steps automatically and pausing on manual steps. Pipelines persist as JSON alongside recordings. The Recording model gains a `pipelineId` field, and a `PipelineExecution` tracks runtime state per recording.

**Tech Stack:** SwiftUI, Foundation, Process (for Claude Code), JSON persistence

---

### Task 1: Pipeline Data Models

**Files:**
- Create: `Sources/App/Models/Pipeline.swift`

**Step 1: Create the Pipeline model file**

```swift
import Foundation

// MARK: - Pipeline

struct Pipeline: Codable, Identifiable {
    let id: UUID
    var name: String
    var steps: [PipelineStep]
    var isDefault: Bool
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, steps: [PipelineStep] = [], isDefault: Bool = false, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.steps = steps
        self.isDefault = isDefault
        self.isEnabled = isEnabled
    }
}

// MARK: - Steps

struct PipelineStep: Codable, Identifiable {
    let id: UUID
    var type: StepType
    var isEnabled: Bool

    init(id: UUID = UUID(), type: StepType, isEnabled: Bool = true) {
        self.id = id
        self.type = type
        self.isEnabled = isEnabled
    }
}

enum StepType: Codable, Equatable {
    case autoTranscribe
    case assignSpeakers
    case claudeCode(ClaudeCodeConfig)

    var label: String {
        switch self {
        case .autoTranscribe: return "Auto Transcribe"
        case .assignSpeakers: return "Assign Speakers"
        case .claudeCode: return "Claude Code"
        }
    }

    var isManual: Bool {
        switch self {
        case .assignSpeakers: return true
        default: return false
        }
    }

    var icon: String {
        switch self {
        case .autoTranscribe: return "waveform"
        case .assignSpeakers: return "person.2"
        case .claudeCode: return "terminal"
        }
    }
}

struct ClaudeCodeConfig: Codable, Equatable {
    var directoryPath: String
    var promptPrefix: String

    init(directoryPath: String = "", promptPrefix: String = "") {
        self.directoryPath = directoryPath
        self.promptPrefix = promptPrefix
    }
}

// MARK: - Pipeline Execution (runtime state per recording)

struct PipelineExecution: Codable, Identifiable {
    let id: UUID
    let pipelineId: UUID
    let recordingId: UUID
    var currentStepIndex: Int
    var status: ExecutionStatus
    var stepResults: [StepResult]
    var startedAt: Date
    var completedAt: Date?

    init(pipelineId: UUID, recordingId: UUID, steps: [PipelineStep]) {
        self.id = UUID()
        self.pipelineId = pipelineId
        self.recordingId = recordingId
        self.currentStepIndex = 0
        self.status = .running
        self.stepResults = steps.map { step in
            StepResult(stepId: step.id, status: .pending)
        }
        self.startedAt = Date()
    }
}

enum ExecutionStatus: String, Codable {
    case running
    case waitingForUser
    case completed
    case failed
    case paused
}

struct StepResult: Codable, Identifiable {
    let id: UUID
    let stepId: UUID
    var status: StepStatus
    var error: String?

    init(id: UUID = UUID(), stepId: UUID, status: StepStatus = .pending, error: String? = nil) {
        self.id = id
        self.stepId = stepId
        self.status = status
        self.error = error
    }
}

enum StepStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case skipped
    case waitingForUser
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/vzgb9jp/Development/memois && xcodebuild -project Memois.xcodeproj -scheme Memois -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/App/Models/Pipeline.swift
git commit -m "feat(pipelines): add Pipeline, PipelineStep, PipelineExecution data models"
```

---

### Task 2: Pipeline Store (persistence)

**Files:**
- Create: `Sources/App/Services/PipelineStore.swift`

**Step 1: Create the PipelineStore**

```swift
import Foundation

@MainActor
final class PipelineStore {
    private let pipelinesURL: URL
    private let executionsURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("Memois", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        self.pipelinesURL = folder.appendingPathComponent("pipelines.json")
        self.executionsURL = folder.appendingPathComponent("pipeline_executions.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadPipelines() -> [Pipeline] {
        guard let data = try? Data(contentsOf: pipelinesURL) else { return [] }
        return (try? decoder.decode([Pipeline].self, from: data)) ?? []
    }

    func savePipelines(_ pipelines: [Pipeline]) {
        guard let data = try? encoder.encode(pipelines) else { return }
        try? data.write(to: pipelinesURL, options: .atomic)
    }

    func loadExecutions() -> [PipelineExecution] {
        guard let data = try? Data(contentsOf: executionsURL) else { return [] }
        return (try? decoder.decode([PipelineExecution].self, from: data)) ?? []
    }

    func saveExecutions(_ executions: [PipelineExecution]) {
        guard let data = try? encoder.encode(executions) else { return }
        try? data.write(to: executionsURL, options: .atomic)
    }
}
```

**Step 2: Verify it compiles**

**Step 3: Commit**

```bash
git add Sources/App/Services/PipelineStore.swift
git commit -m "feat(pipelines): add PipelineStore for JSON persistence"
```

---

### Task 3: Recording model - add pipelineId field

**Files:**
- Modify: `Sources/App/Models/Recording.swift`

**Step 1: Add pipelineId to Recording**

Add `var pipelineId: UUID?` field to Recording struct (after `transcriptionError`). This tracks which pipeline was assigned to the recording.

Since Recording uses memberwise init in multiple places, also update the `Recording(...)` calls in `AppModel.swift` to include `pipelineId: nil`.

**Step 2: Update AppModel.swift Recording creation calls**

In `stopRecording()` (~line 218) and `importAudio()` (~line 353), add `pipelineId: nil` to the Recording init calls. We'll wire in the actual pipeline selection later.

**Step 3: Verify it compiles and commit**

```bash
git add Sources/App/Models/Recording.swift Sources/App/AppModel.swift
git commit -m "feat(pipelines): add pipelineId field to Recording model"
```

---

### Task 4: Pipeline Engine (core execution logic)

**Files:**
- Create: `Sources/App/Services/PipelineEngine.swift`

**Step 1: Create the PipelineEngine**

The engine is responsible for:
1. Starting a pipeline execution when a recording finishes
2. Advancing through steps (auto steps run immediately, manual steps pause)
3. Handling step completion/failure
4. Building the Claude Code prompt and launching the process

```swift
import Foundation

@MainActor
final class PipelineEngine: ObservableObject {
    @Published var executions: [PipelineExecution] = []

    private let store: PipelineStore
    private weak var appModel: AppModel?

    init(store: PipelineStore) {
        self.store = store
        self.executions = store.loadExecutions()
    }

    func setAppModel(_ model: AppModel) {
        self.appModel = model
    }

    // MARK: - Start pipeline for a recording

    func startPipeline(_ pipeline: Pipeline, for recordingId: UUID) {
        let enabledSteps = pipeline.steps.filter(\.isEnabled)
        guard !enabledSteps.isEmpty else { return }

        var execution = PipelineExecution(pipelineId: pipeline.id, recordingId: recordingId, steps: enabledSteps)
        executions.append(execution)
        saveExecutions()

        Task {
            await runNextStep(executionId: execution.id, steps: enabledSteps)
        }
    }

    // MARK: - Advance pipeline

    private func runNextStep(executionId: UUID, steps: [PipelineStep]) async {
        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }) else { return }
        let stepIndex = executions[exIndex].currentStepIndex

        guard stepIndex < steps.count else {
            // All steps done
            executions[exIndex].status = .completed
            executions[exIndex].completedAt = Date()
            saveExecutions()
            return
        }

        let step = steps[stepIndex]

        // Mark step as running
        executions[exIndex].stepResults[stepIndex].status = .running
        executions[exIndex].status = .running
        saveExecutions()

        switch step.type {
        case .autoTranscribe:
            await executeAutoTranscribe(executionId: executionId, stepIndex: stepIndex, steps: steps)

        case .assignSpeakers:
            // Pause and wait for user
            executions[exIndex].stepResults[stepIndex].status = .waitingForUser
            executions[exIndex].status = .waitingForUser
            saveExecutions()
            // Will be resumed by notifySpeakersAssigned()

        case .claudeCode(let config):
            await executeClaudeCode(executionId: executionId, stepIndex: stepIndex, steps: steps, config: config)
        }
    }

    // MARK: - Auto Transcribe

    private func executeAutoTranscribe(executionId: UUID, stepIndex: Int, steps: [PipelineStep]) async {
        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }),
              let model = appModel else { return }

        let recordingId = executions[exIndex].recordingId

        // Trigger transcription
        model.transcribe(recordingID: recordingId)

        // Poll until transcription completes
        while true {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            guard let recIndex = model.recordings.firstIndex(where: { $0.id == recordingId }) else {
                markStepFailed(executionId: executionId, stepIndex: stepIndex, error: "Recording not found")
                return
            }

            let status = model.recordings[recIndex].transcriptionStatus
            if status == .completed {
                break
            } else if status == .failed {
                let error = model.recordings[recIndex].transcriptionError ?? "Transcription failed"
                markStepFailed(executionId: executionId, stepIndex: stepIndex, error: error)
                return
            }
            // else still uploading/processing, keep polling
        }

        // Success
        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }) else { return }
        executions[exIndex].stepResults[stepIndex].status = .completed
        executions[exIndex].currentStepIndex = stepIndex + 1
        saveExecutions()

        await runNextStep(executionId: executionId, steps: steps)
    }

    // MARK: - Claude Code Headless

    private func executeClaudeCode(executionId: UUID, stepIndex: Int, steps: [PipelineStep], config: ClaudeCodeConfig) async {
        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }),
              let model = appModel else { return }

        let recordingId = executions[exIndex].recordingId
        guard let recording = model.recordings.first(where: { $0.id == recordingId }) else {
            markStepFailed(executionId: executionId, stepIndex: stepIndex, error: "Recording not found")
            return
        }

        // Build prompt
        let prompt = buildClaudeCodePrompt(for: recording, config: config, model: model)

        guard !config.directoryPath.isEmpty else {
            markStepFailed(executionId: executionId, stepIndex: stepIndex, error: "No directory configured")
            return
        }

        // Run claude code headless
        let success = await runClaudeCode(prompt: prompt, directory: config.directoryPath)

        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }) else { return }

        if success {
            executions[exIndex].stepResults[stepIndex].status = .completed
            executions[exIndex].currentStepIndex = stepIndex + 1
            saveExecutions()
            await runNextStep(executionId: executionId, steps: steps)
        } else {
            markStepFailed(executionId: executionId, stepIndex: stepIndex, error: "Claude Code exited with error")
        }
    }

    private func buildClaudeCodePrompt(for recording: Recording, config: ClaudeCodeConfig, model: AppModel) -> String {
        let speakerNames = model.loadSpeakerNames(for: recording)
        let rawTranscript = model.readTranscript(for: recording) ?? ""
        let transcript = model.applyingSpeakerNames(speakerNames, to: rawTranscript)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        let dateStr = dateFormatter.string(from: recording.createdAt)

        let recordingName = recording.name ?? "Untitled Recording"

        let speakerList = speakerNames.isEmpty ? "Unknown" : speakerNames.values.filter { !$0.isEmpty }.joined(separator: ", ")

        var prompt = """
        Here is the transcript from a meeting recorded on \(dateStr), titled '\(recordingName)'.

        Speakers: \(speakerList)

        """

        if !config.promptPrefix.isEmpty {
            prompt += config.promptPrefix + "\n\n"
        }

        prompt += transcript

        return prompt
    }

    private func runClaudeCode(prompt: String, directory: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/local/bin/claude")
                process.arguments = ["--dangerously-skip-permissions", "-p", prompt]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)

                // Also check common paths
                let paths = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(NSHomeDirectory())/.claude/local/claude"]
                var foundPath: String?
                for path in paths {
                    if FileManager.default.fileExists(atPath: path) {
                        foundPath = path
                        break
                    }
                }

                guard let execPath = foundPath else {
                    continuation.resume(returning: false)
                    return
                }

                process.executableURL = URL(fileURLWithPath: execPath)
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Manual step completion (speakers assigned)

    func notifySpeakersAssigned(recordingId: UUID) {
        guard let model = appModel,
              let recording = model.recordings.first(where: { $0.id == recordingId }),
              let pipelineId = recording.pipelineId else { return }

        guard let exIndex = executions.firstIndex(where: {
            $0.recordingId == recordingId && $0.status == .waitingForUser
        }) else { return }

        let execution = executions[exIndex]
        let pipelines = store.loadPipelines()
        guard let pipeline = pipelines.first(where: { $0.id == pipelineId }) else { return }
        let enabledSteps = pipeline.steps.filter(\.isEnabled)

        let stepIndex = execution.currentStepIndex
        guard stepIndex < enabledSteps.count else { return }

        // Verify all speakers are named
        let speakerNames = model.loadSpeakerNames(for: recording)
        let rawTranscript = model.readTranscript(for: recording) ?? ""
        let detectedSpeakers = extractSpeakers(from: rawTranscript)

        let allNamed = detectedSpeakers.allSatisfy { speaker in
            guard let name = speakerNames[speaker] else { return false }
            return !name.isEmpty
        }

        guard allNamed else { return }

        // All speakers named - advance
        executions[exIndex].stepResults[stepIndex].status = .completed
        executions[exIndex].currentStepIndex = stepIndex + 1
        saveExecutions()

        Task {
            await runNextStep(executionId: execution.id, steps: enabledSteps)
        }
    }

    /// Force-continue a manual step (user presses "Continue Pipeline" button)
    func forceContinue(executionId: UUID) {
        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }) else { return }

        let execution = executions[exIndex]
        guard execution.status == .waitingForUser else { return }
        guard let pipelineId = execution.pipelineId as UUID? else { return }

        let pipelines = store.loadPipelines()
        guard let pipeline = pipelines.first(where: { $0.id == pipelineId }) else { return }
        let enabledSteps = pipeline.steps.filter(\.isEnabled)

        let stepIndex = execution.currentStepIndex
        executions[exIndex].stepResults[stepIndex].status = .completed
        executions[exIndex].currentStepIndex = stepIndex + 1
        saveExecutions()

        Task {
            await runNextStep(executionId: execution.id, steps: enabledSteps)
        }
    }

    /// Retry a failed step
    func retryStep(executionId: UUID) {
        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }) else { return }
        guard executions[exIndex].status == .failed else { return }

        let execution = executions[exIndex]
        guard let pipelineId = execution.pipelineId as UUID? else { return }

        let pipelines = store.loadPipelines()
        guard let pipeline = pipelines.first(where: { $0.id == pipelineId }) else { return }
        let enabledSteps = pipeline.steps.filter(\.isEnabled)

        executions[exIndex].status = .running
        executions[exIndex].stepResults[execution.currentStepIndex].status = .pending
        executions[exIndex].stepResults[execution.currentStepIndex].error = nil
        saveExecutions()

        Task {
            await runNextStep(executionId: execution.id, steps: enabledSteps)
        }
    }

    // MARK: - Resume on app launch

    func resumePendingExecutions() {
        for execution in executions where execution.status == .running {
            guard let pipelineId = execution.pipelineId as UUID? else { continue }
            let pipelines = store.loadPipelines()
            guard let pipeline = pipelines.first(where: { $0.id == pipelineId }) else { continue }
            let enabledSteps = pipeline.steps.filter(\.isEnabled)

            Task {
                await runNextStep(executionId: execution.id, steps: enabledSteps)
            }
        }
    }

    func execution(for recordingId: UUID) -> PipelineExecution? {
        executions.first(where: { $0.recordingId == recordingId })
    }

    // MARK: - Helpers

    private func markStepFailed(executionId: UUID, stepIndex: Int, error: String) {
        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }) else { return }
        executions[exIndex].stepResults[stepIndex].status = .failed
        executions[exIndex].stepResults[stepIndex].error = error
        executions[exIndex].status = .failed
        saveExecutions()
    }

    private func saveExecutions() {
        store.saveExecutions(executions)
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
```

**Step 2: Verify it compiles**

**Step 3: Commit**

```bash
git add Sources/App/Services/PipelineEngine.swift
git commit -m "feat(pipelines): add PipelineEngine with step execution, Claude Code integration, speaker detection"
```

---

### Task 5: Wire PipelineEngine into AppModel

**Files:**
- Modify: `Sources/App/AppModel.swift`

**Step 1: Add PipelineEngine and PipelineStore to AppModel**

- Add `let pipelineStore: PipelineStore` and `let pipelineEngine: PipelineEngine` properties
- Add `@Published var pipelines: [Pipeline] = []`
- Add `@Published var selectedPipelineId: UUID?` (for the pipeline picker during recording)
- Update init to create PipelineStore, PipelineEngine, load pipelines
- Call `pipelineEngine.setAppModel(self)` in init
- Call `pipelineEngine.resumePendingExecutions()` in init

**Step 2: Trigger pipeline after stopRecording()**

In `stopRecording()`, after `recordingStore.save(recordings)` (~line 232), add:

```swift
// Start pipeline if one is assigned
let pipelineId = selectedPipelineId ?? pipelines.first(where: { $0.isDefault && $0.isEnabled })?.id
if let pipelineId, let pipeline = pipelines.first(where: { $0.id == pipelineId && $0.isEnabled }) {
    recordings[0].pipelineId = pipelineId
    recordingStore.save(recordings)
    pipelineEngine.startPipeline(pipeline, for: recording.id)
}
selectedPipelineId = nil
```

**Step 3: Wire speaker name saves to pipeline engine**

In `saveSpeakerNames()` (~line 406), after writing the file, add:

```swift
pipelineEngine.notifySpeakersAssigned(recordingId: recording.id)
```

But `saveSpeakerNames` takes a `Recording`, not an id. Add the notification call referencing `recording.id`.

**Step 4: Add pipeline CRUD methods to AppModel**

```swift
// MARK: - Pipelines

func addPipeline(name: String) {
    let pipeline = Pipeline(name: name)
    pipelines.append(pipeline)
    pipelineStore.savePipelines(pipelines)
}

func deletePipeline(id: UUID) {
    pipelines.removeAll { $0.id == id }
    pipelineStore.savePipelines(pipelines)
}

func updatePipeline(_ pipeline: Pipeline) {
    guard let index = pipelines.firstIndex(where: { $0.id == pipeline.id }) else { return }
    pipelines[index] = pipeline
    pipelineStore.savePipelines(pipelines)
}

func setDefaultPipeline(id: UUID) {
    for i in pipelines.indices {
        pipelines[i].isDefault = (pipelines[i].id == id)
    }
    pipelineStore.savePipelines(pipelines)
}
```

**Step 5: Update MemoisApp.swift to create PipelineStore**

Add `let pipelineStore = PipelineStore()` and pass it to AppModel init.

**Step 6: Verify it compiles and commit**

```bash
git add Sources/App/AppModel.swift Sources/App/MemoisApp.swift
git commit -m "feat(pipelines): wire PipelineEngine into AppModel, trigger pipelines on recording stop"
```

---

### Task 6: Pipelines Settings UI

**Files:**
- Create: `Sources/App/UI/PipelinesSettingsView.swift`
- Modify: `Sources/App/UI/MainWindowView.swift`

**Step 1: Add "Pipelines" tab to the sidebar**

In MainWindowView, add `.pipelines` case to `SidebarTab` enum (after `.settings`):

```swift
case pipelines = "Pipelines"
```

With icon `"arrow.triangle.branch"`.

Add `case .pipelines: pipelinesContent` to the contentArea switch.

**Step 2: Create PipelinesSettingsView as a separate file**

This view shows:
- List of pipelines with add/delete
- Edit pipeline: name, default toggle, list of steps
- Add step picker (auto-transcribe, assign speakers, claude code)
- Claude Code step config: directory picker + prompt prefix

```swift
import SwiftUI

struct PipelinesSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var editingPipeline: Pipeline?
    @State private var isAddingPipeline = false
    @State private var newPipelineName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Pipelines")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    isAddingPipeline = true
                    newPipelineName = ""
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                        Text("New Pipeline")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }

            if model.pipelines.isEmpty && !isAddingPipeline {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.15))
                    Text("No pipelines configured")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("Create a pipeline to automate post-recording actions")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.15))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
            }

            if isAddingPipeline {
                addPipelineCard
            }

            ForEach(model.pipelines) { pipeline in
                pipelineCard(pipeline)
            }
        }
    }

    // --- Add pipeline card ---
    private var addPipelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Pipeline")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            HStack(spacing: 8) {
                TextField("Pipeline name...", text: $newPipelineName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(red: 0.14, green: 0.14, blue: 0.16))
                    )
                    .onSubmit {
                        createPipeline()
                    }

                Button("Create") {
                    createPipeline()
                }
                .disabled(newPipelineName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Cancel") {
                    isAddingPipeline = false
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13))
        )
    }

    private func createPipeline() {
        let name = newPipelineName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.addPipeline(name: name)
        isAddingPipeline = false
        newPipelineName = ""
    }

    // --- Pipeline card ---
    private func pipelineCard(_ pipeline: Pipeline) -> some View {
        PipelineCardView(pipeline: pipeline, model: model)
    }
}
```

**Step 3: Create PipelineCardView** (inline in same file or separate)

This shows the pipeline name, default toggle, steps list, add step, and each step's config. Include a disclosure group to expand/collapse step configuration.

**Step 4: Add `pipelinesContent` to MainWindowView**

```swift
private var pipelinesContent: some View {
    PipelinesSettingsView(model: model)
}
```

**Step 5: Verify it compiles and commit**

```bash
git add Sources/App/UI/PipelinesSettingsView.swift Sources/App/UI/MainWindowView.swift
git commit -m "feat(pipelines): add Pipelines tab and settings UI with pipeline CRUD"
```

---

### Task 7: Pipeline Picker in Floating Panel

**Files:**
- Modify: `Sources/App/UI/FloatingPanelView.swift`

**Step 1: Add pipeline selector during recording**

In the recording mode section of FloatingPanelView, below the audio level bars, add a pipeline picker if pipelines exist:

```swift
if !model.pipelines.filter(\.isEnabled).isEmpty {
    Divider().opacity(0.2).padding(.vertical, 4)
    HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.4))
        Picker("Pipeline", selection: $model.selectedPipelineId) {
            Text("None").tag(UUID?.none)
            ForEach(model.pipelines.filter(\.isEnabled)) { pipeline in
                Text(pipeline.name).tag(UUID?.some(pipeline.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }
}
```

The default value of `selectedPipelineId` should be set to the default pipeline's id when recording starts (in `startRecording()` in AppModel).

**Step 2: Set default pipeline on recording start**

In `AppModel.startRecording()`, add at the beginning:

```swift
selectedPipelineId = pipelines.first(where: { $0.isDefault && $0.isEnabled })?.id
```

**Step 3: Verify it compiles and commit**

```bash
git add Sources/App/UI/FloatingPanelView.swift Sources/App/AppModel.swift
git commit -m "feat(pipelines): add pipeline picker in floating panel during recording"
```

---

### Task 8: Pipeline Status in Recording List

**Files:**
- Modify: `Sources/App/UI/MainWindowView.swift`

**Step 1: Show pipeline execution status in recording rows**

In `recordingRow()`, after the transcription status badge, add a pipeline status indicator:

```swift
if let execution = model.pipelineEngine.execution(for: recording.id) {
    pipelineStatusBadge(execution)
}
```

Add the helper:

```swift
private func pipelineStatusBadge(_ execution: PipelineExecution) -> some View {
    let enabledCount = execution.stepResults.count
    let completedCount = execution.stepResults.filter { $0.status == .completed }.count
    let (label, color): (String, Color) = {
        switch execution.status {
        case .running: return ("Pipeline \(completedCount)/\(enabledCount)", .brandCyan)
        case .waitingForUser: return ("Waiting for speakers", .brandYellow)
        case .completed: return ("Pipeline done", .brandGreen)
        case .failed: return ("Pipeline failed", .brandPink)
        case .paused: return ("Pipeline paused", .brandYellow)
        }
    }()

    return Text(label)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(color.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
}
```

**Step 2: Add "Continue Pipeline" and "Retry" buttons**

When pipeline is waiting for user or failed, show action buttons:

```swift
if let execution = model.pipelineEngine.execution(for: recording.id) {
    if execution.status == .waitingForUser {
        Button("Continue Pipeline") {
            model.pipelineEngine.forceContinue(executionId: execution.id)
        }
        // styled like other buttons
    }
    if execution.status == .failed {
        Button("Retry Pipeline") {
            model.pipelineEngine.retryStep(executionId: execution.id)
        }
    }
}
```

**Step 3: Verify it compiles and commit**

```bash
git add Sources/App/UI/MainWindowView.swift
git commit -m "feat(pipelines): show pipeline status and actions in recording list"
```

---

### Task 9: Wire speaker name changes to pipeline auto-detection

**Files:**
- Modify: `Sources/App/UI/RecordingDetailView.swift`
- Modify: `Sources/App/AppModel.swift`

**Step 1: Update saveSpeakerNames to notify pipeline engine**

In `AppModel.saveSpeakerNames()`, after writing the file, call:

```swift
pipelineEngine.notifySpeakersAssigned(recordingId: recording.id)
```

This was already planned in Task 5 but ensure it's implemented. The key here: `notifySpeakersAssigned` checks if ALL speakers are renamed before advancing.

**Step 2: Verify the full flow end to end**

Test sequence:
1. Create a pipeline with steps: auto-transcribe -> assign speakers -> claude code
2. Record something short
3. Pipeline should auto-start transcription
4. After transcription completes, pipeline pauses on "assign speakers"
5. Rename all speakers in RecordingDetailView
6. Pipeline should auto-detect and launch Claude Code step

**Step 3: Commit**

```bash
git add Sources/App/AppModel.swift Sources/App/UI/RecordingDetailView.swift
git commit -m "feat(pipelines): wire speaker name saves to pipeline engine auto-detection"
```

---

### Task 10: Resilience - Resume pipelines on app launch

**Files:**
- Modify: `Sources/App/AppModel.swift`

**Step 1: Resume pending executions in AppModel.init**

After loading recordings and resetting stuck transcriptions, call:

```swift
pipelineEngine.resumePendingExecutions()
```

This handles the case where the app was closed while a pipeline was running. Auto steps will retry, manual steps stay waiting.

**Step 2: Reset stuck running executions**

Similar to how transcriptions stuck in `.uploading`/`.processing` are reset, reset pipeline executions stuck in `.running` (the step-level status) back to `.pending` so they can be retried.

**Step 3: Verify and commit**

```bash
git add Sources/App/AppModel.swift
git commit -m "feat(pipelines): resume pending pipeline executions on app launch"
```

---

### Summary of all files

**New files:**
- `Sources/App/Models/Pipeline.swift` - Data models
- `Sources/App/Services/PipelineStore.swift` - JSON persistence
- `Sources/App/Services/PipelineEngine.swift` - Execution engine
- `Sources/App/UI/PipelinesSettingsView.swift` - Settings UI

**Modified files:**
- `Sources/App/Models/Recording.swift` - Add `pipelineId`
- `Sources/App/AppModel.swift` - Wire engine, CRUD, trigger on stop
- `Sources/App/UI/MainWindowView.swift` - Add Pipelines tab, status badges
- `Sources/App/UI/FloatingPanelView.swift` - Pipeline picker during recording
- `Sources/App/UI/RecordingDetailView.swift` - Continue pipeline button
- `Sources/App/MemoisApp.swift` - Create PipelineStore

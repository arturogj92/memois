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

        let execution = PipelineExecution(pipelineId: pipeline.id, recordingId: recordingId, steps: enabledSteps)
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
            executions[exIndex].status = .completed
            executions[exIndex].completedAt = Date()
            saveExecutions()
            return
        }

        let step = steps[stepIndex]

        executions[exIndex].stepResults[stepIndex].status = .running
        executions[exIndex].status = .running
        saveExecutions()

        switch step.type {
        case .autoTranscribe:
            await executeAutoTranscribe(executionId: executionId, stepIndex: stepIndex, steps: steps)

        case .assignSpeakers:
            guard let exIndex = executions.firstIndex(where: { $0.id == executionId }) else { return }
            executions[exIndex].stepResults[stepIndex].status = .waitingForUser
            executions[exIndex].status = .waitingForUser
            saveExecutions()

        case .claudeCode(let config):
            await executeClaudeCode(executionId: executionId, stepIndex: stepIndex, steps: steps, config: config)
        }
    }

    // MARK: - Auto Transcribe

    private func executeAutoTranscribe(executionId: UUID, stepIndex: Int, steps: [PipelineStep]) async {
        guard let exIndex = executions.firstIndex(where: { $0.id == executionId }),
              let model = appModel else { return }

        let recordingId = executions[exIndex].recordingId

        model.transcribe(recordingID: recordingId)

        while true {
            try? await Task.sleep(nanoseconds: 2_000_000_000)

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
        }

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

        let prompt = buildClaudeCodePrompt(for: recording, config: config, model: model)

        guard !config.directoryPath.isEmpty else {
            markStepFailed(executionId: executionId, stepIndex: stepIndex, error: "No directory configured")
            return
        }

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

                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = ["--dangerously-skip-permissions", "-p", prompt]
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
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
              recording.pipelineId != nil else { return }

        guard let exIndex = executions.firstIndex(where: {
            $0.recordingId == recordingId && $0.status == .waitingForUser
        }) else { return }

        let speakerNames = model.loadSpeakerNames(for: recording)
        let rawTranscript = model.readTranscript(for: recording) ?? ""
        let detectedSpeakers = extractSpeakers(from: rawTranscript)

        let allNamed = detectedSpeakers.allSatisfy { speaker in
            guard let name = speakerNames[speaker] else { return false }
            return !name.isEmpty
        }

        guard allNamed else { return }

        let execution = executions[exIndex]
        let pipelines = store.loadPipelines()
        guard let pipeline = pipelines.first(where: { $0.id == execution.pipelineId }) else { return }
        let enabledSteps = pipeline.steps.filter(\.isEnabled)

        let stepIndex = execution.currentStepIndex
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

        let pipelines = store.loadPipelines()
        guard let pipeline = pipelines.first(where: { $0.id == execution.pipelineId }) else { return }
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

        let pipelines = store.loadPipelines()
        guard let pipeline = pipelines.first(where: { $0.id == execution.pipelineId }) else { return }
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
        for i in executions.indices where executions[i].status == .running {
            // Reset the current step from .running back to .pending so it re-executes cleanly
            let stepIndex = executions[i].currentStepIndex
            if stepIndex < executions[i].stepResults.count,
               executions[i].stepResults[stepIndex].status == .running {
                executions[i].stepResults[stepIndex].status = .pending
                executions[i].stepResults[stepIndex].error = nil
            }

            let pipelines = store.loadPipelines()
            guard let pipeline = pipelines.first(where: { $0.id == executions[i].pipelineId }) else { continue }
            let enabledSteps = pipeline.steps.filter(\.isEnabled)
            let executionId = executions[i].id

            Task {
                await runNextStep(executionId: executionId, steps: enabledSteps)
            }
        }
        saveExecutions()
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

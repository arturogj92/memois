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

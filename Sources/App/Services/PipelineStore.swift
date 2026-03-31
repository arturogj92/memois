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

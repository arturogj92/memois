import SwiftUI

// MARK: - Brand palette (mirrors MainWindowView)

private extension Color {
    static let brandCyan = Color(red: 0.0, green: 0.85, blue: 0.95)
    static let brandGreen = Color(red: 0.3, green: 0.95, blue: 0.4)
    static let brandYellow = Color(red: 1.0, green: 0.85, blue: 0.1)
    static let brandPink = Color(red: 1.0, green: 0.3, blue: 0.6)

    static let surfaceBase = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surfaceCard = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surfaceInput = Color(red: 0.14, green: 0.14, blue: 0.16)
}

struct PipelinesSettingsView: View {
    @ObservedObject var model: AppModel

    @State private var isAddingPipeline = false
    @State private var newPipelineName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if isAddingPipeline {
                addPipelineForm
            }
            if model.pipelines.isEmpty && !isAddingPipeline {
                emptyState
            } else {
                ForEach(model.pipelines) { pipeline in
                    PipelineCardView(pipeline: pipeline, model: model)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Pipelines")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            if !model.pipelines.isEmpty {
                Text("\(model.pipelines.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Spacer()
            Button {
                isAddingPipeline = true
                newPipelineName = ""
            } label: {
                HStack(spacing: 5) {
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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.15))
            Text("No pipelines yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.25))
            Text("Create a pipeline to automate post-recording steps")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.15))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    // MARK: - Add Pipeline Form

    private var addPipelineForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Pipeline")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            TextField("Pipeline name", text: $newPipelineName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.surfaceInput)
                )

            HStack(spacing: 8) {
                Spacer()
                Button {
                    isAddingPipeline = false
                    newPipelineName = ""
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)

                Button {
                    let name = newPipelineName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    model.addPipeline(name: name)
                    isAddingPipeline = false
                    newPipelineName = ""
                } label: {
                    Text("Create")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.brandCyan.opacity(0.25))
                        )
                }
                .buttonStyle(.plain)
                .disabled(newPipelineName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.surfaceCard)
        )
    }
}

// MARK: - Pipeline Card

private struct PipelineCardView: View {
    let pipeline: Pipeline
    @ObservedObject var model: AppModel

    @State private var editingName: String = ""
    @State private var isEditingName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pipeline header
            HStack(spacing: 10) {
                // Name (editable inline)
                if isEditingName {
                    TextField("Pipeline name", text: $editingName, onCommit: {
                        var updated = pipeline
                        updated.name = editingName
                        model.updatePipeline(updated)
                        isEditingName = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.surfaceInput)
                    )

                    Button {
                        var updated = pipeline
                        updated.name = editingName
                        model.updatePipeline(updated)
                        isEditingName = false
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brandGreen)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(pipeline.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    Button {
                        editingName = pipeline.name
                        isEditingName = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Default toggle (star)
                Button {
                    model.setDefaultPipeline(id: pipeline.id)
                } label: {
                    Image(systemName: pipeline.isDefault ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(pipeline.isDefault ? Color.brandYellow : .white.opacity(0.3))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(pipeline.isDefault ? "Default pipeline" : "Set as default")

                // Enabled toggle
                Toggle("", isOn: Binding(
                    get: { pipeline.isEnabled },
                    set: { newValue in
                        var updated = pipeline
                        updated.isEnabled = newValue
                        model.updatePipeline(updated)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }

            if pipeline.isDefault {
                Text("Default")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.brandYellow.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.brandYellow.opacity(0.15)))
            }

            Divider().opacity(0.3)

            // Steps
            if pipeline.steps.isEmpty {
                Text("No steps added")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(pipeline.steps.enumerated()), id: \.element.id) { index, step in
                        StepRowView(
                            step: step,
                            pipeline: pipeline,
                            stepIndex: index,
                            model: model
                        )
                    }
                }
            }

            // Add Step + Delete
            HStack(spacing: 8) {
                Menu {
                    Button {
                        addStep(.autoTranscribe)
                    } label: {
                        Label("Auto Transcribe", systemImage: "waveform")
                    }
                    Button {
                        addStep(.assignSpeakers)
                    } label: {
                        Label("Assign Speakers", systemImage: "person.2")
                    }
                    Button {
                        addStep(.claudeCode(ClaudeCodeConfig()))
                    } label: {
                        Label("Claude Code", systemImage: "terminal")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                        Text("Add Step")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.06))
                    )
                }

                Spacer()

                Button {
                    model.deletePipeline(id: pipeline.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("Delete")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.brandPink.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.brandPink.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.surfaceCard)
        )
    }

    private func addStep(_ type: StepType) {
        var updated = pipeline
        updated.steps.append(PipelineStep(type: type))
        model.updatePipeline(updated)
    }
}

// MARK: - Step Row

private struct StepRowView: View {
    let step: PipelineStep
    let pipeline: Pipeline
    let stepIndex: Int
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: step.type.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brandCyan.opacity(0.7))
                    .frame(width: 18)

                Text(step.type.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                if step.type.isManual {
                    Text("Manual")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.brandYellow.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.brandYellow.opacity(0.15)))
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { step.isEnabled },
                    set: { newValue in
                        var updated = pipeline
                        updated.steps[stepIndex].isEnabled = newValue
                        model.updatePipeline(updated)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)

                Button {
                    var updated = pipeline
                    updated.steps.remove(at: stepIndex)
                    model.updatePipeline(updated)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Claude Code expanded config
            if case .claudeCode(let config) = step.type {
                claudeCodeConfig(config)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.03))
        )
    }

    @ViewBuilder
    private func claudeCodeConfig(_ config: ClaudeCodeConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Directory path
            VStack(alignment: .leading, spacing: 4) {
                Text("Directory")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))

                HStack(spacing: 6) {
                    TextField("Working directory path", text: Binding(
                        get: { config.directoryPath },
                        set: { newValue in
                            var updated = pipeline
                            updated.steps[stepIndex].type = .claudeCode(
                                ClaudeCodeConfig(directoryPath: newValue, promptPrefix: config.promptPrefix)
                            )
                            model.updatePipeline(updated)
                        }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.surfaceInput)
                    )

                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.message = "Select working directory for Claude Code"
                        if panel.runModal() == .OK, let url = panel.url {
                            var updated = pipeline
                            updated.steps[stepIndex].type = .claudeCode(
                                ClaudeCodeConfig(directoryPath: url.path, promptPrefix: config.promptPrefix)
                            )
                            model.updatePipeline(updated)
                        }
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // Prompt prefix
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt Prefix")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))

                TextField("Instructions prepended to the transcript...", text: Binding(
                    get: { config.promptPrefix },
                    set: { newValue in
                        var updated = pipeline
                        updated.steps[stepIndex].type = .claudeCode(
                            ClaudeCodeConfig(directoryPath: config.directoryPath, promptPrefix: newValue)
                        )
                        model.updatePipeline(updated)
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.surfaceInput)
                )
            }
        }
        .padding(.leading, 26)
    }
}

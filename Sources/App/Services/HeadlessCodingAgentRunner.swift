import Foundation

enum HeadlessCodingAgentRunner {
    struct ExecutableResolution {
        let overridePath: String?
        let autoDetectedPath: String?
        let selectedPath: String?
        let searchedLocations: [String]

        var isUsingOverride: Bool {
            guard let overridePath else { return false }
            return selectedPath == overridePath
        }
    }

    static func run(
        _ agent: HeadlessCodingAgent,
        prompt: String,
        directory: String,
        executablePathOverride: String? = nil
    ) async -> (Bool, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let resolution = resolveExecutablePath(for: agent, overridePath: executablePathOverride)

                guard let execPath = resolution.selectedPath else {
                    log(
                        "ERROR: \(agent.displayName) binary not found. Searched: \(resolution.searchedLocations)",
                        agent: agent
                    )
                    continuation.resume(
                        returning: (
                            false,
                            "\(agent.displayName) binary not found. Searched:\n\(resolution.searchedLocations.joined(separator: "\n"))"
                        )
                    )
                    return
                }

                log("Found \(agent.executableName) at: \(execPath)", agent: agent)

                guard FileManager.default.fileExists(atPath: directory) else {
                    log("ERROR: Directory not found: \(directory)", agent: agent)
                    continuation.resume(returning: (false, "Directory not found: \(directory)"))
                    return
                }

                let outputFileURL: URL? =
                    if agent == .codex {
                        FileManager.default.temporaryDirectory
                            .appendingPathComponent("memois_codex_response_\(UUID().uuidString)")
                            .appendingPathExtension("txt")
                    } else {
                        nil
                    }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: execPath)
                process.arguments = arguments(for: agent, prompt: prompt, outputFileURL: outputFileURL)
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.environment = executionEnvironment(forExecutableAt: execPath)

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                let inputPipe = Pipe()
                if agent == .codex {
                    process.standardInput = inputPipe
                }

                log(
                    "Launching \(agent.displayName): \(execPath) \(process.arguments?.joined(separator: " ") ?? "") in \(directory)",
                    agent: agent
                )

                do {
                    try process.run()

                    if agent == .codex {
                        if let data = prompt.data(using: .utf8) {
                            inputPipe.fileHandleForWriting.write(data)
                        }
                        inputPipe.fileHandleForWriting.closeFile()
                    }

                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    let combinedOutput = String(data: data, encoding: .utf8) ?? ""
                    let output = preferredOutput(
                        for: agent,
                        combinedOutput: combinedOutput,
                        outputFileURL: outputFileURL
                    )

                    log(
                        "Process exited: status=\(process.terminationStatus), output bytes=\(data.count)",
                        agent: agent
                    )
                    if process.terminationStatus != 0 {
                        let snippetSource = output.isEmpty ? combinedOutput : output
                        let snippet = snippetSource.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !snippet.isEmpty {
                            log("Process failure output: \(snippet.prefix(1000))", agent: agent)
                        }
                    }

                    if let outputFileURL {
                        try? FileManager.default.removeItem(at: outputFileURL)
                    }

                    continuation.resume(returning: (process.terminationStatus == 0, output))
                } catch {
                    log("ERROR launching process: \(error)", agent: agent)
                    if let outputFileURL {
                        try? FileManager.default.removeItem(at: outputFileURL)
                    }
                    continuation.resume(returning: (false, "Failed to launch: \(error.localizedDescription)"))
                }
            }
        }
    }

    static func resolveExecutablePath(
        for agent: HeadlessCodingAgent,
        overridePath: String? = nil
    ) -> ExecutableResolution {
        let normalizedOverride = normalizedPath(overridePath)
        let validOverride = normalizedOverride.flatMap { path in
            isRunnableExecutable(atPath: path) ? path : nil
        }
        let autoDetectedPath = autoDetectedExecutablePath(for: agent)

        return ExecutableResolution(
            overridePath: normalizedOverride,
            autoDetectedPath: autoDetectedPath,
            selectedPath: validOverride ?? autoDetectedPath,
            searchedLocations: searchedLocations(for: agent, overridePath: normalizedOverride)
        )
    }

    static func log(_ message: String, agent: HeadlessCodingAgent) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folderURL = appSupport.appendingPathComponent("Memois", isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let logURL = folderURL.appendingPathComponent(agent.logFileName)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func arguments(for agent: HeadlessCodingAgent, prompt: String, outputFileURL: URL?) -> [String] {
        switch agent {
        case .claudeCode:
            return ["--dangerously-skip-permissions", "-p", prompt]
        case .codex:
            var arguments = [
                "exec",
                "--skip-git-repo-check",
                "--dangerously-bypass-approvals-and-sandbox",
            ]
            if let outputFileURL {
                arguments.append(contentsOf: ["--output-last-message", outputFileURL.path])
            }
            arguments.append("-")
            return arguments
        }
    }

    private static func preferredOutput(
        for agent: HeadlessCodingAgent,
        combinedOutput: String,
        outputFileURL: URL?
    ) -> String {
        guard agent == .codex,
              let outputFileURL,
              let message = try? String(contentsOf: outputFileURL, encoding: .utf8)
        else {
            return combinedOutput
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? combinedOutput : message
    }

    private static func autoDetectedExecutablePath(for agent: HeadlessCodingAgent) -> String? {
        shellResolvedExecutablePath(named: agent.executableName, loginShell: true)
            ?? environmentResolvedExecutablePath(named: agent.executableName)
            ?? candidatePaths(for: agent).first(where: { isRunnableExecutable(atPath: $0) })
    }

    private static func candidatePaths(for agent: HeadlessCodingAgent) -> [String] {
        let home = NSHomeDirectory()

        switch agent {
        case .claudeCode:
            return [
                "\(home)/.local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude",
                "\(home)/.claude/local/claude",
            ]
        case .codex:
            var paths = [
                "/usr/local/bin/codex",
                "/usr/bin/codex",
                "/opt/homebrew/bin/codex",
                "/Applications/Codex.app/Contents/MacOS/codex",
                "\(home)/.volta/bin/codex",
                "\(home)/.local/share/pnpm/codex",
                "\(home)/Library/pnpm/codex",
                "\(home)/.yarn/bin/codex",
                "\(home)/.asdf/shims/codex",
                "\(home)/.local/bin/codex",
            ]

            let fm = FileManager.default
            let nvmVersionsDir = "\(home)/.nvm/versions/node"
            if let versions = try? fm.contentsOfDirectory(atPath: nvmVersionsDir) {
                paths.append(contentsOf: versions.map { "\(nvmVersionsDir)/\($0)/bin/codex" })
            }

            let fnmVersionsDir = "\(home)/.fnm/node-versions"
            if let versions = try? fm.contentsOfDirectory(atPath: fnmVersionsDir) {
                paths.append(contentsOf: versions.map { "\(fnmVersionsDir)/\($0)/installation/bin/codex" })
            }

            return deduplicatedPaths(paths)
        }
    }

    private static func shellResolvedExecutablePath(named executableName: String, loginShell: Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = loginShell ? ["-l", "-c", "command -v \(executableName)"] : ["-c", "command -v \(executableName)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            guard let path = normalizedPath(String(data: data, encoding: .utf8)),
                  isRunnableExecutable(atPath: path)
            else {
                return nil
            }

            return path
        } catch {
            return nil
        }
    }

    private static func executionEnvironment(forExecutableAt executablePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path

        let mergedPath = mergedSearchPath(components: [
            executableDirectory,
            shellEnvironmentValue(named: "PATH", loginShell: true),
            environment["PATH"],
        ])

        if !mergedPath.isEmpty {
            environment["PATH"] = mergedPath
        }

        return environment
    }

    private static func shellEnvironmentValue(named variableName: String, loginShell: Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = loginShell ? ["-l", "-c", "printenv \(variableName)"] : ["-c", "printenv \(variableName)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            return normalizedPath(String(data: data, encoding: .utf8))
        } catch {
            return nil
        }
    }

    private static func mergedSearchPath(components: [String?]) -> String {
        var seen = Set<String>()
        var directories: [String] = []

        for component in components {
            let segments = component?
                .split(separator: ":")
                .map(String.init) ?? []

            for segment in segments where !segment.isEmpty {
                guard seen.insert(segment).inserted else { continue }
                directories.append(segment)
            }
        }

        return directories.joined(separator: ":")
    }

    private static func environmentResolvedExecutablePath(named executableName: String) -> String? {
        let paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        for directory in paths where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(executableName)
                .path
            if isRunnableExecutable(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func searchedLocations(
        for agent: HeadlessCodingAgent,
        overridePath: String?
    ) -> [String] {
        var locations: [String] = []

        if let overridePath {
            locations.append("Custom override: \(overridePath)")
        }

        locations.append("Login shell lookup: command -v \(agent.executableName)")
        locations.append("Environment PATH lookup: \(ProcessInfo.processInfo.environment["PATH"] ?? "(empty)")")
        locations.append(contentsOf: candidatePaths(for: agent))

        return deduplicatedPaths(locations)
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NSString(string: trimmed).expandingTildeInPath
    }

    private static func isRunnableExecutable(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private static func deduplicatedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for path in paths {
            guard seen.insert(path).inserted else { continue }
            result.append(path)
        }

        return result
    }
}

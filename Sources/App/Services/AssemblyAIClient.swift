import Foundation

@MainActor
final class AssemblyAIClient {
    struct TranscriptResponse: Codable {
        let id: String
        let status: String
        let text: String?
        let utterances: [Utterance]?
        let error: String?

        struct Utterance: Codable {
            let speaker: String
            let text: String
            let start: Int
            let end: Int
        }
    }

    private let baseURL = "https://api.assemblyai.com/v2"

    /// Upload a local audio file and return the upload URL
    func upload(fileURL: URL, apiKey: String, onProgress: ((Double) -> Void)? = nil) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        var request = URLRequest(url: URL(string: "\(baseURL)/upload")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "AssemblyAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }

        struct UploadResponse: Codable { let upload_url: String }
        let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: responseData)
        return uploadResponse.upload_url
    }

    /// Submit a transcription request and return the transcript ID
    func transcribe(audioURL: String, apiKey: String, model: String, speakerLabels: Bool) async throws -> String {
        var body: [String: Any] = [
            "audio_url": audioURL,
            "speaker_labels": speakerLabels,
        ]

        // Map model setting to AssemblyAI speech_models (list format)
        switch model {
        case "nano":
            body["speech_model"] = "nano"
        default:
            body["speech_models"] = ["universal-3-pro"]
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/transcript")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "AssemblyAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Transcription request failed: \(errorBody)"])
        }

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)
        return transcript.id
    }

    /// Poll for transcription result until completed or failed
    func poll(transcriptID: String, apiKey: String) async throws -> TranscriptResponse {
        while true {
            var request = URLRequest(url: URL(string: "\(baseURL)/transcript/\(transcriptID)")!)
            request.setValue(apiKey, forHTTPHeaderField: "authorization")

            let (data, _) = try await URLSession.shared.data(for: request)
            let result = try JSONDecoder().decode(TranscriptResponse.self, from: data)

            switch result.status {
            case "completed":
                return result
            case "error":
                throw NSError(domain: "AssemblyAI", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: result.error ?? "Transcription failed"
                ])
            default:
                // queued or processing — wait and retry
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }
    }

    /// Format transcript with speaker labels
    func formatTranscript(_ response: TranscriptResponse) -> String {
        if let utterances = response.utterances, !utterances.isEmpty {
            return utterances.map { utterance in
                "Speaker \(utterance.speaker): \(utterance.text)"
            }.joined(separator: "\n\n")
        }
        return response.text ?? ""
    }
}

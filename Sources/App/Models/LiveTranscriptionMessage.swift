import Foundation

/// Inbound messages from AssemblyAI Universal-Streaming v3 WebSocket.
///
/// Verified against the official AssemblyAI Python SDK
/// (https://github.com/AssemblyAI/assemblyai-python-sdk/blob/master/assemblyai/streaming/v3/models.py).
enum LiveTranscriptionMessage {
    case begin(BeginPayload)
    case turn(TurnPayload)
    case termination(TerminationPayload)
    case speechStarted
    case error(code: Int?, message: String)
    case warning(code: Int, message: String)
    case unknown

    struct BeginPayload {
        let id: String
    }

    struct TurnPayload {
        let turnOrder: Int
        let turnIsFormatted: Bool
        let endOfTurn: Bool
        let transcript: String
        let endOfTurnConfidence: Double?
        let words: [Word]?
        let languageCode: String?
        let languageConfidence: Double?
    }

    struct TerminationPayload {
        let audioDurationSeconds: Int?
        let sessionDurationSeconds: Int?
    }

    struct Word {
        let start: Int
        let end: Int
        let confidence: Double
        let text: String
        let wordIsFinal: Bool
    }
}

extension LiveTranscriptionMessage: Decodable {
    private enum TopKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TopKeys.self)
        let type = try typeContainer.decode(String.self, forKey: .type)
        let single = try decoder.singleValueContainer()

        switch type {
        case "Begin":
            self = .begin(try single.decode(BeginPayload.self))
        case "Turn":
            self = .turn(try single.decode(TurnPayload.self))
        case "Termination":
            self = .termination(try single.decode(TerminationPayload.self))
        case "SpeechStarted":
            self = .speechStarted
        case "Error":
            struct E: Decodable { let error_code: Int?; let error: String }
            let e = try single.decode(E.self)
            self = .error(code: e.error_code, message: e.error)
        case "Warning":
            struct W: Decodable { let warning_code: Int; let warning: String }
            let w = try single.decode(W.self)
            self = .warning(code: w.warning_code, message: w.warning)
        default:
            self = .unknown
        }
    }
}

extension LiveTranscriptionMessage.BeginPayload: Decodable {}

extension LiveTranscriptionMessage.TurnPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case turn_order, turn_is_formatted, end_of_turn, transcript
        case end_of_turn_confidence, words, language_code, language_confidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnOrder = try c.decode(Int.self, forKey: .turn_order)
        turnIsFormatted = try c.decodeIfPresent(Bool.self, forKey: .turn_is_formatted) ?? false
        endOfTurn = try c.decodeIfPresent(Bool.self, forKey: .end_of_turn) ?? false
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        endOfTurnConfidence = try c.decodeIfPresent(Double.self, forKey: .end_of_turn_confidence)
        words = try c.decodeIfPresent([LiveTranscriptionMessage.Word].self, forKey: .words)
        languageCode = try c.decodeIfPresent(String.self, forKey: .language_code)
        languageConfidence = try c.decodeIfPresent(Double.self, forKey: .language_confidence)
    }
}

extension LiveTranscriptionMessage.TerminationPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case audio_duration_seconds, session_duration_seconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .audio_duration_seconds)
        sessionDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .session_duration_seconds)
    }
}

extension LiveTranscriptionMessage.Word: Decodable {
    private enum CodingKeys: String, CodingKey {
        case start, end, confidence, text, word_is_final
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        confidence = try c.decode(Double.self, forKey: .confidence)
        text = try c.decode(String.self, forKey: .text)
        wordIsFinal = try c.decodeIfPresent(Bool.self, forKey: .word_is_final) ?? false
    }
}

/// Outbound: tells the server to close the session cleanly.
struct LiveTranscriptionTerminate: Encodable {
    let type = "Terminate"
}

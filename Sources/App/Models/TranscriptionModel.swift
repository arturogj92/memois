import Foundation

/// The AssemblyAI speech models Memois can transcribe with.
///
/// The raw values are the model ids AssemblyAI expects in `speech_models`, so the
/// stored setting and the API payload never drift apart. Older builds stored
/// `"best"` (Universal-3 Pro) and `"nano"`, both deprecated by AssemblyAI — see
/// `migrate(storedID:)` for how those are carried over.
enum TranscriptionModel: String, CaseIterable {
    case universal35Pro = "universal-3-5-pro"
    case universal2 = "universal-2"

    static let `default`: TranscriptionModel = .universal35Pro

    var label: String {
        switch self {
        case .universal35Pro: "Universal-3.5 Pro (Best)"
        case .universal2: "Universal-2 (Cheaper, 99 languages)"
        }
    }

    /// USD per hour of audio, from AssemblyAI's pricing page.
    var pricePerHourUSD: Double {
        switch self {
        case .universal35Pro: 0.21
        case .universal2: 0.15
        }
    }

    /// Models sent to AssemblyAI, in priority order. Universal-3.5 Pro only covers
    /// 18 languages, so Universal-2 rides behind it as the fallback for the rest.
    var speechModels: [String] {
        switch self {
        case .universal35Pro: [Self.universal35Pro.rawValue, Self.universal2.rawValue]
        case .universal2: [Self.universal2.rawValue]
        }
    }

    // MARK: - Legacy ids

    /// Maps a stored setting to a model that still exists. `"best"` was Universal-3 Pro
    /// and `"nano"` was the cheap tier; AssemblyAI deprecated both.
    static func migrate(storedID: String?) -> TranscriptionModel {
        switch storedID {
        case "nano": .universal2
        default: TranscriptionModel(rawValue: storedID ?? "") ?? .default
        }
    }

    static func speechModels(for storedID: String) -> [String] {
        migrate(storedID: storedID).speechModels
    }

    /// Human-readable name for any model id we may have recorded, including retired ones.
    static func label(forRecordedID id: String) -> String {
        switch id {
        case "best": "Universal-3 Pro (retired)"
        case "nano": "Nano (retired)"
        default: TranscriptionModel(rawValue: id)?.label ?? id
        }
    }

    /// Price used for cost estimates over historical stats, retired models included.
    static func pricePerHourUSD(forRecordedID id: String) -> Double {
        switch id {
        case "best": 0.15
        case "nano": 0.0265
        default: TranscriptionModel(rawValue: id)?.pricePerHourUSD ?? TranscriptionModel.default.pricePerHourUSD
        }
    }
}

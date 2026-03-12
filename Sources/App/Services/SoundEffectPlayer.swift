import AudioToolbox
import Foundation

@MainActor
final class SoundEffectPlayer {
    enum Effect {
        case recordingStarted
        case recordingLocked
        case recordingStopped
    }

    static let availableSounds: [String] = [
        "Blow", "Bottle", "Frog", "Funk", "Glass",
        "Hero", "Morse", "Ping", "Pop", "Purr",
        "Sosumi", "Submarine", "Tink"
    ]

    var isEnabled = true

    private var soundIDs: [String: SystemSoundID] = [:]

    init() {
        for name in Self.availableSounds {
            let url = URL(filePath: "/System/Library/Sounds/\(name).aiff", directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var soundID: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == noErr {
                soundIDs[name] = soundID
            }
        }
    }

    func play(_ effect: Effect, soundName: String) {
        guard isEnabled, let soundID = soundIDs[soundName] else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    func preview(_ soundName: String) {
        guard let soundID = soundIDs[soundName] else { return }
        AudioServicesPlaySystemSound(soundID)
    }
}

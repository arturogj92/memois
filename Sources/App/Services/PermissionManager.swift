import AVFoundation
import Foundation
import AppKit
import ScreenCaptureKit

enum MicrophoneAuthStatus {
    case granted
    case denied
    case undetermined
}

struct PermissionStatus {
    let microphoneGranted: Bool
    let microphoneStatus: MicrophoneAuthStatus
    let screenRecordingGranted: Bool

    var allGranted: Bool {
        microphoneGranted && screenRecordingGranted
    }
}

@MainActor
final class PermissionManager {
    func currentStatus() -> PermissionStatus {
        let micStatus = microphoneAuthStatus
        return PermissionStatus(
            microphoneGranted: micStatus == .granted,
            microphoneStatus: micStatus,
            screenRecordingGranted: checkScreenRecordingPermission()
        )
    }

    func requestMicrophoneAccess() async -> Bool {
        MemoisDebugLog.shared.write("requestMicrophoneAccess: AVAudioApplication.recordPermission=\(AVAudioApplication.shared.recordPermission.rawValue) AVCaptureDevice.authStatus=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        if microphoneAuthStatus == .granted { return true }
        let granted = await AVAudioApplication.requestRecordPermission()
        MemoisDebugLog.shared.write("requestMicrophoneAccess: AVAudioApplication.requestRecordPermission returned \(granted)")
        if granted || microphoneAuthStatus == .granted { return true }
        let captureGranted = await AVCaptureDevice.requestAccess(for: .audio)
        MemoisDebugLog.shared.write("requestMicrophoneAccess: AVCaptureDevice.requestAccess returned \(captureGranted)")
        return captureGranted || microphoneAuthStatus == .granted
    }

    func requestScreenRecordingAccess() {
        // Trigger the permission prompt by attempting to get shareable content
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    var microphoneAuthStatus: MicrophoneAuthStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .denied
        case .undetermined:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .undetermined
        @unknown default:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .undetermined
        }
    }

    private func checkScreenRecordingPermission() -> Bool {
        // On macOS 14+, CGPreflightScreenCaptureAccess works for ScreenCaptureKit
        return CGPreflightScreenCaptureAccess()
    }
}

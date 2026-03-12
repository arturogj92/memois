import AVFoundation
import CoreGraphics
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
    let inputMonitoringGranted: Bool

    var allGranted: Bool {
        microphoneGranted && screenRecordingGranted && inputMonitoringGranted
    }
}

@MainActor
final class PermissionManager {
    func currentStatus() -> PermissionStatus {
        let micStatus = microphoneAuthStatus
        return PermissionStatus(
            microphoneGranted: micStatus == .granted,
            microphoneStatus: micStatus,
            screenRecordingGranted: checkScreenRecordingPermission(),
            inputMonitoringGranted: CGPreflightListenEventAccess()
        )
    }

    func requestMicrophoneAccess() async -> Bool {
        if microphoneAuthStatus == .granted { return true }
        let granted = await AVAudioApplication.requestRecordPermission()
        if granted || microphoneAuthStatus == .granted { return true }
        let captureGranted = await AVCaptureDevice.requestAccess(for: .audio)
        return captureGranted || microphoneAuthStatus == .granted
    }

    func requestScreenRecordingAccess() {
        // Trigger the permission prompt by attempting to get shareable content
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
    }

    func requestInputMonitoringAccess() {
        _ = CGRequestListenEventAccess()
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
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

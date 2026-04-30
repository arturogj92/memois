# Microphone Preflight Check — Design

**Date:** 2026-04-26
**Task:** #11290

## Problem

Today, hitting the global shortcut (or otherwise triggering recording) starts capture instantly. There's no way to verify the right microphone is selected or that audio is actually being detected before committing to the recording. Users can end up with silent or wrong-mic recordings.

## Goal

Add a preflight step that appears in the existing dock pill (`DockTabView`) before recording begins. The preflight shows:

- A microphone selector (reuses existing `AudioDevice.inputDevices()` + `selectedMicrophoneUID` setting)
- Two live audio level bars: mic input (green) and system audio (cyan)
- A recording-name text field (so the title can be set up front)
- Start and Cancel buttons

Toggleable via a new setting **"Confirm microphone before recording"** — default ON. When OFF, the shortcut starts recording instantly (current behavior).

## Flow

1. Shortcut press / record action → if setting ON, enter `.preparing`. If OFF, go straight to `.recording`.
2. In `.preparing` the dock panel renders the preflight content. Audio preview starts: `AVAudioEngine` for the mic + `SCStream` for system audio, feeding the existing `onMicLevel` / `onSystemLevel` callbacks. No writer, no chunks, nothing on disk.
3. Changing the mic in the picker hot-swaps the input device on the running engine.
4. **Start** (button or Enter) → preview stops, normal `startRecording()` proceeds with the chosen mic UID and prefilled name. The pill transitions in place into the recording state.
5. **Cancel** (button, Esc, or pressing the global shortcut again) → preview stops, return to `.idle`, pill hides.

## State machine change

`AppModel.SessionState` gains `.preparing`:

```
.idle  ──shortcut──▶ .preparing ──Start──▶ .recording ──stop──▶ .idle
   │                       │
   │                       └──Cancel──▶ .idle
   └──(setting OFF)──▶ .recording
```

## UI (DockTabView)

The dock panel (`NSPanel` controlled by `DockTabController`) gains a new render branch for `.preparing`:

```
┌──────────────────────────────────────┐
│ 🎙  Ready to record       Opt+Shift+R│
│                                      │
│ Mic: [Built-in Microphone ▾]         │
│                                      │
│ 🎤 ████░░░░░░░░░  Mic                │
│ 🔈 ██░░░░░░░░░░░  System             │
│                                      │
│ [Recording name (optional)…]         │
│                                      │
│ [ Cancel ]      [ Start Recording ]  │
└──────────────────────────────────────┘
```

The panel is taller (~200pt) than the recording pill. Keyboard focus is on the TextField; Enter triggers Start, Esc triggers Cancel.

## File changes

| File | Change |
|---|---|
| `SettingsStore.swift` | New `@Published var confirmMicBeforeRecording: Bool = true` |
| `AudioRecorder.swift` | `startPreview(deviceUID:)`, `stopPreview()`, `switchPreviewDevice(uid:)` |
| `AppModel.swift` | New `.preparing` case + `enterPreflight()`, `cancelPreflight()`, `confirmAndStartRecording()`, `changePreflightMic(uid:)` |
| `DockTabView.swift` | New `preflightContent` view + branch render |
| `DockTabController.swift` | `.preparing` → `allowKeyboard = true`, makeKey, larger pill rect |
| `AppDelegate.swift` | `$sessionState` sink hides panel on `.idle`/`.error`, shows on `.preparing`/`.recording` |
| `MainWindowView.swift` | Toggle "Confirm microphone before recording" in Microphone card |

## What is NOT changing

- The chunked recording / merge pipeline
- `GlobalShortcutMonitor` — same handler, just dispatches to a richer `toggleRecording`
- `FloatingPanelView.swift` — already unused dead code
- Transcription / AssemblyAI flow

## Manual verification

1. Default install (setting ON): shortcut → preflight pill appears, both bars react to voice and to system audio playback. Type title, Enter → recording starts in same pill with timer.
2. Cancel paths: Esc, second shortcut press, click Cancel — all return to idle and stop preview.
3. Hot-swap mic in picker → mic bar reflects the new device immediately.
4. Toggle setting OFF → shortcut starts recording directly (no preflight).
5. With existing recording in progress → shortcut still stops it (no preflight on stop).

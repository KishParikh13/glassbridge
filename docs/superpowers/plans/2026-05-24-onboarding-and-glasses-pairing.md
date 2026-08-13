# Onboarding + Glasses-Pairing Redesign — Implementation Plan

> **For agentic workers:** Implement task-by-task. Verification for this iOS app =
> `xcodebuild` compile + MockDeviceKit Simulator run + device install (no XCTest target).

**Goal:** Replace the confusing 3-tab UI with a Live home + guided Setup onboarding +
organized More, and rewrite glasses pairing to mirror Meta's canonical DAT 0.7 pattern.

**Architecture:** A canonical `GlassesSessionManager` (defers `DeviceSession` creation,
races state-vs-error streams, recreates on `.stopped`) under a slimmer `GlassesController`
that exposes one user-facing `ConnectionState`. SwiftUI splits into `LiveView` (home, owns
ASK), `SetupView` (onboarding + capability matrix), `MoreView` (connection + hands-free +
Advanced→existing Debug tools).

**Tech Stack:** Swift 5.10, SwiftUI, MWDATCore/MWDATCamera/MWDATMockDevice 0.7, xcodegen.

---

## File structure

New (`ios/Glassbridge/`):
- `ConnectionState.swift` — user-facing connection enum + reason; `DATErrorText` mapping for
  `RegistrationError`/`PermissionError`/`DeviceSessionError`/`StreamError`.
- `GlassesSessionManager.swift` — owns `DeviceSession`; `getSession()` racing error stream;
  `activeDeviceStream()` monitoring; recreate-on-`.stopped`.
- `PermissionsService.swift` — iOS mic / camera / speech / local-network checks + requests.
- `BackendHealth.swift` — `GET /healthz` reachability.
- `Capability.swift` — capability model + status/source enums; `CapabilityMatrixView`.
- `LiveView.swift` — home: source chip, preview, primary ASK, photo/record, rolling-context,
  reply sheet, recent strip. (absorbs AssistantView + CameraView capture UI)
- `Gallery.swift` — `MediaThumbnail`, `VideoThumbnail`, `MediaDetailView` (moved from CameraView).
- `SetupView.swift` — onboarding step list + capability matrix.
- `MoreView.swift` — connection, hands-free, quality, unregister, Advanced disclosure.

Rewrite:
- `GlassesController.swift` — registration + devices + compatibility listener + lazy permission;
  delegates session to `GlassesSessionManager`; keeps photo/video/preview/rolling-context.
- `ContentView.swift` — TabView Live / Setup / More.
- `SessionCoordinator.swift` — tab enum (`live/setup/more`), onboarding state, capability
  computeds, backend-health; ASK pipeline unchanged.

Keep ~unchanged: `AudioController`, `WakeWordListener`, `LiveActivityController`, `IPhoneCapture`,
`IPhoneVideoRecorder`, `VideoRecorder`, `CapturedMedia`, `BackendClient`, `Config`,
`GlassbridgeApp`, `MockSetup`. `DebugView` retained, embedded in More→Advanced.

## Key new interfaces (lock these names)

```swift
// ConnectionState.swift
enum ConnectionState: Equatable {
    case usingPhone            // glasses unavailable; iPhone fallback
    case metaAINotInstalled
    case readyToConnect        // RegistrationState.available
    case registering
    case connecting            // registered; waiting for a connected device
    case needsDeviceUpdate(String)   // compatibility .deviceUpdateRequired/.sdkUpdateRequired
    case needsCameraPermission
    case connected             // connected device + session startable
    case streaming             // stream live
    case problem(String)       // mapped typed-error reason
    var isGlassesLive: Bool { self == .streaming }
    var shortLabel: String { ... }   // for Live chip
    var detail: String { ... }       // for Setup step
}
enum DATErrorText { static func describe(_ error: Error) -> String }  // typed → plain language

// GlassesSessionManager.swift  (mirrors CameraAccess DeviceSessionManager)
@MainActor final class GlassesSessionManager {
    private(set) var hasActiveDevice: Bool
    private(set) var isReady: Bool
    func getSession() async throws -> DeviceSession   // waits for .started, races errorStream
    func cleanup()
}

// Capability.swift
enum CapabilitySource { case glasses, iPhone, backend, onDevice }
enum CapabilityStatus { case ready, glassesOnly, needsPermission, unavailable }
struct Capability: Identifiable { let id, name; let status: CapabilityStatus; let source: String }
struct CapabilityMatrixView: View { let items: [Capability] }
```

---

## Tasks

### Task 1: `ConnectionState` + `DATErrorText`
**Files:** Create `ios/Glassbridge/ConnectionState.swift`
- [ ] Define `ConnectionState` enum + `shortLabel`/`detail`/`isGlassesLive`.
- [ ] Define `DATErrorText.describe` mapping each `RegistrationError`, `PermissionError`,
      `DeviceSessionError` (incl. `.batteryCritical`, `.thermalCritical`,
      `.datAppOnTheGlassesUpdateRequired`, `.noEligibleDevice`), `StreamError` case → sentence.
- [ ] Verify: file compiles (built with Task 3).

### Task 2: `GlassesSessionManager`
**Files:** Create `ios/Glassbridge/GlassesSessionManager.swift`
- [ ] Port CameraAccess `DeviceSessionManager`: `AutoDeviceSelector`, `startDeviceMonitoring()`
      via `activeDeviceStream()`, `getSession()` with `waitForSessionStart` racing
      `stateStream()` vs `errorStream()` in a throwing task group, `startStateObserver` clearing
      session on `.stopped`, `cleanup()`.
- [ ] Verify: compiles (with Task 3).

### Task 3: Rewrite `GlassesController`
**Files:** Modify `ios/Glassbridge/GlassesController.swift`
- [ ] Keep `@Published` UI signals (previewImage, measuredFPS, quality/frameRate, contextFrames,
      isRecording, debugLog) and the stream/photo/video/rolling-context logic.
- [ ] Replace eager-session logic with `GlassesSessionManager`. Add per-device compatibility
      monitoring (`deviceForIdentifier` + `addCompatibilityListener`) → `connectionState`.
- [ ] Add lazy camera permission at stream start (`checkPermissionStatus` → `requestPermission`).
- [ ] Expose `@Published var connectionState: ConnectionState` derived from registration +
      hasActiveDevice + compatibility + permission + stream state.
- [ ] Add `connect()` (startRegistration, guard `.registering`, catch typed),
      `openFirmwareUpdate()`/`openDATGlassesAppUpdate()`, `startStreaming()` (permission→getSession→addStream).
- [ ] Verify: `xcodebuild` device build succeeds.

### Task 4: `PermissionsService` + `BackendHealth`
**Files:** Create `PermissionsService.swift`, `BackendHealth.swift`
- [ ] `PermissionsService`: async check/request for mic (`AVAudioApplication`), camera
      (`AVCaptureDevice`), speech (`SFSpeechRecognizer`); `localNetworkPrime()` (a no-op fetch to
      the backend to trigger the OS prompt). Each returns a small status enum.
- [ ] `BackendHealth.check(url:)` → `GET /healthz`, returns reachable Bool + latency.
- [ ] Verify: compiles.

### Task 5: `Capability` + `CapabilityMatrixView`
**Files:** Create `Capability.swift`
- [ ] Model + `CapabilityMatrixView` (rows: icon, name, status badge, source text).
- [ ] Verify: SwiftUI preview/compile.

### Task 6: `SessionCoordinator` updates
**Files:** Modify `ios/Glassbridge/SessionCoordinator.swift`
- [ ] Tab enum → `.live/.setup/.more`. Add onboarding flags (`hasCompletedOnboarding` via
      `@AppStorage`), permission statuses, backend reachability, `capabilities: [Capability]`
      computed from glasses.connectionState + permission states.
- [ ] Keep `performAsk`/`askPressed`/`askAboutMedia` untouched (capability lives in Live now).
- [ ] Verify: compiles.

### Task 7: `Gallery.swift` + `LiveView`
**Files:** Create `Gallery.swift`, `LiveView.swift`; the gallery types move out of CameraView.
- [ ] Move `MediaThumbnail`/`VideoThumbnail`/`MediaDetailView` into `Gallery.swift`.
- [ ] `LiveView`: source chip from `connectionState`, preview (glasses) / iPhone hint, primary
      ASK button (calls `coordinator.askPressed()`), Photo/Record, rolling-context toggle, reply
      sheet (transcript/reply/latency), recent-captures strip. Condensed capability hint.
- [ ] Verify: device build.

### Task 8: `SetupView`
**Files:** Create `SetupView.swift`
- [ ] Step list (Welcome, Mic, Camera, Speech, Backend, Glasses sub-flow, Done) each with live
      status + fix action; Glasses step renders `connectionState.detail` + Connect / Update /
      Test buttons. Capability matrix at the bottom. Skippable.
- [ ] Verify: device build.

### Task 9: `MoreView` (+ retain Debug)
**Files:** Create `MoreView.swift`; keep `DebugView.swift`
- [ ] Connection details + hands-free toggle + quality/frame-rate + unregister; `DisclosureGroup`
      "Advanced (Developer)" embedding existing `DebugView` body sections.
- [ ] Verify: device build.

### Task 10: `ContentView` + wire up
**Files:** Modify `ContentView.swift`; run `xcodegen generate`
- [ ] TabView Live/Setup/More; first-launch `.sheet`/selection → Setup when `!hasCompletedOnboarding`.
- [ ] `xcodegen generate`; `xcodebuild` device build; install to iPhone.
- [ ] Commit.

### Task 11: MockDeviceKit Simulator verification
**Files:** Modify `MockSetup.swift` / `GlassbridgeApp.swift` (DEBUG only)
- [ ] Enable MockDeviceKit with `initiallyRegistered`, `initialPermissionsGranted`, camera feed.
- [ ] Run in Simulator: assert `connectionState` reaches `.streaming`, ASK round-trips against the
      live backend, fold/unfold returns to `.streaming` (recreated session), and an injected error
      surfaces via `DATErrorText`.
- [ ] Commit.

---

## Self-review notes
- Spec coverage: nav (T7-10), capability matrix (T5,T8), onboarding (T8), pairing rewrite
  (T1-3), typed errors (T1,T3), self-test (T11) — all covered.
- Types consistent: `ConnectionState`, `GlassesSessionManager.getSession()`, `Capability` used
  uniformly across tasks.
- iOS reality: verification is compile + MockDevice + device install, stated up front.

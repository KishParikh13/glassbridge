# Glassbridge — Onboarding + Glasses-Pairing Redesign

Date: 2026-05-24
Status: Approved (design)

## Problem

Three issues, from live testing on iPhone 17 Pro + Ray-Ban glasses:

1. **The app is confusing.** Three tabs (Assistant / Camera / Debug), no guided
   setup, no clear statement of what works and what is connected to what.
2. **The standalone ASK button page isn't wanted.** The ASK *capability* (voice +
   vision Q&A) must stay, but its dedicated page should go.
3. **Glasses pairing is flaky.** The current `GlassesController` diverges from
   Meta's canonical DAT 0.7 pattern in ways that each cause real failures.

Constraints: do not delete functionality; make capability + source (Glasses vs
iPhone vs backend) legible everywhere; keep the iPhone-only path working at all
times.

## Root causes of flaky pairing (from Meta's DAT 0.7 sources)

Verified against `MWDATCore` swiftinterface, Meta's DAT agent skills
(permissions-registration, session-lifecycle, debugging), and the canonical
`CameraAccess` sample (`DeviceSessionManager`, `WearablesViewModel`,
`StreamSessionViewModel`).

1. Treats "device id present in `devicesStream`" as "device ready." Never checks
   `Device.linkState == .connected` or uses `AutoDeviceSelector.activeDeviceStream()`.
   A folded/asleep device shows an id but is not connected → session/stream stalls.
2. Eagerly creates the `DeviceSession` on every registration/device event. The
   canonical pattern **defers** creation to an on-demand `getSession()` to avoid races.
3. Requests camera permission too early (on `.registered`, before a connected
   device exists) → `PermissionError.noDevice`. Canonical flow checks/requests
   permission **at stream start**.
4. Never observes the session `errorStream()`, so `batteryCritical`,
   `thermalCritical`, `datAppOnTheGlassesUpdateRequired`, `noEligibleDevice` are
   invisible. Canonical pattern **races state-vs-error streams** on start.
5. No compatibility/firmware check. `.deviceUpdateRequired` / `.sdkUpdateRequired`
   fail silently. Canonical pattern monitors `addCompatibilityListener` and offers
   `openFirmwareUpdate()` / `openDATGlassesAppUpdate()`.
6. Doesn't recreate the session after `.stopped` or correctly hold during `.paused`.

## Design

### Navigation (replaces Assistant / Camera / Debug)

- **Live** (home): source chip (Glasses/iPhone), live preview (glasses stream) or
  iPhone camera, **ASK** as the primary button, Photo / Record beside it,
  rolling-context toggle, reply shown in a sheet, recent-captures strip. This is
  where the ASK capability now lives.
- **Setup**: the onboarding flow, always re-runnable; per-step live status; ends
  with the capability matrix.
- **More**: connection details, Hands-free (wake word) toggle, quality/frame rate,
  unregister, and an **Advanced (Developer)** disclosure that retains *all* current
  Debug tools (audio route, mic meter, loopback, test tone, event log).

### Capability matrix

Compact table in Setup (condensed strip on Live). Each row → status + source:

| Capability | Status | Source |
|---|---|---|
| Voice Q&A (ASK) | Ready | iPhone mic+cam now → upgrades to Glasses when connected |
| Photo / Video | Ready | iPhone (or Glasses) |
| Live preview | Glasses only | needs Glasses streaming |
| Rolling context | Glasses only | needs Glasses streaming |
| Wake word "hey glass" | needs Speech permission | on-device |
| Backend (Claude) | reachable / not | Mac LAN URL |

### Onboarding flow (Setup tab; auto-shown first launch; skippable, not blocking)

1. Welcome — works with iPhone alone, better with glasses.
2. Microphone (iOS) — required for voice.
3. Camera (iOS) — for iPhone capture fallback.
4. Speech Recognition (iOS) — for wake word; skippable.
5. Backend — trigger Local Network prompt, ping `/healthz`, show reachable + URL.
6. Glasses (robust sub-flow, each sub-step shows status + fix hint):
   Connect (`startRegistration` → Meta AI) → wait for **connected** device
   (`linkState`) → **compatibility/firmware check** (offer `openFirmwareUpdate`) →
   **camera permission** (lazy) → **Test connection** (start session, grab one
   frame). Skippable → iPhone fallback.
7. Done — capability matrix.

### Pairing rewrite (`GlassesController`)

Mirror the canonical sample:

- New **`GlassesSessionManager`** owns the `DeviceSession`: defers creation to an
  on-demand `getSession()` that waits for `.started` while racing the error stream;
  recreates after `.stopped`; holds during `.paused`; monitors `activeDeviceStream()`
  for `hasActiveDevice`.
- Slimmer **`GlassesController`**: registration, devices, **per-device compatibility
  listener**, lazy camera permission (at stream start), high-level state.
- **Typed errors → plain language**: `RegistrationError`, `PermissionError`,
  `DeviceSessionError` (battery/thermal/update-required/noEligibleDevice),
  `StreamError` each map to a clear message + suggested action.
- A single user-facing `ConnectionState` enum carrying a *reason*; rendered by
  Live's chip and Setup's glasses step.
- Existing features (photo, video, preview, rolling context, wake word, Live
  Activity) re-wire onto the new session manager. Nothing removed.

### Decisions (approved)

- Onboarding is **skippable**, not blocking.
- Debug tools survive under **More → Advanced**, not a top-level tab.
- Backend URL stays compile-time for now (runtime field can come later).

## Testing strategy

- **Self-testable (no physical glasses):** `MWDATMockDevice` is already a
  dependency. DAT 0.6+ MockDeviceKit supports `initiallyRegistered`,
  `initialPermissionsGranted`, a simulated camera feed, and fold/unfold cycles.
  Drive the new pairing state machine in the Simulator: reaches connected/streaming,
  survives disconnect→reconnect, surfaces typed errors.
- Build-to-device (iPhone 17 Pro) + install verification.
- Backend `/ask` smoke tests (vision + tool-use) already passing.
- Real-glasses end-to-end still requires the user wearing them.

## Out of scope

- Runtime-editable backend URL.
- Display capability (`MWDATDisplay`) for Ray-Ban Display glasses.
- Changes to the Python backend.

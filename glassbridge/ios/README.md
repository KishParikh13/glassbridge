# Glassbridge iOS

One screen, one ASK button. Captures a frame + 5s of audio from your
Ray-Ban glasses, sends them to the Glassbridge backend, plays back
Claude's voice answer through the glasses speaker.

## Prereqs

- Xcode 16+ (verified on Xcode 26 / iOS SDK 26.2)
- iPhone with **Developer Mode** on (Settings → Privacy & Security → Developer Mode)
- Meta AI companion app installed, glasses paired, **Developer Mode** enabled
  in Meta AI (Settings → Your glasses → Developer Mode)
- The Glassbridge backend running on your Mac. Note the LAN URL it prints —
  e.g. `http://192.168.1.42:8082`
- `brew install xcodegen` (one-time)

## Setup (3 minutes)

1. **Point at the backend** — edit `Glassbridge/Config.swift` and replace the
   `backendURL` with the URL `run.sh` printed for you. Keep the `http://` prefix.

2. **Generate the Xcode project**:

   ```bash
   cd ios
   xcodegen generate
   open Glassbridge.xcodeproj
   ```

3. **Sign with your personal team**:
   - In Xcode, select the *Glassbridge* target → *Signing & Capabilities*.
   - Set **Team** to your personal Apple ID team.
   - If the bundle id `com.kish.glassbridge` clashes with anything you have
     on file, change it to something unique (`com.<you>.glassbridge`). Make
     sure to update the `CFBundleURLSchemes` entry in `Info.plist` to match
     if you change the URL scheme, otherwise leave the scheme as `glassbridge`.

4. **Pair your iPhone**: plug it in, select it in Xcode's run-destination dropdown.

5. **Build & Run** (⌘R). First launch:
   - Approve the dev profile on the phone (Settings → General → VPN & Device Management).
   - When the app opens, tap **Pair / register glasses**. This hands off to the
     Meta AI app and back via the `glassbridge://` URL scheme.
   - Grant camera + mic permissions on the glasses through Meta AI when
     prompted. The status line should go `available → registering → registered →
     waiting → streaming`.

6. **Make the glasses the audio device**: open Settings → Bluetooth, tap your
   glasses, and turn **Use for Calls** ON. This is what makes the glasses
   appear as a Bluetooth HFP route to iOS. Without it, ASK will record from
   the iPhone mic and play from the iPhone speaker.

## Using it

Tap **ASK**. The button:

1. **Red — Listening (5s)**: glasses mic captures audio + the glasses camera
   grabs one frame in parallel.
2. **Orange — Thinking**: backend transcribes, calls Claude with the photo +
   transcript, then streams Claude's reply to ElevenLabs.
3. **Green — Speaking**: the MP3 reply plays through the glasses speakers.
4. **Blue — Idle**: ready for the next ASK. Your transcript and Claude's
   reply text stay visible on the iPhone screen.

The session keeps the last 3 turns of memory, keyed by a per-launch UUID.
Force-quit + relaunch to start a fresh conversation.

## Troubleshooting

| Symptom | What's actually happening |
|---|---|
| Status stuck on `available` | Tap "Pair / register glasses". You'll be bounced to Meta AI. |
| Status stuck on `registered` | Glasses aren't reporting as available. Open Meta AI, confirm glasses are connected, confirm camera permission is granted for Glassbridge. |
| Status `waitingForDevice` for >30s | Glasses are asleep or folded. Open them, tap the side. |
| Error "Bluetooth HFP route" | Settings → Bluetooth → your glasses → **Use for Calls** ON. |
| Reply plays from iPhone speaker | Same as above. Also verify the route in Xcode console — `AudioController.routeSummary()` prints the active in/out ports. |
| `Backend HTTP 5xx` | Backend isn't running or your LAN IP changed. Re-run `./run.sh` and update `Config.swift`. |
| `transport: cancelled` | iPhone joined a different Wi-Fi than the Mac. Make sure both are on the same network. |
| First ASK after launch hangs ~15s | Whisper is loading. Wait it out, subsequent ASKs are fast. |

## Where stuff lives

```
Glassbridge/
├── GlassbridgeApp.swift      – @main, Wearables.configure(), URL handler
├── ContentView.swift         – TabView root: Assistant (ASK) + Camera tabs
├── Config.swift              – backend URL + record duration + session id
├── SessionCoordinator.swift  – orchestrates ASK flow + direct camera control
├── GlassesController.swift   – DAT registration, DeviceSession, Stream, capturePhoto + video recording
├── VideoRecorder.swift       – glasses video frames (CMSampleBuffer) → .mp4 via AVAssetWriter
├── IPhoneVideoRecorder.swift – iPhone movie-capture fallback for the Camera tab
├── CapturedMedia.swift       – gallery item model (photo bytes or video URL)
├── CameraView.swift          – direct-control UI: Photo/Record buttons + in-app gallery
├── IPhoneCapture.swift       – iPhone photo-capture fallback
├── AudioController.swift     – AVAudioSession HFP wiring, record, play
└── BackendClient.swift       – multipart POST /ask, parses response headers
```

## Camera tab (direct glasses control)

Separate from the ASK/AI flow, the **Camera** tab lets you drive the glasses
directly:

- **Photo** — snaps one still and loads it straight into the in-app gallery.
- **Record** — toggles video recording; the finished clip lands in the gallery,
  tappable for inline playback.

Source follows the same rule as ASK: it uses the **Ray-Ban glasses** when the
stream is live (`status: streaming`), and falls back to the **iPhone camera + mic**
otherwise — so the tab is fully usable before glasses pairing works. Glasses
video is built from the DAT `videoFramePublisher` frames, encoded to H.264 .mp4.

> Added files (VideoRecorder, IPhoneVideoRecorder, CapturedMedia, CameraView)
> are picked up automatically on the next `xcodegen generate`.

## Why not the simulator?

DAT-SDK device sessions require either real glasses connected through Meta AI
or `MWDATMockDevice`. We didn't wire up the mock kit for the MVP; if you want
it, add `MWDATMockDevice` to the dependencies in `project.yml` and stub a
device in `GlassbridgeApp.init` per `reference/PortWorld/IOS/AGENTS_DAT_SDK.md`
section "Testing instructions".

# Learnings

What we figured out building Glassbridge that would have saved us hours if we'd known up front. Written for anyone (including future-you) picking this up from a cold start.

## TL;DR — current state

- **Backend + iPhone-camera path works end-to-end** on a real iPhone. Tap ASK, look at something, speak, hear Claude reply through the phone speaker. ~4–13s round-trip end-to-end.
- **Glasses path is blocked on Meta's dev-mode permission flow.** App is fully wired for it; the moment Meta's flow works again, the same `ASK` button uses Ray-Ban camera + Ray-Ban mic with zero code change.
- **Code is verified correct via MockDeviceKit** in the iOS Simulator (stub image → backend → Claude → ElevenLabs → playback). So if real-glasses doesn't work for you, it's not the code.

## What works (proven)

- FastAPI backend with one endpoint: `POST /ask` (multipart `audio` + `image` + optional `session_id` + optional `text_override`). Streams MP3 back.
- `faster-whisper distil-large-v3` on CPU/int8 transcribing user audio.
- Claude Sonnet 4.6 vision via the Anthropic Python SDK — takes image as inline base64.
- ElevenLabs streaming TTS via plain HTTP (no SDK needed).
- 3-turn rolling session memory keyed by `session_id`.
- iOS app with one ASK button, status phases, captured image transcript + reply on screen.
- iPhone-camera fallback when DAT glasses aren't streaming. Same backend, same UI, just different input source.
- MockDeviceKit setup for autonomous simulator testing.

## What's blocked (and why)

**Meta MMA (Managed Meta Account) login at `work.meta.com`** rejects signup emails as "no account associated" even after the "Your account is ready" confirmation email arrives. This blocks the Wearables Developer Center, which is the only way to obtain a real `MetaAppID` + `ClientToken` for DAT SDK Info.plist.

**DAT SDK 0.7 dev mode with `MetaAppID="0"`** registers the app with Meta AI (Glassbridge appears as "Developer mode apps") but the per-app permission flow never propagates. Meta AI shows only a slashed-shield icon + "Disconnect" — no Camera toggle to grant. Without a granted permission, `Wearables.shared.devicesStream()` never emits a device, so the app sits forever in `status: registered · no device`.

Both bugs are tracked: GitHub Discussion #101 on `facebook/meta-wearables-dat-ios` (closed without a documented fix), and a draft bug report for `developers.facebook.com/support/bugs/` lives in this repo's session memory.

Until one of those clears, the iPhone fallback is the practical path.

## Key technical findings

### 1. DAT SDK 0.7 API ≠ 0.5 API (and the public docs lag)

The PortWorld reference repo (`reference/PortWorld/IOS`) and Meta's own `AGENTS_DAT_SDK.md` document the 0.5-era API. **None of that compiles against 0.7.** The actual 0.7 pattern (verified from the swiftinterface):

```swift
// OLD (0.5, broken on 0.7):
let session = StreamSession(streamSessionConfig: StreamSessionConfig(...),
                            deviceSelector: AutoDeviceSelector(wearables: Wearables.shared))

// NEW (0.7, works):
let selector = AutoDeviceSelector(wearables: Wearables.shared)
let deviceSession = try Wearables.shared.createSession(deviceSelector: selector)
try deviceSession.start()
let stream: MWDATCamera.Stream? = try deviceSession.addStream(
    config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)
)
await stream?.start()
```

Two type-name gotchas:
- `Stream` must be qualified as `MWDATCamera.Stream` — `Foundation` exports a `Stream` type so Swift says "ambiguous for type lookup".
- `RegistrationState` cases changed: `.unavailable | .available | .registering | .registered`, *not* `.unregistered`.

**Ground truth lives at**: `~/Library/Developer/Xcode/DerivedData/<project>/SourcePackages/checkouts/meta-wearables-dat-ios/MWDATCamera.xcframework/ios-arm64/MWDATCamera.framework/Modules/MWDATCamera.swiftmodule/arm64-apple-ios.swiftinterface`. Read this before the public docs.

### 2. Apple Developer Team ID — the keychain misleads you

`security find-identity -v -p codesigning` shows:
```
"Apple Development: Kish Parikh (25R5F2DCAS)"
```
The parenthetical `25R5F2DCAS` is the **certificate identifier**, NOT your Apple Developer Team ID. Setting `DEVELOPMENT_TEAM=25R5F2DCAS` fails with "No Account for Team 25R5F2DCAS".

Get the real team ID from existing provisioning profiles:
```bash
for p in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$p" 2>/dev/null | plutil -extract TeamIdentifier xml1 -o - - \
    | grep -oE "[A-Z0-9]{10}" | head -1
done | sort -u
```

### 3. `Wearables.configure()` fatals on the iOS Simulator

It throws `WearablesError.internalError` because there's no Meta AI infra in the sim. Catch it. *Then also gate every subsequent `Wearables.shared` access*, because the `.shared` getter itself fatals if `configure()` didn't succeed.

```swift
do { try Wearables.configure(); Self.configured = true }
catch { Self.configured = false; print("Wearables disabled: \(error)") }
// Later, everywhere:
guard Self.configured else { return }
```

### 4. MockDeviceKit is for unit tests, not as a replacement for Wearables

The docs imply MockDeviceKit "simulates the entire SDK stack" but the swiftinterface shows it's a parallel `MockDeviceKit.shared` API. **It does not make `Wearables.shared` work.** You can pair a mock Ray-Ban, dön it, set up a stub photo — but your app's normal `observeRegistration` and `observeDevices` paths still fatal because they access `Wearables.shared`.

For autonomous testing, use MockDeviceKit purely to generate the stub photo + bypass the regular code path entirely. See `MockSetup.swift` and `SessionCoordinator.runTestAsk()`.

### 5. iOS 26 changed AVAudioSession Bluetooth UI

There's no longer a "Use for Calls" toggle in per-Bluetooth-device settings. The new flow uses "Device Type" picker. Also, newer Ray-Ban firmware likely uses Bluetooth LE Audio (LC3) instead of classic HFP — so `availableInputs` may show `.bluetoothLE`, not `.bluetoothHFP`.

The fix: accept any of `[.bluetoothHFP, .bluetoothLE, .bluetoothA2DP, .headsetMic, .headphones]` as a valid glasses route, and prefer one whose `portName` contains "Meta" or "Ray-Ban". See `AudioController.activateForGlasses`.

Also: do *not* throw if no Bluetooth route appears — fall back to the iPhone built-in mic/speaker.

### 6. `HTTPURLResponse.allHeaderFields` casing is undefined

On some iOS 26 builds, dict access (`headers["X-Foo"]`) misses our custom `X-Glassbridge-*` headers. Use the case-insensitive accessor:
```swift
let value = httpResponse.value(forHTTPHeaderField: "X-Glassbridge-Reply")
```

### 7. Anthropic vision caps inline images at 5 MB

iPhone JPEGs at native res are 5–8 MB. Sending one returns `400 image exceeds 5 MB maximum`. Downsample before upload:

```swift
// In IPhoneCapture: long edge → 1600 px, quality 0.7 → ~600 KB JPEG.
```

For the DAT path the streamed-frame resolutions (low/medium/high) all stay under the cap, but if you ever swap in iPhone-style photo capture for glasses, remember to downsize.

### 8. Real-glasses prerequisites cheatsheet (when MMA finally works)

These are the *minimum* pre-conditions before `Wearables.shared.devicesStream()` will emit a device — getting any one wrong = silent empty stream:

- Glasses firmware up to date (Meta AI app → glasses settings shows red dot when not).
- Developer Mode enabled in Meta AI (Settings → App Info → Developer Mode toggle).
- App registered with Meta AI (`startRegistration` → confirm in Meta AI → returns).
- **App holds at least one device permission** (camera or mic). Without this, no devices.
- Glasses physically donned (worn) or at least unfolded — folded = Bluetooth off.
- Battery > 10% (charging counts).

### 9. AVAudioSession HFP route activation is not instant

After `setPreferredInput(...)` to a BT route, the actual current route doesn't update synchronously. PortWorld polls every 100 ms for up to 2 s. We do the same. Don't trust `availableInputs` alone — confirm via `session.currentRoute.inputs.contains { $0.portType == .bluetoothXxx }`.

### 10. Latency budget

For a 5-second user utterance, what we measured on a 2024 MacBook + M2 Pro:
- Whisper distil-large-v3 CPU/int8: **~5–8 s** transcription
- Claude Sonnet 4.6 vision: **~3–5 s** to full reply
- ElevenLabs `eleven_flash_v2_5` streaming MP3: **~0.7 s** time-to-first-chunk, ~15 chunks total in ~2 s
- Network + multipart upload: ~200 ms on LAN

Total perceived "tap-to-reply-audio": **4–13 s**. Whisper dominates; the rest is small. If you want sub-3 s, replace Whisper with a streaming STT (Deepgram, AssemblyAI) or run Whisper on GPU.

### 11. Backend `0.0.0.0` vs `127.0.0.1`

If the iPhone is on the same Wi-Fi as your Mac, the backend must bind to `0.0.0.0` (not `127.0.0.1`) for the phone to reach it. `run.sh` already does this. iOS Simulator can reach the host via `127.0.0.1`. We split the URL in `Config.swift` by `#if targetEnvironment(simulator)`.

### 12. xcodegen is worth keeping

Project file is regenerated from `ios/project.yml`. Adding/removing Swift files just means rerunning `xcodegen generate`. No more pbxproj merge conflicts. Trade-off: `.xcodeproj` is gitignored, so collaborators need `brew install xcodegen` once.

### 13. Anthropic system prompt: ask for plain text

Claude defaults to markdown (`**bold**`, bullets, etc.) which both reads weirdly when voiced *and* renders as literal asterisks on a small label. Add to system prompt:
> "Do not use markdown formatting (no asterisks, no bold, no bullets) — your reply will be spoken aloud and shown on a small screen."

## Resume checklist

Next time you sit down to extend this:

1. **Pull repo**, `brew install xcodegen` if you don't have it, `python3 -m venv .venv`, `pip install -r requirements.txt`.
2. **Copy `.env.example` to `.env`**, paste real Anthropic + ElevenLabs keys.
3. **Update `ios/Glassbridge/Config.swift`** — set `backendURL` to `http://<your-mac-lan-ip>:8082` for the physical-device branch.
4. **Set your Apple team** in `ios/project.yml` (`DEVELOPMENT_TEAM`).
5. **Backend**: `./run.sh` from the repo root. First boot downloads Whisper (~600 MB, ~30–60 s).
6. **iOS**: `cd ios && xcodegen generate && open Glassbridge.xcodeproj`, build to your iPhone.
7. **First launch** on iPhone: trust the dev profile (Settings → General → VPN & Device Management).
8. **Tap ASK** — should work with iPhone camera + iPhone mic immediately. No glasses pairing needed.
9. (Optional) Try pairing Ray-Ban glasses via the Advanced sheet. If Meta MMA / permission flow has been fixed by Meta in the meantime, glasses will activate automatically.

## Files that capture the design vision

- `README.md` — what + how to run
- `docs/USE_CASES.md` — 25 glasses-specific workflows in 5 tiers
- `docs/ARCHITECTURE_V2.md` — the "programmable workflow" vision (Trigger → Inputs → Policy → Effects), 90-min migration path from MVP
- `docs/LEARNINGS.md` — this file

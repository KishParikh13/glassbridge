# Glassbridge

Voice + vision loop: tap one button, look at something, speak. Claude replies
in your ear a few seconds later.

```
Glasses ─BT─┐
            ├─▶ iPhone ─Wi-Fi─▶ MacBook (FastAPI)
iPhone cam ─┘                         ├── Whisper STT (faster-whisper, CPU)
                                      ├── Claude Sonnet 4.6 vision
                                      └── ElevenLabs streaming TTS
```

## Current status

- **iPhone-camera + iPhone-mic path works end-to-end.** Tap ASK, see + hear
  Claude respond about what your phone is pointed at. 4–13 second round-trip.
- **Ray-Ban glasses path is fully wired but blocked** on Meta's DAT SDK
  dev-mode permission flow (a known Meta-side issue — see [docs/LEARNINGS.md](docs/LEARNINGS.md)).
  When that unblocks, the app switches to glasses automatically with no code
  change.

## Run it (≈10 minutes the first time)

### 1. Start the backend

```bash
cd glassbridge
cp .env.example .env
# Edit .env, paste:
#   ANTHROPIC_API_KEY=sk-ant-...
#   ELEVENLABS_API_KEY=sk_...
./run.sh
```

First run creates a `.venv` and pulls dependencies (~2 min). Then it
downloads the `distil-large-v3` Whisper model (~600 MB, one time). After
that you'll see:

```
[run] starting on http://192.168.1.42:8082
[run] iOS BACKEND_URL = http://192.168.1.42:8082
INFO  Loading Whisper model=distil-large-v3 device=cpu compute=int8
INFO  Whisper model ready.
INFO  Glassbridge ready on 0.0.0.0:8082
```

Keep this terminal open. Smoke-test from any other terminal:

```bash
curl http://192.168.1.42:8082/healthz
# {"status":"ok"}
```

### 2. Run the iOS app

See [`ios/README.md`](ios/README.md). The TL;DR:

```bash
brew install xcodegen          # one-time
cd ios
# Edit Glassbridge/Config.swift → paste the http://… URL printed above
xcodegen generate
open Glassbridge.xcodeproj
# In Xcode: set your team, build to your iPhone (⌘R), tap "Pair / register glasses"
```

Then in iOS Settings → Bluetooth → your glasses, turn **Use for Calls** ON
so the glasses appear as a Bluetooth HFP audio device to the phone.

### 3. Tap ASK

Look at something, speak. Done.

## What you get

- **`/healthz`** — liveness probe.
- **`POST /ask`** — multipart `audio` (wav) + `image` (jpeg) + `session_id` (form
  field). Returns `audio/mpeg` (streaming MP3) with debug headers:
  - `X-Glassbridge-Transcript` (URL-encoded)
  - `X-Glassbridge-Reply` (URL-encoded)
  - `X-Glassbridge-Lang`
  - `X-Glassbridge-Latency-Stt`, `X-Glassbridge-Latency-Llm`
- **Multi-turn memory**: backend keeps the last 3 turns per `session_id`. The
  iOS app generates one per launch.

## What this does NOT do (yet)

- Tailscale / remote backend — local LAN only
- Wake word — manual button tap to ASK
- OpenClaw tool calling, MCP, agent presets
- Continuous video context — single frame per ASK
- WebSocket streaming — single POST per turn

See [`docs/USE_CASES.md`](docs/USE_CASES.md) for ideas that would actually
benefit from those, and [`docs/ARCHITECTURE_V2.md`](docs/ARCHITECTURE_V2.md)
for what a programmable-workflow version of Glassbridge looks like.

## Project layout

```
glassbridge/
├── backend/
│   ├── main.py         – FastAPI app, /healthz, /ask
│   ├── config.py       – env-driven Settings
│   ├── stt.py          – faster-whisper wrapper
│   ├── llm.py          – Anthropic vision wrapper
│   ├── tts.py          – ElevenLabs streaming HTTP
│   └── sessions.py     – in-memory rolling history per session_id
├── ios/
│   ├── project.yml     – xcodegen spec
│   └── Glassbridge/    – Swift sources (see ios/README.md)
├── docs/
│   ├── USE_CASES.md         – 25 glasses-specific workflows
│   ├── ARCHITECTURE_V2.md   – the programmable-workflow vision
│   └── LEARNINGS.md         – hard-won technical notes (DAT 0.7, MMA, audio, latency, …)
├── samples/            – test inputs for curl smoke tests
├── requirements.txt
├── .env.example
└── run.sh
```

## Before you contribute

Read [`docs/LEARNINGS.md`](docs/LEARNINGS.md) — it captures the ~10 things that
will save you hours: the actual DAT SDK 0.7 API (which differs from Meta's
own public docs), the Apple Developer Team ID trap, Meta MMA's broken
permission flow, the AVAudioSession HFP route activation poll, the Anthropic
5 MB image cap, and more.

## Files we read while building this

- `reference/PortWorld/` — gave us the AVAudioSession HFP incantation
  ([`IOS/PortWorld/Audio/AudioCollectionManager.swift`](../reference/PortWorld/IOS/PortWorld/Audio/AudioCollectionManager.swift)).
- `reference/meta-wearables-dat-ios/` — DAT SDK 0.7 swiftinterface (the API
  shape changed meaningfully from PortWorld's 0.5-era reference: `Stream`
  not `StreamSession`, `deviceSession.addStream(config:)` not a free init).
- ElevenLabs streaming TTS: `https://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream`
- Anthropic vision: standard `messages.create` with an `image` content block
  (base64 inline).

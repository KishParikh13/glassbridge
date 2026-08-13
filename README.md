# Glassbridge

Talk to an AI through Ray-Ban Meta glasses, hands-free, with no screen.

Say **"hey glass"** and ask a question. It answers in your ear in about five seconds. Say
**"look"** and it takes a photo first. Talk over the reply and it stops and listens. Say
**"go to sleep"** and it stays asleep, even after a restart.

The interesting part is not the model call. It is that the whole interface is sound and
timing: there is nothing to look at, so every state has to be audible, and every mistake
has to be cheap to take back.

```
                      "hey glass"            "hey claude"
                           │                      │
  Ray-Ban Meta ──BT/HFP──▶ iPhone ──Tailscale──▶ Mac mini
   mic + speaker           on-device              ├── MLX Whisper       1.6s
                           wake word              ├── agent registry    ├─ Claude + web search
                           + earcons              └── ElevenLabs TTS    └─ or your own agent
```

## What works

Verified on real hardware. See [`docs/HARDWARE_VALIDATION.md`](docs/HARDWARE_VALIDATION.md)
for the test script and results.

- **Hands-free voice loop** over the glasses' mic and speaker. ~5.2s round trip.
- **A spoken vocabulary**, not just a wake word: `look` attaches a photo mid-sentence,
  `never mind` drops the turn, `stop` cuts a reply short, `go to sleep` switches it off.
- **Barge-in.** Talk over an answer and it stops. Echo cancellation measured at essentially
  zero leakage, which is what makes this safe to be sensitive.
- **An open conversation.** For 15 seconds after a reply you can just talk, no wake phrase,
  same thread.
- **Pluggable agents.** Each gets its own wake phrase. Adding one is a config file and a
  restart, no app rebuild. See [`docs/AGENTS.md`](docs/AGENTS.md).

## What does not work

- **The glasses camera is unreliable.** Meta's DAT permission flow is broken on their side
  and closed with no fix (`facebook/meta-wearables-dat-ios` Discussion #101). Captures
  currently take ~6s and sometimes never arrive. The **audio** path is unaffected, which is
  why the product is viable at all. Details in [`docs/LEARNINGS.md`](docs/LEARNINGS.md) §2.
- **You cannot install this the normal way.** Meta's Wearables Device Access Toolkit is in
  Developer Preview, so App Store and TestFlight distribution are not available to anyone.
  Building from source with your own Apple developer account is the only path.
- Effects are hardcoded to "speak". No triggers other than the wake word (no cron,
  geofence, calendar). See [`docs/ARCHITECTURE_V2.md`](docs/ARCHITECTURE_V2.md) for the
  model the rest of this is heading toward.

## Run it

Roughly 15 minutes the first time. You need an iPhone, an Apple developer account, and
your own API keys. Ray-Ban Meta glasses are optional: without them it uses the phone's mic
and camera and everything else behaves the same.

### 1. Backend

```bash
cp .env.example .env
# ANTHROPIC_API_KEY=sk-ant-...
# ELEVENLABS_API_KEY=sk_...
./run.sh
```

First run creates a `.venv` and installs dependencies. Speech-to-text defaults to whatever
is available:

| | |
|---|---|
| Apple Silicon with `mlx-whisper` installed | GPU, ~1.6s. `pip install mlx-whisper` |
| `GROQ_API_KEY` set | hosted, under a second |
| neither | local CPU Whisper, ~12s, and a ~1.5 GB model download |

The last one works but is slow enough to change how the product feels. On a Mac, install
`mlx-whisper`.

`run.sh` prints the URL to use. Smoke-test it:

```bash
curl http://<that-host>:8082/healthz     # {"status":"ok"}
curl http://<that-host>:8082/agents      # who you can talk to
```

### 2. iOS app

```bash
brew install xcodegen        # one time
cd ios
# Edit Glassbridge/Config.swift → the URL run.sh printed
xcodegen generate
open Glassbridge.xcodeproj   # set your team, ⌘R to your iPhone
```

Grant microphone, camera, and speech recognition. Then Settings → Hands-free → wake word
on.

**If the backend is not on the same Wi-Fi**, put both devices on a Tailscale tailnet and
use the Tailscale address. That is what this repo does, and it is more reliable than a LAN
address: it survives changing networks, and many public networks isolate clients from each
other so a LAN address simply cannot work. Note that Tailscale addresses are CGNAT, which
iOS does **not** treat as local networking, so cleartext HTTP needs an ATS exception. This
project sets one.

### 3. Glasses (optional)

Pair them in the Meta AI app, then check iOS Settings → Bluetooth. They need to be an audio
route, not just paired to Meta AI. On iOS 26 the old "Use for Calls" toggle is gone; look
for the Device Type picker.

When it is working, Settings → Status → Ray-Ban glasses shows *Connected*, and the audio
route reads `BluetoothHFP` for both input and output.

## Agents

Two ship by default:

```
"hey glass"   → Claude with eyes and web search. Knows what you are looking at.
"hey claude"  → whatever you point it at. Here, a personal assistant with its own
                corpus, tools, and memory.
```

Adding a third is an entry in `agents.json` and a backend restart. The app asks
`GET /agents` at launch and arms a trigger phrase for each, so there is no app change.
Anything that accepts a JSON POST and answers with newline-delimited JSON works. Full
contract in [`docs/AGENTS.md`](docs/AGENTS.md).

## API

- `GET /healthz` — liveness.
- `GET /agents` — the agents and their wake phrases.
- `POST /ask` — multipart: `audio` (wav, required), `image` (jpeg, optional),
  `session_id`, `agent`, `model`, `text_override`. Streams back `audio/mpeg` with
  `X-Glassbridge-Transcript`, `-Reply`, `-Agent`, `-Latency-Stt`, `-Latency-Llm` (all
  URL-encoded).

The image is optional on purpose. Most questions are language, not vision, and a photo
nobody asked for costs latency and tokens.

## Docs

| | |
|---|---|
| [`AGENTS.md`](docs/AGENTS.md) | How to plug in a different assistant |
| [`HARDWARE_VALIDATION.md`](docs/HARDWARE_VALIDATION.md) | The test script for real glasses, plus results |
| [`RESEARCH.md`](docs/RESEARCH.md) | Prior art, what Meta's own always-on mode does, industry numbers vs ours |
| [`LEARNINGS.md`](docs/LEARNINGS.md) | The things that cost hours. Read before contributing |
| [`ARCHITECTURE_V2.md`](docs/ARCHITECTURE_V2.md) | Trigger → Inputs → Policy → Effects, where this is going |
| [`USE_CASES.md`](docs/USE_CASES.md) | 25 workflows that need glasses rather than a phone |
| [`DEMO.md`](docs/DEMO.md) | What to record, and what each shot proves |
| [`earcons/index.html`](docs/earcons) | Audition the sound sets. `python3 docs/earcons/generate.py` regenerates them |

## Layout

```
backend/
  main.py          FastAPI: /healthz, /agents, /ask
  agents/          the pluggable agent layer (base, claude, gateway, registry)
  stt.py           MLX / Groq / faster-whisper, chosen at startup
  llm.py           Anthropic vision + tools
  tts.py           ElevenLabs streaming
  tests/           agent-layer tests, no network or keys needed
ios/Glassbridge/
  WakeWordListener  continuous recognition, phase-scoped command grammar
  MicrophoneHub     one mic tap, many subscribers
  AudioSessionController  the single owner of AVAudioSession
  VoiceActivity     adaptive-threshold barge-in detection
  Earcons           generated tones; the whole audible vocabulary
  SessionRecorder   per-turn JSON event log
agents.example.json  copy to agents.json to add assistants
```

## Notes

Run the backend tests with `python -m unittest discover -s backend/tests -t .`

Before changing anything audio-related, read [`docs/LEARNINGS.md`](docs/LEARNINGS.md). The
short version: one object owns the audio session, one object owns the microphone, and
everything else subscribes. Every version of this that ignored that rule broke in a way
that took hours to find.

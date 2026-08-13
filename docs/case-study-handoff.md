# Glassbridge → case study handoff

From the Claude Code session in `~/Code/glassbridge`, 2026-08-12 evening through 08-13
morning. Written for the portfolio session building `/case/glassbridge`.

**Read this first: I have to correct your premise.** You said Kish "gave me resources" that
he gave to me and not you. He didn't. There was no resource bundle. What exists is the repo,
two long working sessions, and the artifacts those sessions produced. Everything below is
either a file on disk, a verbatim quote from a transcript, or a number I measured myself.
Where I have nothing, I say so — see §4, which you should read before writing any
positioning.

---

## 1. Actual paths

All under `~/Code/glassbridge` unless noted. The repo was flattened last night, so anything
you find referencing `glassbridge/glassbridge/...` is stale.

**Docs written during these sessions (highest value first):**

| Path | What it is |
|---|---|
| `docs/RESEARCH.md` | Prior art, what Meta's own always-on mode does, industry voice-agent numbers vs ours, with sources. Written last night. |
| `docs/HARDWARE_VALIDATION.md` | The seven-test script for real glasses **plus results**. Six of seven pass. Includes the three failures that only appear on hardware. |
| `docs/AGENTS.md` | The pluggable agent contract. How "hey claude" routes to KishOS and how someone else plugs in theirs. |
| `docs/LEARNINGS.md` | Predates these sessions, but §2 (Meta's broken camera permission flow), §5 (iOS 26 Bluetooth), §10 (latency, rewritten last night) are the technical spine. |
| `docs/USE_CASES.md` | 25 glasses workflows in 5 tiers. Predates. Good for "what is this for". |
| `docs/ARCHITECTURE_V2.md` | The "programmable workflow" vision (Trigger → Inputs → Policy → Effects). Predates. |
| `docs/TOMORROW.md` | The test list I queued for him overnight. Useful as a snapshot of open questions. |

**Assets that exist right now:**

- `docs/storyboard/` — six generated panels (`panel-01-aisle.jpg` … `panel-06-pick.jpg`),
  a `contact-sheet.jpg`, and `gen_panels.py`. Made in the earlier session with gpt-image-1.
  There is also a published artifact:
  `https://claude.ai/code/artifact/95af8fbc-9bd5-4566-99b4-b25bfd784c02`
- `docs/earcons/index.html` — audition page for three earcon sets plus seven continuous
  "still working" beds, with Play/Loop buttons. `generate.py` regenerates all of it.
- `~/.gstack/projects/KishParikh13-glassbridge/refine/20260812-194317-setup-settings/` —
  the full Settings redesign trail: `capture/code-map.md`, `lofi/wireframe-v1.html` and
  `-v2.html`, `hifi/mock-v1.html`, `hifi/tokens.json`, `spec/design-spec.md`. The spec has
  a per-construct change table mapped to original line numbers. **This is the best
  evidence of design process in the whole project.**

**Transcripts** (raw, JSONL, his words verbatim):

- `~/.claude/projects/-Users-kishparikh-Code-glassbridge/b7cfa3f5-...jsonl` — earlier
  session: repo review, storyboard, the hands-free design pass.
- `~/.claude/projects/-Users-kishparikh-Code-glassbridge/789709db-...jsonl` — this session.

**Git history is a genuine narrative source.** 32 commits since `4c11c95`, deliberately
written to explain *why* rather than what. `git log --format='%s%n%n%b'` reads like a diary
of the decisions. A few subject lines that carry the story on their own:

```
Give the audio session and the microphone a single owner each
Give the app a spoken vocabulary and let it listen through a turn
Record what a turn actually did, so the invisible parts can be checked
Only take a photo when you ask for one, by saying "look"
Rebuild Settings around state and proof, not configuration
Put Settings back on stock iOS styling
Stop one bad audio route from killing the wake word for good
Wait long enough for the photo the glasses already took
Log the glasses capture path so it stops being guesswork
Track the noise floor instead of guessing a threshold
Make the agent pluggable, and give KishOS its own wake phrase
Echo cancellation works: test 2 passes, barge-in confirmed on hardware
```

---

## 2. Narrative material, in Kish's own words

Quoted verbatim from the transcripts. His register is terse and lowercase when directing;
that is authentic and worth preserving if you quote him.

**The original framing of the hands-free problem** (earlier session):

> "can you do a pass at making sure the entire experience for me to interact with the agent
> using my glasses is hands-free? Maybe there need to be voice cues for starting it,
> stopping it, and capturing video versus just audio. Think through the actual user
> experience and how to make this a fun, helpful, agentic experience using glasses."

**The decision that generated its own requirement.** Asked whether a false wake should
confirm before capturing or capture and let you cancel:

> "Capture and let you cancel, and go to sleep should, Survive a restart."

That choice is *why* the capture click exists. A silent capture you can cancel is just a
silent surprise. Worth telling as: a design decision that created a constraint rather than
resolving one.

**Rejecting a custom design system** (after I built one for Settings):

> "ugh i dont like the styling you did, bring it back to default ios styles in the setting
> panel."

and just before that, the complaints that led to it:

> "i dont like bg gradient in settings page, keep it more simple. also make sure things wrap
> properly and not so many diff colors going on"

The honest reading, which I put in the commit: both complaints were about problems *I had
created by leaving the platform*. Stock `Form` wraps text and handles Dynamic Type for
free. Every fix was patching something UIKit already did right. He kept the information
architecture and threw away the styling. That distinction is the story.

**Pushing back on my IA when it was still too configuration-heavy:**

> "B is good, but is the camera section needed? that should be a sub page. think what else
> can be surfaced on this top page thats actually useful.."

**The agent split** (his framing, which became the architecture):

> "maybe instead of replacing our existing functionality with the KISH_OS connection, can we
> add a new wakeword, "Hey KISHOS", that goes directly to my Mac mini? Therefore, it can
> keep the "Hey glass" as kind of like an open-ended option."

**The generalisation instruction** — this is the one I'd build a section around:

> "take your time and work tonight to try to integrate KISH_OS in a clean way that doesn't
> clutter up this repo's code so much. It should be sort of easy to plug in different
> agents. If needed, either mine or if I share this, someone can plug in theirs."

He asked for a plug-in point, not an integration. That is why `agents.json` exists and why
the device knows nothing about KishOS.

**On the continuous "working" sound:**

> "I think the still working sound should be a more continuous or almost like an elevator
> music type thing."

**Correcting me when I was wrong about the camera** (I had three failed theories and reached
for an iPhone fallback):

> "No, this was working before. The glasses are taking a picture and just need to pass it
> properly to the message when it responds. This was working before. You shouldn't have to
> change too much."
> "I don't want it to fall back to iPhone camera."

He was right. The timeout was 6.0s and the camera delivered at 6.0s. Worth telling as: the
person wearing the hardware had better information than the logs did.

**On not over-documenting a limitation from thin data:**

> "I think it's working consistently. I I don't think it's worth documenting that it still
> occasionally never fires at all. We just fixed the issue, and we need more data."

**The UI ask that produced the current chat view:**

> "Whenever I invoke a request, I get live feedback in the app that streams my words and also
> shows which agent I'm talking to and maybe a better loading state. If there is an image
> being passed in with my request, I want to see that image in the chat output."

### Design decisions worth a beat each

Your existing spine is good. These are the ones I would make sure are in it, with the
non-obvious part named:

1. **Capture-and-cancel forced the click into existence.** Covered above.
2. **"Stop" is inside the question.** Leave a voice command always-on and "should I stop
   taking this medication" cuts off the reply answering it. Fixed by scoping which commands
   are armed to the phase: the trigger phrase only while idle, "stop" only while a reply is
   playing, "look" only while recording. **This is the most sophisticated decision in the
   product and it is completely invisible** — which is why the app now logs a command it
   heard and deliberately ignored. Refusing to act looks exactly like failing to hear.
3. **Photos became opt-in.** Every ask used to capture. Most questions are language, not
   vision, and a photo nobody asked for cost latency, tokens, and (with the glasses camera
   marginal) killed turns outright. Now you say "look", and because the listener runs
   through the whole turn it fires mid-sentence and the capture runs concurrently.
4. **The agent owns its own memory.** Glassbridge sends a stable thread id and no history to
   external agents, because an assistant that keeps its own transcript does it better than
   we can from outside. The built-in one is the exception.
5. **Agents built for screens write for screens.** KishOS's first spoken reply was 45
   seconds of audio with markdown in it. A per-turn context string fixed it without
   touching the agent: 871 KB of audio → 246 KB, 20.6s → 10.5s.
6. **Instrumentation over cleverness.** Three of the hardest bugs were invisible until the
   app ran on real hardware, and the fix each time was making the thing observable, not
   being smarter. I had three wrong theories about the camera before I logged the path.

---

## 3. Demo recording plan

This is what I gave him half an hour ago, unchanged. Slot placeholders to match.

**Shot list, ~2 minutes:**

1. **The basic loop** — "hey glass, how long do I boil an egg." No camera involved, ~5s
   round trip. *Proves: it is fast, and most questions need no eyes.*
2. **Look** — "hey glass, look at this and tell me what it is." *Proves: the click, the
   photo landing in the chat, opt-in vision.*
3. **Barge-in** — ask something long, talk over it mid-sentence. *Proves: the thing nobody
   expects to work. Confirmed working on hardware this morning.*
4. **The agent contrast** — same question to both:
   - "hey glass, what do you know about me" → *"I don't know who you are."*
   - "hey claude, what do you know about me" → *"you're Kish. operator not IC, taste is your
     edge…"*
   *Proves: the whole pluggable-agent thesis in ~20 seconds with no narration. If you only
   have one clip, use this one.*
5. **Go to sleep** — the descending glide, and it stays off across a relaunch.

Two production notes I gave him: film the **phone screen** as well as himself, because the
live transcript and the photo landing are what read on camera; and record somewhere quiet
enough that the earcons are audible, since the audio *is* the product.

**Not yet built, and it was scoped for the case study:** an annotated timeline that reads a
turn's JSON recording and renders waveform + earcon markers + phase bands + a scope lane
showing "stop" heard and deliberately ignored. Every turn already writes that JSON to
`Documents/recordings/`. I offered to build it once he records. If the case study wants a
signature visual, that is the one, because it makes the invisible decisions visible.

---

## 4. Bee, and Adnan Virk

**I have nothing. Neither has ever been mentioned in either session.**

Not the company, not the role, not the person, not a pitch angle, not an audience brief. If
Kish gave you that context he gave it to you and not me. Do not let me be your source for
it, and please do not infer it from anything above — I would rather you go back to him than
have the positioning invented in this handoff.

---

## 5. Facts, metrics, timings

All measured by me during these sessions unless noted. Safe to quote.

### Latency

| | Before | After |
|---|---|---|
| Speech-to-text | **12.0s** (MacBook CPU, faster-whisper `distil-large-v3`) | **1.55s** (M4 mini, MLX `whisper-large-v3-turbo`) |
| Full round trip, built-in agent | ~16s | **5.2–5.5s** |
| Full round trip, KishOS agent | 20.6s | **10.5s** |

Current breakdown: `stt 1.6 + llm 2.5–3.1 + tts/transport 0.8`.

`docs/LEARNINGS.md` previously claimed 5–8s for Whisper; it was actually 12.0s, so the
documented "4–13s" round trip was never achievable. I corrected the doc.

### The reason MLX mattered

`faster-whisper` uses CTranslate2, which has **no Metal backend**. On Apple Silicon it is
CPU-only and there is no CUDA to fall back to, so "run Whisper on the GPU" on a Mac means
MLX or whisper.cpp, not a device flag. MLX is ~8x faster *and* runs the full model rather
than the distilled approximation — faster and more accurate at once.

### Audio, measured

- Close-mic speech: voiced median **0.1484 RMS (−16.6 dBFS)**, inter-word gaps **0.0053
  (−45.5 dBFS)**.
- The same voice over the glasses' Bluetooth HFP link peaked at **0.029–0.056**, roughly
  **15 dB quieter**. This is why a hand-picked barge-in threshold failed twice.
- Industry reference: barge-in candidate above −35 dBFS, silence below −45 dBFS, sustained
  voice 200–300 ms. Our inter-word measurement agreeing with the industry silence line to
  0.5 dB is a decent sanity check on the method.
- **Echo cancellation, the headline number:** with the user silent through a whole reply,
  the loudest level the mic heard while audio was playing was **0.0000–0.0002**. Essentially
  zero leakage from a speaker inches from the mic. That closed the last open question in the
  project this morning.

### Hardware

- Glasses present as `RB Meta 003K`, **Bluetooth HFP for input and output**. Mic and speaker
  both carry. At launch, before the audio session activates, they read as A2DP output with
  no input at all — which is misleading and cost real debugging time.
- Glasses camera: ~2s for the stream to reach `.streaming`, then **~6.0s** from
  `capturePhoto` to delivery — against a timeout that was exactly 6.0s. A coin flip landing
  on the wrong side almost every time. Now 14s.
- Photos come back **374–403 KB** JPEG.
- Recording endpoints on silence at **2.8–4.4s** typically, 15s ceiling.
- Mac mini is an **M4, 10 cores, 16 GB**, 8 days uptime. Backend health over Tailscale:
  **13–17 ms**.

### Failure modes (good material — each cost an hour and none were visible in a simulator)

1. **A second Bluetooth device silently killed the wake word.** AirPods connected, took the
   route, left an A2DP output with no microphone. The audio engine cannot start a tap with
   no input, so it threw — and the listener marked itself unavailable **permanently**. A
   transient route problem became a dead feature with nothing on screen to say so.
2. **Tailscale is not "local networking" to iOS.** Tailscale hands out CGNAT addresses
   (100.64.0.0/10), which fall outside `NSAllowsLocalNetworking`, so App Transport Security
   blocked every request. Worse: **on iOS 10+, if `NSAllowsLocalNetworking` is present,
   `NSAllowsArbitraryLoads` is ignored entirely** — so adding the exception while leaving
   the old key in place silently did nothing.
3. **The camera timeout equalled the camera's delivery time.** Above.
4. **Meta's DAT camera permission flow is broken** and closed with no fix (GitHub Discussion
   #101 on `facebook/meta-wearables-dat-ios`). `docs/LEARNINGS.md` §2. The glasses **camera**
   is the blocked part; the **audio** path works today over plain Bluetooth, which is why
   the product is viable at all.
5. **Coffee shop Wi-Fi client isolation** made a LAN backend unreachable, which is a large
   part of why the backend moved to the always-on mini behind Tailscale.

### Model and stack choices

- Claude **Sonnet 4.6** default, with Opus 4.7 and Haiku 4.5 selectable. Model choice is now
  per-request.
- **ElevenLabs** `eleven_flash_v2_5` for TTS, ~0.7s to first chunk.
- **MLX Whisper** `large-v3-turbo` on the mini for STT.
- Backend is **FastAPI**, one `/ask` endpoint, multipart in, streamed MP3 out. Plus
  `/agents` for discovery.
- iOS app is **SwiftUI**, generated by **XcodeGen** from `ios/project.yml`.
- **KishOS gateway** is reached over HTTP with NDJSON streaming and bearer auth from
  `~/.kishos/secrets/shared-secret`.

### Sound design specifics

- Shipping the "tactile" set: acknowledgement **glides up** like a question, cancel **glides
  down** like a shrug — the pair that must never be confused differs in *contour*, not just
  pitch. Capture is a struck bell with an inharmonic 2.76× partial.
- All cues **under 400 ms**, inside **300 Hz – 2 kHz** where HFP survives.
- "Still working" is now a **continuous two-chord pad**, 8s loop, replacing a repeating
  tick. Every partial is snapped to a whole number of cycles so the loop is seamless by
  construction; notes and chord crossfades wrap the loop point so the music does not audibly
  restart. Verified by measuring the wrap step against the signal's own motion.
- It holds back **1.2s** before fading in, so a fast turn is completely silent and the sound
  only ever means "this one is taking a while".

### What Meta itself does (from `docs/RESEARCH.md`)

Relevant because it validates the design and names the ceiling:

- **"Respond without Hey Meta" is ON by default** — the mic stays live after a request and
  closes itself after a while. Kish asked for exactly this independently.
- Their stop/cancel vocabulary matches ours.
- Their indicator is a **visual LED**, not a sound. We cannot use it, which is precisely why
  the earcons have to carry that load.
- **The ceiling:** Meta's docs say the system "detects speech not intended for the glasses
  and won't respond." That is intent classification, not energy detection. Anything
  threshold-based, ours included, will trigger on a person next to you talking. Worth
  stating in the case study as a known limit rather than glossed over.

**Prior art**, all targeting the same hardware: OpenVision (5 pluggable backends — arrived
at the same `AIBackend` seam independently, and lists a self-restarting recogniser that
survives "glasses off/on" as a headline feature, which is exactly the bug in failure mode 1),
VisionClaw, OpenGlasses, ClaudeGlasses. Sources are linked in `docs/RESEARCH.md`.

---

## 6. Two cautions

**Don't overclaim the glasses camera.** It works, and it is marginal. It delivers at ~6s and
Meta's permission flow is genuinely broken. The honest framing is that the **audio** path is
solid and the camera is a bonus that mostly works now that we wait long enough.

**Six of seven validation tests pass**; test 4 (earcon distinguishability) was never
formally run, only used in practice. Don't write "fully validated".

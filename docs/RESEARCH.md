# What others built, and what Meta does

Research pass, 2026-08-13. Prior art, Meta's own always-on behaviour, industry voice-agent
numbers, and measurements of our own audio. Written to be acted on: everything here either
changed a constant, confirmed a decision, or is listed as a known limit.

## 1. Prior art

Four public projects target the same hardware. None publish thresholds or latency, so the
value is architectural.

| Project | What it is | What it tells us |
|---|---|---|
| [OpenVision](https://github.com/rayl15/OpenVision) | iOS app, 5 backends (MLX on-device, Apple Intelligence, OpenAI, Gemini Live, OpenClaw) | Defines an `AIBackend` seam. **The same shape as our agent layer**, arrived at independently. Also: "primed recognition + self-restart so it keeps listening (survives idle, replies, and glasses off/on)" |
| [VisionClaw](https://github.com/Intent-Lab/VisionClaw) | Gemini Live + OpenClaw, agentic actions | Voice + vision + acting on your behalf; same product thesis |
| [OpenGlasses](https://github.com/straff2002/OpenGlasses) | Multi-provider, mirrors to the Display glasses HUD | Provider choice as a first-class feature |
| [ClaudeGlasses](https://github.com/Mattp1976/ClaudeGlasses) | Claude + Ray-Ban Meta | Closest to our original scope |

**Two things worth stealing.**

*OpenVision's self-restarting recogniser.* They call out surviving "idle, replies, and
glasses off/on" as a named feature. We hit exactly this last night: AirPods took the route,
the engine could not start a tap, and the listener died permanently. That it is a headline
feature for them says it is the central reliability problem of this product category, not
an edge case.

*Follow-up windows are standard, and ours is short.* OpenVision offers **15s to 2 minutes**
of conversation mode after a wake. Ours is a fixed 15s — the bottom of their range. Worth
making configurable.

A separate [custom wake word writeup](https://crookse.com/journal/2026-03-21-ray-ban-meta-development-day-03)
replaced "Hey Meta" with Porcupine on the same glasses, confirming the audio path: **48kHz
stereo Float32 from the device, converted to 16kHz mono Int16, 512-sample frames.** Ours is
the same conversion, and they hit the same class of bug (wake firing only once per session
until restarted).

## 2. What Meta actually does

Their behaviour is the best available spec, since millions of people use it daily.

- **"Respond without Hey Meta" is ON by default.** The mic stays live after a request and
  turns off by itself "after a little while". Kish asked for this independently; Meta ships
  it as the default. Our 15s open window is the same feature.
- **"Stop" or "Cancel" ends it.** Our vocabulary already matches, which is worth something:
  users arriving from Meta AI will guess right.
- **The indicator is visual, not audible** — the LED shows when audio is being processed.
  They never make a sound to say "still listening". We cannot use their LED, which is
  precisely why our earcons have to carry that load.
- **Music controls deliberately do not extend the window**, so a command that starts
  playback does not leave the mic open into the music.
- **It will not engage while the mic is already in use** (calls, recording).
- **The important one:** *"the system detects speech not intended for the glasses and won't
  respond."* That is intent classification, not energy detection.

**The lesson.** Meta's hard problem is not hearing you, it is knowing when you meant them.
Any purely energy-based detector — ours included — will trigger on someone next to you
talking. This is the known ceiling of the current design and worth naming rather than
pretending otherwise.

## 3. Industry numbers, and ours against them

From current voice-agent practice:

| | Industry | Ours before | Ours now |
|---|---|---|---|
| Silence line | < −45 dBFS | −36.5 dBFS (`silenceThreshold` 0.015) | unchanged, see below |
| Barge-in candidate | > −35 dBFS | −30.5 dBFS (`threshold` 0.030) | adaptive, floor −42 dBFS |
| Sustained voice before barge-in | 200–300 ms | 220 ms | 200 ms |
| Turn-taking gap | 200–400 ms | 900 ms (`trailingSilence`) | unchanged |
| False barge-in rate | < 2% | unmeasured | unmeasured |

### The measurement that mattered

Analysing real speech at 20ms frames:

```
close-mic speech, voiced median   0.1484   (−16.6 dBFS)
close-mic speech, inter-word gap  0.0053   (−45.5 dBFS)
our barge-in threshold was        0.0300   (−30.5 dBFS)
observed field peaks (glasses)    0.029 – 0.056
```

Close-mic speech sits at −16.6 dBFS. The **same voice through the glasses' HFP link peaked
at 0.056**, roughly 15 dB quieter. Our trigger at 0.030 was therefore near the *peak* of
glasses speech, not its body — which is exactly why barge-in never fired despite peaks
appearing to clear the threshold. A peak is not a sustain.

Note the industry silence line (−45 dBFS) and close-mic inter-word gaps (−45.5 dBFS) agree
almost exactly, which is a good sign the frame analysis is sound.

### What changed

`VoiceActivityDetector` no longer uses a fixed threshold. It tracks the noise floor —
falling fast toward quiet, rising slowly so a sentence cannot raise the bar it is measured
against — and triggers **12 dB above the floor**, clamped to −42 dBFS at the bottom and
−26 dBFS at the top. Sensitivity now follows the room instead of a number chosen by hand,
which had already been wrong twice (0.06, then 0.03).

`trailingSilence` and `silenceThreshold` are left alone: endpointing measured fine in the
field at 2.8–4.4s per question, and there is no evidence to move them.

## 4. The open question this sets up

Every window now logs **peak while a reply was playing**, separately from peak overall:

```
[OPEN] closed: window elapsed · peak 0.0412 · echo 0.0067 · floor 0.0051 · trigger 0.0203
```

`echo` is the highest level seen while audio was coming out of the speaker. If `.voiceChat`
cancellation works, it sits near the floor and aggressive barge-in is safe. If it tracks
`peak`, the reply is leaking into the mic and no energy threshold will separate the two.

**That single number settles the echo-cancellation question that has been open since the
first hardware session.** It needs one turn with a long reply, listened to in silence.

## Sources

- [OpenVision](https://github.com/rayl15/OpenVision) · [VisionClaw](https://github.com/Intent-Lab/VisionClaw) · [OpenGlasses](https://github.com/straff2002/OpenGlasses) · [ClaudeGlasses](https://github.com/Mattp1976/ClaudeGlasses)
- [Custom wake word on Ray-Ban Meta](https://crookse.com/journal/2026-03-21-ray-ban-meta-development-day-03)
- [Respond without "Hey Meta"](https://www.meta.com/help/ai-glasses/899314785056676/) · [Voice controls](https://www.meta.com/help/ai-glasses/377922810809460/)
- [Meta Wearables Device Access Toolkit](https://developers.meta.com/blog/introducing-meta-wearables-device-access-toolkit/)
- [Voice AI barge-in and turn-taking, 2026](https://futureagi.com/blog/voice-ai-barge-in-turn-taking-2026/) · [Barge-in for on-device agents](https://www.runedge.ai/blog/barge-in-interruption-handling-on-device-voice) · [Interruption handling runbook](https://hamming.ai/resources/voice-agent-interruption-handling-runbook)

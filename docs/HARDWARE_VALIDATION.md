# Hardware validation pass

The app has never run against the glasses. Every claim about the hands-free experience is
currently an inference from port types and API docs, not an observation. This is the
session that turns them into facts.

Budget about 45 minutes. Work through it in order: test 0 gates everything after it, and
test 2 is the one most likely to change the design.

Every turn writes a JSON file. Get them off the device afterward via **Files → On My
iPhone → Glassbridge → recordings**, then AirDrop the folder to the Mac.

## Setup

1. Backend up: `./run.sh` from the repo root. Wait for the Whisper load line.
2. `ios/Glassbridge/Config.swift` → `backendURL` points at your Mac's LAN IP, not
   `127.0.0.1`. The phone cannot reach localhost.
3. `cd ios && xcodegen generate`, build to the iPhone.
4. Glasses: charged above 10%, unfolded and on your face, paired in iOS Bluetooth settings.
5. In the app: Setup → Hands-free → wake word **on**. You should hear a rising three note
   cue. If you hear it out of the iPhone speaker rather than the glasses, stop and fix the
   route before going further.

Reading a recording:

```bash
jq -r '.route, (.events[] | "\(.at|tostring|.[0:5])s  \(.kind)  \(.label)  \(.detail // "")\(if .armed == false then "  [NOT ARMED, scope=\(.scope)]" else "" end)")' turn-*.json
```

---

## Test 0. Does the glasses route pin? (gate)

Everything below is measuring the iPhone unless this passes.

**Do:** relaunch the app with the glasses connected and worn. Say "hey glass", ask "what
do you see", let it finish.

**Pass:** the recording's `route` field shows an input of `BluetoothHFP` or `BluetoothLE`
with a port name containing Meta or Ray-Ban.

**Fail:** `MicrophoneBuiltIn`. Note the exact `route` string and stop here. Likely causes
are in `LEARNINGS.md` §5: iOS 26 moved the per-device audio setting to a "Device Type"
picker, and newer firmware may present as LE Audio rather than classic HFP.

**Note down:** the exact port type string. `AudioSessionController.bluetoothPorts` may
need a case added.

---

## Test 1. Does the wake word fire through the glasses mic?

**Do:** five separate wakes, spread out, normal speaking voice, phone in your pocket:
"hey glass" → wait for the rising two note cue → ask anything short.

Then three deliberate near-misses: "hey class", "hey glasses", "okay glass".

**Pass:** 5 of 5 real wakes fire. Ideally 0 of 3 near-misses fire.

**Note down:** how many fired, and for any miss, what `lastHeard` shows in the log. A
consistent mishearing is a tuning problem, not a failure. If it hears "hey glass" as
"hagglers" every time, the trigger phrase is the wrong phrase.

---

## Test 2. Does echo cancellation hold? (the risky one)

This decides whether barge-in is a feature or a story about a wall. `.voiceChat` is
supposed to keep Claude's own voice out of the recognizer. Over a small speaker sitting on
your temple, next to a mic, that is a real question.

**Do:** wake it and ask something with a long answer: "explain how a bicycle stays
upright". Then stay **completely silent** and let the whole reply play.

Repeat three times.

**Pass:** no `heard` events at all during the `speaking` phase.

**Fail:** any `heard` event while `speaking`. That means the recognizer is picking up the
reply through the glasses speaker.

**Note down:** if it fails, which command matched, what the transcript was, and roughly
how far into the reply. A single spurious `stop` near the end is a different problem from
constant retriggering.

---

## Test 3. Does silence endpointing cut you off?

`silenceThreshold: 0.015` was picked for HFP being noisy. It has never met actual HFP.

**Do:** four turns, and pay attention to whether the capture click lands while you are
still talking.

1. Short question, no pauses: "what color is this"
2. Long question, one natural mid-sentence pause: "I'm looking at this label, and, tell me
   whether there's anything in here I should avoid"
3. Question with a long thinking pause: "so this is the thing I mentioned... what do you
   make of it"
4. Start speaking immediately on the wake cue, no gap.

**Pass:** the `recording endpointed` event shows a duration that matches what you actually
said, and none of the four got clipped.

**Note down:** the duration for each. If number 3 clipped, `trailingSilence` (0.9s) is too
short. If any recording ran to the 15s ceiling with you silent, `silenceThreshold` is too
low for the glasses mic and it never hears silence at all. Both are one-line constants.

---

## Test 4. Are seven earcons actually distinguishable?

They were designed on paper. That speaker is small.

**Do:** trigger each one and write down what you heard, without looking at the list:

- wake heard (rising two note) — say "hey glass"
- frame taken (single tick) — happens right after
- thinking (quiet repeated tick) — only if the reply takes over 1.2s
- cancelled (falling two note) — say "never mind" mid-question
- error (low double buzz) — kill the backend and ask something
- asleep (descending three note) — say "go to sleep"
- awake (ascending three note) — toggle it back on in Setup

**Pass:** you can tell wake from cancelled, and capture from thinking, without being told
which one is playing. Those are the two pairs that matter.

**Note down:** any pair you cannot distinguish, and anything inaudible in normal ambient
noise. Amplitude and pitch are both easy to change.

---

## Test 5. Do the three commands work?

**Do, one per turn:**

1. Wake, start asking, then say "never mind" mid-question. Expect the falling cue and
   nothing sent.
2. Wake, ask something long, then say "stop" while it is replying. Expect playback to cut.
3. Say "go to sleep" while idle. Expect the descending cue and the Live Activity to end.
   Force-quit and relaunch: it should still be asleep.

Then the one that proves the scope design:

4. Wake it and ask, out loud, "should I stop taking this medication". Let the reply play
   all the way through.

**Pass on 4:** the reply is not interrupted, and the log shows a `heard` event for
`stopSpeaking` with `armed: false` while phase was `listening`.

That last one is the money shot for the case study. It is also the only way to see that
the scope logic is doing anything at all.

---

## Test 6. Latency baseline

**Do:** five normal turns. Nothing special.

**Note down:** `stt` and `llm` from each recording, and your gut on whether the wait felt
tolerable.

This is the before number. Phase C swaps Whisper for Groq and we measure again.

---

## After

Bring back the `recordings` folder and your notes on each test. What we do next depends
almost entirely on test 2.

# Demo recording guide

Everything in this guide works on hardware as of 2026-08-13. Nothing here is aspirational.

**Audience note.** These clips are for a case study aimed at people building always-on
ambient wearables. That changes the emphasis: the impressive part is not that it answers
questions, it is that it knows *when you meant it*, and that you can shut it up. Shots 3
and 5 carry more weight than they look like they should.

---

## Before you press record

1. **Glasses on, unfolded, connected.** Check Settings → Status shows *Connected*. If the
   log says `devices: wait timed out`, unfold them and relaunch.
2. **Backend up.** `curl -s http://100.96.61.83:8082/healthz` → `{"status":"ok"}`. It runs
   on the mini, so it should already be up.
3. **Both phrases armed.** Settings → Agents should list `hey glass` and `hey claude`.
4. **Somewhere quiet.** The audio is the product. Room tone raises the noise floor, which
   makes barge-in less sensitive and the earcons harder to hear.
5. **Film the phone screen too.** The live transcript, the working dots, and the photo
   landing in the chat are what read on camera. A shot of your face while you talk to
   nothing is not the story.

---

## The shots

Five, about two minutes total. Ordered so each one sets up the next.

### 1 · The loop is fast, and most questions need no eyes

> **"hey glass, how long do I boil an egg"**

Rising two-note cue, your words appear live on screen, ~5 seconds, spoken answer.

**Proves:** the round trip is 5.2–5.5s, and no camera was involved. Every other glasses
assistant demo opens with a photo. This one deliberately does not.

---

### 2 · Vision is opt-in, by saying so

> **"hey glass, look at this and tell me what it is"**

Say **look** naturally, mid-sentence. Point at something with text on it — a label, a
book spine, a product box.

Watch for: the capture tick firing *while you are still talking*, then the photo appearing
above your question in the chat.

**Proves:** the camera runs only when asked. The word fires mid-sentence and the capture
runs concurrently with the rest of your question, so it costs nothing.

*Retake if:* the tick does not fire. The camera is marginal (~6s to deliver) and
occasionally does not.

---

### 3 · It knows when you did not mean it

Two takes, back to back. **This is the subtle one and it is worth the extra minute.**

**3a — the interruption works:**

> **"hey glass, explain how a bicycle stays upright"**
> …then, over the top of the reply, without any wake phrase: **"what about motorcycles"**

It should cut off mid-sentence and answer the new question, in the same thread.

**3b — but it is not just listening for noise:**

> **"hey glass, should I stop taking this medication"**

Let the whole reply play. **Nothing happens** when you say the word "stop".

**Proves:** the two halves together. It hears everything, and it distinguishes *talking to
it* from *talking near it*. Commands are armed by phase — "stop" only counts while a reply
is playing, the wake phrase only while idle. On camera 3b looks like nothing happening,
which is exactly why it needs 3a next to it.

*This is the shot for an always-on audience.* Anything can listen constantly. The design
problem is not acting on everything it hears.

---

### 4 · The same question, two agents — **the one-clip pick**

> **"hey glass, what do you know about me"**
> → *"I don't know who you are."*
>
> **"hey claude, what do you know about me"**
> → *"you're Kish. operator not IC, taste is your edge…"*

Same hardware, same microphone, same sentence. Only the wake phrase changed.

**Proves:** the whole thesis in about twenty seconds with no narration. The device knows
nothing about which agent is which — it asks the backend at launch what exists and arms a
phrase for each. Adding a third is a config file and a restart.

For an ambient device this is the load-bearing idea: *what answers you* has to be swappable
without rebuilding *the thing that listens*.

---

### 5 · The off switch

> **"go to sleep"**

Descending glide. The Live Activity ends. Then **force-quit and relaunch** — it is still
asleep.

**Proves:** the trust surface. A device that listens all the time is only acceptable if
turning it off is as easy as talking, and if it stays off. Persisting across a restart is
the part that makes it a promise rather than a toggle.

---

## If you want one more

**The failure that is not a failure.** Ask something that needs eyes without saying look:

> **"hey glass, what am I holding"**
> → *"I don't see an image. Say look and I'll take a picture."*

It explains the interaction rather than guessing or erroring. Good beat if the case study
has room for how the system behaves when it cannot answer.

---

## After recording

Every turn writes a JSON event log to the app's `Documents/recordings/`. Pull them off
with:

```
xcrun devicectl device copy from --device F279F78D-DD9F-5C73-84A3-A649633D07CB \
  --domain-type appDataContainer --domain-identifier com.kish.glassbridge \
  --source Documents/recordings --destination ./recordings
```

Those files are the raw material for the annotated timeline — waveform, earcon markers,
phase bands, and a lane showing a command that was heard and deliberately ignored. Shot 3b
produces exactly that record. It is the only artifact that makes an invisible decision
visible, and it is not built yet.

---

## Numbers, if a clip needs a caption

| | |
|---|---|
| Round trip, built-in agent | 5.2–5.5s (stt 1.6 · llm 2.5–3.1 · tts 0.8) |
| Round trip, personal agent | ~10.5s |
| Speech-to-text | 12.0s → 1.55s after moving to the GPU |
| Echo leaking into the mic while a reply plays | 0.0000–0.0002 |
| Photo from the glasses | ~6s, 374–403 KB |

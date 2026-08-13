# Queued for you — 2026-08-13

Everything is committed, pushed, and installed. Backend running on the mini.

## 1. KishOS has its own wake phrase  (~2 min)

Say **"hey claude, what should I focus on today"**.

Verified working overnight, same question to each:
  hey glass   -> "I don't know who you are."
  hey claude  -> "you're Kish. operator not IC, taste is your edge... right now the
                  honest focus is close to home: your dad's treatment, Aarthi's visa."

Settings -> Agents lists both phrases. An eye icon marks the one that can see.
Adding a third is an edit to agents.json + a backend restart. No rebuild, no Swift.
Contract in docs/AGENTS.md.

## 2. The one measurement I need  (~1 min, matters most)

Wake it, ask **"explain how a bicycle stays upright"**, then stay COMPLETELY SILENT
through the whole reply.

Then tell me. I pull one line:

  [OPEN] closed: window elapsed - peak 0.041 - echo 0.006 - floor 0.005 - trigger 0.020

`echo` is the loudest the mic heard while the reply was playing. Near the floor means
echo cancellation works and barge-in can be aggressive. Close to `peak` means the reply
is leaking into the mic, and no energy threshold will ever separate you from it.

This settles the question that has been open since the first hardware session.

## 3. Barge-in, second attempt  (~2 min)

Talk over a reply. Just talk, no wake phrase.

Last attempt failed and the research explains why: your voice over HFP arrives ~15 dB
quieter than close-mic, so my 0.030 threshold sat near the PEAK of glasses speech rather
than its body. It now tracks the room's noise floor and triggers 12 dB above it, so
sensitivity follows the environment instead of a number I guessed wrong twice.

## 4. Earcons to pick from  (~5 min)

    open docs/earcons/index.html

Three complete sets, "Play a whole turn" on each. Listen on the glasses if you can.
  a-glass    pure sines, what ships today. neutral, iOS-ish.
  b-warm     same intervals, softer timbre. a chime not a beep.
  c-tactile  struck bells + pitch glides. most physical, least like a computer.

Tell me a set, or mix cues across sets, and I will wire it.

## Reading, if you want it

  docs/RESEARCH.md   prior art, what Meta actually does, industry numbers vs ours
  docs/AGENTS.md     how to plug in another agent

Headline from the research: Meta ships "respond without Hey Meta" ON by default, which
is the open-conversation window you asked for independently. And their real trick is not
hearing you, it is knowing when you meant them: they filter "speech not intended for the
glasses". That is intent classification, not energy, and it is the known ceiling of our
approach.

## Still open

- KishOS answers in ~10.5s vs ~5.3s for glass. Agentic loop; the thinking earcon covers it.
- Follow-up window is fixed at 15s. OpenVision makes it configurable 15s-2min.
- KishOS is acceptsImages:false, so "look" does nothing there. Its gateway has an /upload
  endpoint if you want images routed to it.

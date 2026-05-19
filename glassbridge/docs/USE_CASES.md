# Use Cases: What Glasses Unlock that Phones Don't

The phone is a deliberate device. You take it out, unlock it, open an app,
type, hit send. Every step is friction, and the friction is the reason you
*don't* do most things you could theoretically do with AI.

Glasses are different. Two things change:

1. **The camera is already pointing at what you care about.** You don't have
   to frame a shot. The model sees the thing you're looking at, which is
   almost always the thing you'd be asking about.
2. **The mic and speaker are always on your head.** You don't context-switch
   between "talking to a person" and "talking to a model" — the same channel
   carries both.

This document is a thinking tool for what to build *because* of those two
changes, not despite them. The MVP in this repo is the substrate; the things
below are workflows you'd wire on top of it.

Each entry is structured as:

- **Trigger** — what kicks it off (button, voice, location, schedule).
- **Inputs** — what's captured (frame, video clip, audio, context).
- **What Claude does** — the actual model call, tool-use, memory access.
- **Output** — voice, on-glasses display (Display models), iPhone notification, downstream side-effect.
- **Why glasses specifically** — what makes this not-a-chatbot.

---

## Tier 1 — Already work on the MVP today

These need nothing beyond what's shipped: one frame, one voice query, one
voice reply. Just system-prompt tweaks.

### 1. "What is this?" — the always-on identifier
- **Trigger** Tap ASK.
- **Inputs** Frame + voice query (or none).
- **What Claude does** Identifies the object, with one line of practical info.
- **Output** Voice.
- **Why glasses** Plant in a friend's apartment, mystery dial on a
  rental car dashboard, button on a hotel shower you can't decode. You
  never have to ask a stranger what something is again.

### 2. Live menu and label translator
- **Trigger** Tap ASK, "translate this".
- **Inputs** Frame of foreign-language menu/sign + voice.
- **What Claude does** Returns the translation directly, prefers natural
  rendering over literal ("creamy lemon chicken" not "chicken in lemon
  cream sauce").
- **Output** Voice. Also persist transcript on the iPhone so you can read
  the long ones.
- **Why glasses** You're sitting at the table, looking at the menu. The
  alternative is squinting at Google Translate held an inch above the paper
  while the waiter waits.

### 3. Receipt and expense narrator
- **Trigger** Tap ASK, "log this".
- **Inputs** Frame of a receipt.
- **What Claude does** Extracts vendor, total, date, category. Speaks
  back the line items it picked up so you can correct on the spot.
- **Output** Voice confirmation + write to a local CSV / Notion / Airtable
  via a tool call (Tier 2 wiring).
- **Why glasses** Receipt logging at the moment of payment, not three
  weeks later when you can't remember what the dinner was about.

### 4. Reading-aloud with reflow
- **Trigger** "Read this to me."
- **Inputs** Frame of any text — a letter, a packaging label, a museum plaque.
- **What Claude does** OCRs (it's just Claude reading the image), reflows
  paragraphs, speaks them through ElevenLabs. Skips fine print unless asked.
- **Output** Voice.
- **Why glasses** Walking through a museum with both hands free. Reading
  small print on a medicine box without finding your glasses. (Yes, this is
  funny.)

### 5. "Is this the right one?"
- **Trigger** "Is this the X I'm looking for?"
- **Inputs** Frame + voice describing what you want.
- **What Claude does** Compares image to spec, calls out mismatches.
- **Output** Voice.
- **Why glasses** Hardware store. Spare bolts, light bulb bases, USB-C vs
  Lightning. Returns avoided.

### 6. Cooking copilot, single-shot
- **Trigger** "What do I do next?"
- **Inputs** Frame of the pan / counter / recipe card + history (last 3 turns).
- **What Claude does** Sees state ("onions are translucent, no color yet"),
  references the recipe in history, gives the next step.
- **Output** Voice.
- **Why glasses** Hands literally covered in flour.

### 7. Outfit / decor check
- **Trigger** "How does this look?"
- **Inputs** Frame (you, in a mirror).
- **What Claude does** Honest, specific feedback — "the navy reads dressier
  than the rest, swap for the gray".
- **Output** Voice.
- **Why glasses** Faster than asking your roommate.

### 8. "What did I just look at?"
- **Trigger** "Save that."
- **Inputs** Last frame in memory + a one-line voice label.
- **What Claude does** Writes a one-line description + the label to a "visual
  scratchpad" (local SQLite or Notion).
- **Output** Voice confirmation.
- **Why glasses** You walk past a poster, a book on someone's shelf, a sign.
  You don't have time to take out a phone. You will completely forget about
  it by tomorrow.

---

## Tier 2 — Adds tool-use (small backend lift)

Add Anthropic tool-use to the Claude call. Each tool is a small Python
function the backend exposes to the model. Pattern is the same: model
decides when to call a tool, backend runs it, result goes back into the
conversation.

### 9. Personal memory: "where did I leave …"
- **Trigger** "Where did I last see my keys?"
- **Inputs** Voice only, no frame needed.
- **What Claude does** Calls a `query_visual_memory(text)` tool that does
  a semantic search over the per-look descriptions saved in #8.
- **Output** Voice.
- **Why glasses** This use case is *only* possible if the capture is
  effortless. If you have to pull out a phone to log "keys on counter",
  you never do. Glasses + a button-tap or wake word makes it free.

### 10. Reminder bound to a thing
- **Trigger** "Remind me to refill this when it's half empty." (looking at a
  detergent bottle)
- **Inputs** Frame + voice.
- **What Claude does** Calls `create_visual_reminder(image, instruction)`.
  Backend stashes the image embedding + the trigger. Future ASKs check it.
- **Output** Voice. Future re-trigger sends an iPhone push.
- **Why glasses** Anchoring a reminder to a physical object, not a calendar
  date, only works if the capture is incidental.

### 11. Calendar / email peek
- **Trigger** "Anything I should know about today?"
- **Inputs** Voice only.
- **What Claude does** Calls `gcal_today()` + `gmail_unread_priority()` tools.
- **Output** Voice summary.
- **Why glasses** Replaces the "open phone, check calendar app, check email,
  put phone away" loop. About 30s saved per check, 5-10 checks per day.

### 12. Shopping price-and-spec check
- **Trigger** Looking at a product, "Worth it?"
- **Inputs** Frame + voice.
- **What Claude does** Identifies the product, calls a `web_search(query)`
  tool, returns price range + a quick verdict ("Amazon has it for $32, this
  store's $48 is high but not insane").
- **Output** Voice.
- **Why glasses** In-store decisions take 10x less time than phone-out
  research. Most people skip the research and either overpay or skip the
  purchase.

### 13. Plant / pet / kid care lookup
- **Trigger** Looking at a houseplant, "Am I underwatering this?"
- **Inputs** Frame + voice.
- **What Claude does** Identifies species (vision), calls
  `web_search("monstera deliciosa watering")`, synthesizes.
- **Output** Voice.
- **Why glasses** The moment you notice droopy leaves *is* the moment you'd
  want to know. Not 6 hours later.

### 14. Personal context lookup ([[me]] skill)
- **Trigger** "Did I take notes on this book?" (looking at the cover)
- **Inputs** Frame + voice.
- **What Claude does** Vision identifies the book → calls a
  `personal_context(query)` tool that hits the user's personal-context MCP
  server (notes, email, calendar going back years).
- **Output** Voice: "Yes — your notes from Oct 2024 said the second half
  drags but Chapter 7's framework on X is still the thing you reference."
- **Why glasses** Your past is finally co-located with your present. This
  is the killer use case for people who write a lot down.

---

## Tier 3 — Modes (system-prompt + tool-bundle switching)

A "mode" is a saved combination of: system prompt + enabled tools + memory
scope + output style. Switching modes happens by voice ("cooking mode on")
or by a small mode-picker in the iOS app.

### 15. Research / journaling mode
- **System prompt** "I am brainstorming. Be a sparring partner, not an
  assistant. Push back. Ask one good question per turn."
- **Tools** `personal_context`, `web_search`, `save_to_journal`.
- **Output** Voice + writes a structured journal entry the iPhone shows.
- **Why glasses** Walking-while-thinking is the historical mode for
  philosophers. Now you can do it with a sparring partner who has perfect
  memory of every walk you've ever taken.

### 16. Code-review-on-the-walk mode
- **System prompt** "I'm reviewing a PR. Read me changed files one at a time.
  Pause for my reactions. Don't summarize, quote the diff."
- **Inputs** Voice; pulls PR from GitHub via a tool.
- **Tools** `gh_pr_diff(num)`, `gh_post_review_comment(file, line, body)`.
- **Why glasses** Walking is where the best code-review feedback comes from.

### 17. Accessibility mode (low vision)
- **System prompt** "Describe scenes for someone who can't see well. Lead
  with people, then obstacles, then context. Read all text aloud verbatim."
- **Trigger** Continuous low-rate frame sampling (2 fps), pushes a verbal
  description every 5s + on-demand "what's that".
- **Why glasses** This is the use case the hardware was practically designed
  for. The DAT SDK photo-capture API is fast enough; you'd batch frames and
  let Claude tell you when something *changed*.

### 18. Tour-guide mode (location-aware)
- **System prompt** "You're a knowledgeable, opinionated local guide for
  $CITY. Two sentences max."
- **Trigger** Tap ASK while pointing at a building/landmark.
- **Tools** `wikipedia(title)`, `gps_location()` (from the iPhone) so model
  knows where it is.
- **Why glasses** Strangers in a city. Replaces ~80% of what you'd get from
  a $40 walking tour.

### 19. "Show me what I'm not seeing" — domain-specific noticing
- **System prompt** "I'm a $ROLE. Tell me what's wrong / interesting / off
  in this scene, from my professional perspective."
- **Examples**:
  - For a chef walking through a market: "the lemons in the back bin are
    over-ripe but cheap; good for preserved lemons."
  - For an electrician walking through a basement: "that's a federal-pacific
    panel, those are flagged for fire risk."
  - For a parent: "the cabinet under the sink isn't latched and there's
    drain cleaner visible."
- **Why glasses** A model with a specific perspective sees things you'd
  walk past.

### 20. Live transcription + soft real-time summary
- **System prompt** "Transcribe and lightly clean up. Every 60 seconds,
  surface a 1-line summary of what's been said so far."
- **Trigger** "Start meeting." → continuous mic capture (longer than 5s).
- **Output** Live transcript on iPhone; voice summary nudges in your ear at
  intervals.
- **Why glasses** You can be in a conversation, not buried in a notes app.

---

## Tier 4 — Triggers other than the button (workflow primitives)

The MVP only triggers on a button. The interesting product is when triggers
are first-class.

### 21. Wake-word triggers
- "Hey Claude" / "Claude, " preamble → uses iOS speech recognition for the
  wake-word so we don't ship audio to a cloud during idle, then handoff to
  the full pipeline on detection.
- Different wake words can route to different *modes*: "Note this" → journal
  mode; "What's that" → identify mode.

### 22. Time triggers (cron)
- "Every morning at 7, tell me what's on my plate today and remind me to
  take vitamins."
- The backend runs cron-style; the trigger pushes a notification to the
  iPhone which can speak through the glasses if active.

### 23. Place triggers (geofence)
- "When I get to Whole Foods, list things on the shopping list" (from a
  shared list maintained throughout the week as you add items by voice).
- iPhone geofence → notification → glasses voice.

### 24. State triggers (memory deltas)
- "If I look at the laundry hamper and it's full, remind me to run a load."
- The visual-memory store tracks state of named things. Tier-2 #10 reminders
  pattern, generalized.

### 25. Calendar-edge triggers
- 10 minutes before a meeting → "Brief me." → glasses voice plays a
  one-paragraph summary built from your past notes on the attendees.

---

## Tier 5 — Speculative, "would need different hardware"

The Display models (Meta Ray-Ban Display) add a heads-up display surface.
Most of Tier 1-3 above would have a visual companion:

- Tier 1 #2 (translate): the translation can appear *over* the menu
  visually instead of being spoken.
- Tier 2 #11 (calendar peek): glance up, see today's three items.
- Tier 3 #20 (transcription): live captions for hearing-impaired users in
  conversation.

The Glassbridge architecture doesn't change — same backend pipeline, just
an additional "display payload" output channel alongside voice.

---

## Where the unique value compounds

The above are mostly individual workflows. The interesting thing is what
happens when you stack them across months:

1. **Your visual scratchpad becomes a personal-truth dataset.** Every
   one-line "I saw X at Y context" entry is signal. After 6 months of
   wearing the glasses 4 hours a day, you have ~10K entries that describe
   your life with a fidelity no Apple Photos timeline can match. Queries
   like "what do I usually have for lunch on tuesdays" become trivial.
2. **You spend less time on your phone.** Most of the Tier 1-2 use cases
   replace a 30-second phone interaction with a 5-second voice interaction.
   That's not just speed — it's psychological. You stop opening the phone
   for the small things, which means you stop opening the phone for the
   medium things either. People who run this for a month report that.
3. **The model develops a *you*-shaped voice.** With a long-running
   personal-context MCP feeding the LLM your notes/emails/journal, the
   replies stop sounding like Claude and start sounding like your own
   reasoning, played back to you. Walking-and-thinking with a model that's
   read everything you've ever written is a genuinely new mode of work.

The MVP in this repo is just the I/O loop. The workflows + modes + triggers
are the product. See [`ARCHITECTURE_V2.md`](ARCHITECTURE_V2.md) for what
that looks like as code.

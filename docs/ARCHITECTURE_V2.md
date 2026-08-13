# Glassbridge V2: a programmable workflow runtime for your glasses

The MVP is a single hardcoded pipeline:

```
button → 1 frame + 5s audio → whisper → claude(vision) → elevenlabs → speaker
```

That's the I/O loop. **V2 makes that loop a generic substrate, and lets
"what should happen on a trigger" become a small piece of code you can edit
without touching iOS or Swift.**

Concretely: every interaction on your glasses is the execution of a
*Workflow*. A workflow is a value, not a build. You add new workflows in
seconds; you edit existing ones while the system is running.

## The mental model

```
TRIGGER  →  INPUTS  →  POLICY  →  EFFECTS
  what       what       which        what to
  starts     to         model        do with
  the run    capture    runs +       the model
                        with what    output
                        tools/memory
```

Five primitives, all swappable. The MVP is one hardcoded combination of
these. V2 is a registry of named combinations.

### Primitive 1: Trigger

What initiates a run.

```yaml
triggers:
  manual_ask:       # the MVP
    kind: button
  hey_claude:
    kind: wake_word
    phrase: "hey claude"
  morning_brief:
    kind: cron
    schedule: "0 7 * * *"
  enter_office:
    kind: geofence
    place: home_to_office
  pre_meeting:
    kind: calendar_edge
    minutes_before: 10
  state_change:
    kind: visual_delta
    watch: "laundry hamper"
    rule: "fullness changed by >=20%"
```

The trigger fires; what comes next depends on the workflow that owns it.

### Primitive 2: Inputs

What the trigger captures.

```yaml
inputs:
  none: []                       # voice query only
  one_shot: [photo, audio_5s]    # the MVP
  context_burst: [photo, audio_5s, photos_last_3]
  voice_only: [audio_5s]
  continuous: [video_30s, mic_30s]
  visual_state: [photo]          # for state-change triggers
```

The iOS app exposes these as named capture *recipes*. The Swift side knows
how to fulfill each one.

### Primitive 3: Policy (the model call)

The actual LLM call: which model, what system prompt, what tools, what
memory scope. This is the meat. In V2, a Policy is a small Python class
the backend registers by name.

```python
@workflow.policy("identify")
class IdentifyPolicy:
    model = "claude-sonnet-4-6"
    system = (
        "You are looking through the user's glasses. "
        "Identify the main subject of the image in one short spoken sentence. "
        "If they asked something specific, answer that first."
    )
    tools = []
    memory = MemoryScope.none

@workflow.policy("personal_research")
class PersonalResearchPolicy:
    model = "claude-sonnet-4-6"
    system = (
        "You are the user's research sparring partner. "
        "You have access to their notes and emails going back two years. "
        "Push back. Quote their own past writing back at them when relevant."
    )
    tools = [PersonalContextTool, WebSearchTool, SaveToJournalTool]
    memory = MemoryScope.session_plus_durable("research_threads")
```

Tools are standard Anthropic-style tool-use schemas wired to local
functions. Memory scope decides what conversation history gets injected.

### Primitive 4: Effects

What happens to the model's output. Voice is just one effect; in V2 a
single run can fan out to multiple.

```yaml
effects:
  speak:           # the MVP
    kind: tts_glasses
    voice: rachel
  speak_briefly:
    kind: tts_glasses
    voice: rachel
    max_seconds: 4
  display:         # Display models only
    kind: heads_up
    style: bullet
  write_log:
    kind: append_file
    path: ~/glassbridge/visual_log.jsonl
  push_to_notion:
    kind: notion_block
    page_id: $WORKFLOWS_PAGE
  iphone_notification:
    kind: ios_push
    title: "Glassbridge"
```

A "log this receipt" workflow uses `speak_briefly` + `push_to_notion`.
A morning brief uses `speak` + `iphone_notification` so you can re-read
the brief later.

### Primitive 5: Workflow (the binding)

A workflow ties one trigger to one inputs recipe, one policy, and N
effects.

```yaml
workflows:
  ask:
    trigger: manual_ask
    inputs: one_shot
    policy: identify
    effects: [speak]

  log_receipt:
    trigger:
      kind: wake_word
      phrase: "log receipt"
    inputs: one_shot
    policy: receipt_extract
    effects: [speak_briefly, push_to_notion]

  morning_brief:
    trigger: morning_brief
    inputs: none
    policy: morning_brief_policy
    effects: [speak, iphone_notification]

  research_mode:
    trigger:
      kind: wake_word
      phrase: "research mode on"
    inputs: voice_only
    policy: personal_research
    effects: [speak, write_log]
```

## What changes in the codebase

### Backend (Python)

- **`backend/workflows/`** — directory. One file per workflow definition
  (Python module exporting a `WORKFLOW` constant) plus a `policies/`
  subdir of Policy classes.
- **`backend/main.py`** — `POST /ask` becomes `POST /run`. Body adds
  `workflow_id`. The endpoint dispatches to the named workflow's Policy.
- **`backend/triggers/`** — long-running trigger drivers (cron, geofence
  listener, calendar-edge poller). Each pushes events into the same `/run`
  dispatcher as if the button had been tapped.
- **`backend/tools/`** — registry of callable tools (web_search,
  gcal_today, personal_context, etc.). Policies declare which they want.
- **`backend/memory/`** — pluggable: per-session ring (MVP), per-workflow
  durable (SQLite), full personal corpus (delegate to the user's
  personal-context MCP server).

### iOS

- **Capture recipes** become a thin Swift enum: each variant knows how to
  produce its inputs (DAT photo, AVAudioRecorder 5s clip, etc.).
- **Trigger sources** stay split: button + wake-word run on the device;
  cron + geofence + calendar-edge run on the backend and push the iPhone
  via APNS when they need glasses time.
- **Mode UI** (optional): a list of workflows you can toggle on. The
  ASK button gets a long-press menu for "run with workflow…".

### Wire protocol

`POST /run` becomes the universal dispatch endpoint:

```http
POST /run
Content-Type: multipart/form-data

workflow_id=log_receipt
session_id=<uuid>
audio=@capture.wav
image=@frame.jpg
```

Response: same as MVP (streaming MP3 if the policy wants TTS) plus
structured side-effect telemetry headers.

For cron/geofence triggers the backend just calls its own `/run` handler
internally — no HTTP roundtrip.

## What this buys you

1. **New workflows in minutes, not commits.** Edit a YAML file or drop a
   Python class in `workflows/`. Hot-reload on the backend. The iOS app
   doesn't change.
2. **One Swift app, many "products".** "Research mode," "translator,"
   "receipt logger," "tour guide" are all the same binary. You don't ship
   to TestFlight to try a new use case.
3. **Triggers are first-class.** "Do X every morning" is symmetric with
   "do X when I press the button". Cron and the button hit the same
   dispatcher.
4. **Tools and memory compose.** Wiring `personal_context` into a new
   workflow is one line. The MCP server you already run for your
   notes/email becomes a tool any workflow can opt into.
5. **The data layer becomes interesting.** A `write_log` effect on
   "identify what I'm looking at" produces a JSONL stream of every
   intentional look you've taken. That stream becomes its own input for
   future workflows ("review what I noticed last week").

## What this explicitly is NOT

- **Not a no-code platform.** YAML for the binding, Python for the policy
  and tools. If you're writing prompts and integrations, you're writing
  code. The point is that the *plumbing* is one-time.
- **Not a multi-user system.** This is yours. Single account, single
  device. Don't pay the price of multi-tenancy for one user.
- **Not async-by-default.** The MVP loop is synchronous and ~4–6s.
  Workflows that need to be slow (e.g., long research) opt-in to async
  delivery via iPhone notification rather than the in-ear voice.
- **Not a separate "agent" abstraction.** A workflow *is* a small agent
  in the modern sense (policy + tools + memory + I/O). No need for a
  framework on top.

## A 90-minute path from MVP to V2 sketch

If you wanted to start exploring this without the full rewrite:

1. **Hour 1**: Rename `/ask` to `/run`, add a `workflow_id` form field,
   default it to `"identify"`. Move the current system prompt into a
   `policies/identify.py` module. Verify nothing changed end-to-end.
2. **Hour 2**: Add a second policy, `policies/receipt.py`, with a tighter
   system prompt and a single `append_to_csv` tool. Add a hidden second
   button in the iOS app that posts with `workflow_id=receipt`.
3. **Hour 3**: Add a third policy that calls your personal-context MCP
   server through a tool. Now `workflow_id=me` answers questions from
   your own notes.

At that point the abstraction is real and the rest is adding triggers and
effects as you actually want them.

---

The MVP is the kernel. V2 is the OS.

# Agents

Glassbridge is a pair of glasses, a microphone, and a speaker. **What answers you is
pluggable.** Each agent gets its own wake phrase, and adding one is an edit to
`agents.json` plus a backend restart. No app rebuild, no Swift.

```
"hey glass"   → the built-in agent: Claude, with eyes and web search
"hey kishos"  → KishOS: personal corpus, ledger, goals, its own tools
"hey <yours>" → whatever you point it at
```

## Why it is split this way

The built-in agent is deliberately ignorant. It sees what your camera sees and can search
the web, and it knows nothing about you. That is right for "what is this thing in front of
me" and wrong for "what should I be doing today".

Rather than teaching one agent everything, a second wake phrase routes to an assistant that
already knows. Ask the wrong one and it will tell you honestly: "I don't know who you are."

## Adding an agent

Copy `agents.example.json` to `agents.json` and add an entry:

```json
{
  "id": "kishos",
  "label": "KishOS",
  "wakePhrase": "hey kishos",
  "type": "gateway",
  "url": "http://127.0.0.1:17890/chat",
  "healthUrl": "http://127.0.0.1:17890/health",
  "tokenFile": "~/.kishos/secrets/shared-secret",
  "acceptsImages": false,
  "context": "Answer in at most two short spoken sentences. No markdown."
}
```

Restart the backend. The app fetches `GET /agents` at launch, arms a trigger phrase for
each, and shows them under Settings → Agents.

`agents.json` is gitignored, because it can carry tokens. `agents.example.json` is not.

### Fields

| Field | Meaning |
|---|---|
| `id` | Sent to `/ask` as `agent=`. `glass` is reserved for the built-in one. |
| `wakePhrase` | What the glasses listen for. Matched on whole words. |
| `type` | Only `gateway` today: HTTP POST in, NDJSON out. |
| `url` | Where to POST. |
| `token` / `tokenFile` | Bearer auth. Prefer `tokenFile` so secrets stay out of config. |
| `acceptsImages` | Whether "look" means anything for this agent. |
| `context` | Prepended per turn, not stored. Use it to say the reply will be spoken. |
| `timeoutSeconds` | Default 90. Agentic assistants are slower than a single model call. |
| `textField` / `threadField` / `replyField` | Rename the JSON fields for services that differ. |
| `extraBody` | Merged into every request. |

### The wire contract

POST the configured `url` with `{"threadId": "...", "text": "..."}` and a bearer token.
Answer with newline-delimited JSON:

```
{"type":"status","status":"queued"}
{"type":"text","text":"partial answer "}
{"type":"done","ok":true,"text":"the whole answer","ms":4106}
```

`done.text` is preferred; the streamed `text` events are the fallback. `{"type":"error"}`
surfaces to the user as spoken words, so phrase those for the ear.

## Two things worth knowing

**The agent owns its memory.** Glassbridge sends a stable `threadId` and nothing else. It
does not send history to gateway agents, because an assistant that keeps its own transcript
does it better than we can from outside. The built-in agent is the exception: it has no
memory of its own, so the 3-turn rolling history lives in Glassbridge for that one.

**Agents built for screens write for screens.** The first live KishOS reply came back as 45
seconds of speech with markdown in it. The `context` field fixes this without touching the
agent: it is prepended to the prompt and kept out of the transcript, so it shapes the answer
without polluting the conversation. Measured on the same question, adding it took the reply
from 871 KB of audio to 246 KB and the turn from 20.6s to 10.5s.

## Latency

An agentic assistant is slower than one model call, and it shows.

| | Round trip |
|---|---|
| `hey glass` | ~5.3s (stt 1.6 · llm 3.1 · tts 0.8) |
| `hey kishos` | ~10.5s |

The thinking earcon holds back 1.2s before it starts ticking, which covers the first case
entirely and makes the second audible as "working" rather than as "broken".

# Pick up here

Last session: 2026-08-12 evening → 08-13 midday. 35 commits, all pushed, `main` clean.

## State of things

Working on real hardware, verified: the hands-free loop (~5.2s), the spoken vocabulary
(`look`, `never mind`, `stop`, `go to sleep`), barge-in, the 15s open conversation, and two
agents on separate wake phrases. Six of seven hardware validation tests pass; the seventh
(earcon distinguishability) was never formally run, only used.

**Backend lives on the Mac mini** and the phone reaches it over Tailscale. Both were up at
`100.96.61.83:8082` when this was written. To restart:

```bash
ssh kishparikh@kishs-mac-mini-1 'cd ~/Code/glassbridge && ./run.sh'
```

**The phone was disconnected at the end**, so the last three fixes (wake-phrase label, the
auto-test image, the sheet detent) are in git and on the simulator but **not on the
device**. Reconnect and:

```bash
cd ios && xcodebuild -project Glassbridge.xcodeproj -scheme Glassbridge \
  -destination 'id=00008150-001A65C41A12401C' -derivedDataPath build-dev \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device F279F78D-DD9F-5C73-84A3-A649633D07CB \
  build-dev/Build/Products/Debug-iphoneos/Glassbridge.app
```

## Next, in the order I would do it

**1. Record the demo.** Everything in [`DEMO.md`](DEMO.md) works. Five shots, ~2 minutes.
The one-clip pick is shot 4: the same question to both agents. Shot 3 is two takes and is
the one an always-on audience will care about most.

**2. Build the annotated timeline.** Scoped but not built. It reads a turn's JSON from
`Documents/recordings/` and renders waveform, earcon markers, phase bands, and a lane
showing a command that was *heard and deliberately ignored*. Shot 3b produces exactly that
record. It is the only artifact that makes an invisible decision visible, and the portfolio
session wants it as the signature visual.

**3. Decide what "sharing" means.** The repo is public and clean of secrets. Nobody can
install the app while Meta's toolkit is in Developer Preview, so the realistic options are
the repo as a reference implementation and the case study. If you want someone else to be
able to *run* it: backend URL as a setting rather than a constant, a shared token on
`/ask`, and a cold-start README pass. Maybe half a day.

## Loose ends

- **`/ask` has no auth.** Anyone on the tailnet can spend your Anthropic and ElevenLabs
  credits. Fine today, not fine the moment you add someone.
- **`ios/README.md` is stale.** The main README no longer links it. Update or delete.
- The glasses camera is the flakiest part: ~6s when it works, and Meta's permission flow is
  broken underneath. Do not build a demo beat that depends on it firing first try.
- The open-conversation window is fixed at 15s. OpenVision makes it configurable 15s–2min.
- KishOS is `acceptsImages: false`, so `look` does nothing on that agent. Its gateway has an
  `/upload` endpoint if you want images routed there.
- Untested in a noisy room. Every audio measurement we have is from a quiet one, and the
  wake word's sensitivity now adapts to the noise floor.

## Where things are

| | |
|---|---|
| Sound sets to audition | `docs/earcons/index.html` (shipping: tactile + two-chord pad) |
| Screenshots | `docs/screenshots/`, captured against the live backend |
| Case study handoff | `/tmp/glassbridge-case-study-handoff.md` (copy it somewhere durable) |
| Settings redesign trail | `~/.gstack/projects/KishParikh13-glassbridge/refine/20260812-194317-setup-settings/` |
| Simulator screenshots | `SIMCTL_CHILD_GB_SKIP_ONBOARDING=1 SIMCTL_CHILD_GB_SCREEN=agent xcrun simctl launch booted com.kish.glassbridge` |

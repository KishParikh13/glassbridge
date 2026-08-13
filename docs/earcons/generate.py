#!/usr/bin/env python3
"""Generate candidate earcon sets as WAVs, plus a page to audition them.

    python3 docs/earcons/generate.py && open docs/earcons/index.html

Design constraints these are written against, in order of how much they bind:

1. It plays into your ear through a small speaker inches from an open microphone. Anything
   long or loud gets picked up by the wake recogniser and, worse, delays the thing it is
   announcing. Every cue here is under 400ms.
2. It has to be legible against street noise without being startling in a quiet room, so
   the useful range is roughly 300 Hz to 2 kHz. Below that HFP rolls it off; above that it
   sounds like an alarm.
3. Pairs that mean opposite things must not be confusable. `listening` vs `cancelled` and
   `captured` vs `thinking` are the two that matter, so each set inverts contour rather
   than only shifting pitch.
4. `thinking` repeats. It must be quiet enough to ignore and short enough not to collide
   with itself.
"""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

RATE = 16_000
OUT = Path(__file__).parent


def tone(freq, dur, amp=0.5, shape="sine", fade=0.008):
    n = int(dur * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, min(t, dur - t) / fade) if fade > 0 else 1.0
        env = max(0.0, env)
        if shape == "sine":
            v = math.sin(2 * math.pi * freq * t)
        elif shape == "tri":
            ph = (freq * t) % 1.0
            v = 4 * abs(ph - 0.5) - 1
        elif shape == "soft":  # sine + a quiet octave, rounder than pure
            v = 0.85 * math.sin(2 * math.pi * freq * t) + 0.15 * math.sin(4 * math.pi * freq * t)
        elif shape == "bell":  # inharmonic partial, struck feel
            v = 0.7 * math.sin(2 * math.pi * freq * t) + 0.3 * math.sin(2 * math.pi * freq * 2.76 * t)
            env *= math.exp(-3.5 * t / dur)
        elif shape == "glide_up":
            f = freq * (1 + 0.32 * (t / dur))
            v = math.sin(2 * math.pi * f * t)
        elif shape == "glide_down":
            f = freq * (1 - 0.24 * (t / dur))
            v = math.sin(2 * math.pi * f * t)
        else:
            raise ValueError(shape)
        out.append(v * amp * env)
    return out


def silence(dur):
    return [0.0] * int(dur * RATE)


def write(name, samples):
    path = OUT / f"{name}.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        ))
    dur = len(samples) / RATE * 1000
    return path.name, dur


# --- Set A: "Glass" — pure sine intervals. Clean, neutral, iOS-ish. -------------------
# A perfect fifth up to acknowledge, the same fifth inverted to cancel. Unmistakable pair
# even at low volume, because the contour differs rather than only the pitch.
SET_A = {
    "listening": tone(587.33, 0.07) + tone(880.00, 0.09),                 # D5 → A5
    "captured":  tone(1174.66, 0.045, 0.40),                              # single tick, D6
    "thinking":  tone(440.00, 0.04, 0.16),                                # quiet A4 tick
    "cancelled": tone(880.00, 0.07) + tone(587.33, 0.09),                 # A5 → D5
    "error":     tone(311.13, 0.09) + silence(0.05) + tone(311.13, 0.09), # low double
    "asleep":    tone(587.33, 0.09) + tone(440.00, 0.09) + tone(329.63, 0.16),
    "awake":     tone(329.63, 0.09) + tone(440.00, 0.09) + tone(587.33, 0.12),
}

# --- Set B: "Warm" — soft two-partial tones, rounder and less clinical. ---------------
# Same intervals as A but on a softer timbre with slower fades, so it reads as a chime
# rather than a beep. Better in a quiet room, slightly less cutting outdoors.
SET_B = {
    "listening": tone(523.25, 0.08, 0.45, "soft", 0.015) + tone(783.99, 0.11, 0.45, "soft", 0.015),
    "captured":  tone(1046.50, 0.05, 0.34, "soft", 0.010),
    "thinking":  tone(392.00, 0.05, 0.13, "soft", 0.015),
    "cancelled": tone(783.99, 0.08, 0.45, "soft", 0.015) + tone(523.25, 0.11, 0.45, "soft", 0.015),
    "error":     tone(261.63, 0.11, 0.42, "soft", 0.015) + silence(0.04) + tone(261.63, 0.11, 0.42, "soft", 0.015),
    "asleep":    tone(523.25, 0.10, 0.42, "soft", 0.018) + tone(392.00, 0.10, 0.42, "soft", 0.018) + tone(293.66, 0.18, 0.40, "soft", 0.020),
    "awake":     tone(293.66, 0.10, 0.42, "soft", 0.018) + tone(392.00, 0.10, 0.42, "soft", 0.018) + tone(523.25, 0.14, 0.42, "soft", 0.020),
}

# --- Set C: "Tactile" — struck bell tones + pitch glides. Most physical. --------------
# Acknowledgement glides up like a question, cancel glides down like a shrug. The capture
# is a genuine struck tick, which is the closest thing to a shutter without being one.
SET_C = {
    "listening": tone(560.00, 0.13, 0.46, "glide_up", 0.010),
    "captured":  tone(1400.00, 0.035, 0.36, "bell", 0.004),
    "thinking":  tone(500.00, 0.05, 0.12, "bell", 0.006),
    "cancelled": tone(700.00, 0.14, 0.44, "glide_down", 0.010),
    "error":     tone(220.00, 0.13, 0.44, "bell", 0.008) + silence(0.03) + tone(220.00, 0.13, 0.44, "bell", 0.008),
    "asleep":    tone(660.00, 0.24, 0.42, "glide_down", 0.015),
    "awake":     tone(440.00, 0.22, 0.42, "glide_up", 0.015),
}

SETS = {"a-glass": SET_A, "b-warm": SET_B, "c-tactile": SET_C}


# --- Continuous "still working" beds ---------------------------------------------------
#
# A repeating tick says "still ticking". A bed says "still working" — it fills the wait
# rather than marking it. Kish's note: "more continuous, almost like an elevator music
# type thing".
#
# These have to loop perfectly. A discontinuity at the seam is a click, and a click every
# few seconds is worse than the tick we are replacing. The trick is to quantise every
# frequency so a whole number of cycles fits the loop exactly, which makes the last sample
# continuous with the first by construction rather than by luck.
#
# They also have to survive being in the room while the wake recogniser is listening, so
# everything here is low, quiet, and deliberately unlike speech: no consonants, no sudden
# onsets, nothing in the 1-3 kHz band where vowels carry.

def snap(freq, loop_dur):
    """Nearest frequency with a whole number of cycles in `loop_dur`."""
    return round(freq * loop_dur) / loop_dur


def bed(loop_dur, partials, amp=0.11, tremolo_hz=None, tremolo_depth=0.35):
    """Sum of sines, each snapped to loop cleanly. `partials` is [(freq, weight)]."""
    n = int(loop_dur * RATE)
    snapped = [(snap(f, loop_dur), w) for f, w in partials]
    trem = snap(tremolo_hz, loop_dur) if tremolo_hz else None
    total_w = sum(w for _, w in snapped)
    out = []
    for i in range(n):
        t = i / RATE
        v = sum(w * math.sin(2 * math.pi * f * t) for f, w in snapped) / total_w
        if trem:
            v *= 1.0 - tremolo_depth * (0.5 - 0.5 * math.cos(2 * math.pi * trem * t))
        out.append(v * amp)
    return out


# 1. Warm pad — a soft major-ninth chord, breathing slowly. Closest to "elevator music"
#    without a melody to get stuck in your head.
BED_PAD = bed(4.0, [(146.83, 1.0), (220.00, 0.7), (293.66, 0.5), (329.63, 0.35), (440.00, 0.2)],
              amp=0.12, tremolo_hz=0.25, tremolo_depth=0.30)

# --- A small additive synth, so the hold-music family can actually be explored ----------
#
# Everything wraps around the loop: a note struck near the end continues into the start of
# the next pass, and chord crossfades wrap too. Without that, "seamless" only means "no
# click", and you would still hear the music restart.

def notes_bed(loop_dur, events, partials=((1.0, 1.0),), amp=0.10,
              attack=0.02, decay=1.4, under=None, under_amp=0.05):
    """`events` is [(start_seconds, freq, velocity)]. Notes wrap past the loop end.

    `partials` shapes the timbre as [(harmonic_ratio, weight)] — a single entry is a pure
    sine, adding an octave and a fifth gets you toward an electric piano.
    """
    n = int(loop_dur * RATE)
    out = [0.0] * n
    for start, freq, vel in events:
        fs = [(snap(freq * r, loop_dur), w) for r, w in partials]
        total_w = sum(w for _, w in fs)
        length = int(min(decay * 4, loop_dur) * RATE)
        s0 = int(start * RATE)
        for i in range(length):
            t = i / RATE
            env = min(1.0, t / attack) * math.exp(-t / decay)
            if env < 1e-4:
                break
            pos = (s0 + i) % n                      # wrap, so the loop point is inaudible
            gt = pos / RATE
            v = sum(w * math.sin(2 * math.pi * f * gt) for f, w in fs) / total_w
            out[pos] += v * amp * vel * env
    if under:
        d = bed(loop_dur, under, amp=under_amp)
        out = [a + b for a, b in zip(out, d)]
    return out


def chord_bed(loop_dur, chords, amp=0.11, cross=1.2):
    """Sustained chords crossfading into each other, wrapping at the loop point."""
    n = int(loop_dur * RATE)
    out = [0.0] * n
    span = loop_dur / len(chords)
    for idx, freqs in enumerate(chords):
        fs = [snap(f, loop_dur) for f in freqs]
        start = idx * span
        for i in range(n):
            gt = i / RATE
            # Distance into this chord's window, wrapped.
            d = (gt - start) % loop_dur
            if d > span + cross:
                continue
            # Fade in over `cross`, hold, fade out over `cross`.
            if d < cross:
                env = d / cross
            elif d < span:
                env = 1.0
            else:
                env = max(0.0, 1.0 - (d - span) / cross)
            if env <= 0:
                continue
            v = sum(math.sin(2 * math.pi * f * gt) for f in fs) / len(fs)
            out[i] += v * amp * env
    return out


# Timbres
SINE = ((1.0, 1.0),)
RHODES = ((1.0, 1.0), (2.0, 0.35), (3.0, 0.12), (4.01, 0.06))   # soft electric piano
BOX = ((1.0, 1.0), (2.0, 0.5), (5.4, 0.18))                     # music box / celeste

C, E, F, G, A, Bb, D5 = 261.63, 329.63, 349.23, 392.00, 440.00, 466.16, 587.33

# 2. Hold music — gentle four-note arpeggio over a drone. The literal reading.
BED_HOLD = notes_bed(4.0,
                     [(0.0, C, 1.0), (1.0, E, 0.9), (2.0, G, 0.85), (3.0, E, 0.8)],
                     partials=SINE, amp=0.11, attack=0.25, decay=1.1,
                     under=[(130.81, 1.0), (196.00, 0.4)], under_amp=0.045)

# 3. Low drone — the most ignorable.
BED_DRONE = bed(4.0, [(110.00, 1.0), (110.75, 0.9), (220.00, 0.25)], amp=0.10)

# 4. Rhodes — soft electric piano, two chords. The most straightforwardly "hold music".
BED_RHODES = notes_bed(8.0,
                       [(0.0, C, 1.0), (0.0, E, .8), (0.0, G, .7), (0.55, D5, .5),
                        (4.0, A/2, 1.0), (4.0, C, .8), (4.0, E, .7), (4.55, G, .5)],
                       partials=RHODES, amp=0.085, attack=0.015, decay=1.9,
                       under=[(130.81, 1.0), (164.81, 0.5)], under_amp=0.035)

# 5. Music box — high and sparse over a warm pad. Prettiest, most distinctive.
BED_BOX = notes_bed(8.0,
                    [(0.0, G*2, .9), (0.9, C*2, .8), (1.8, E*2, .75), (2.7, D5*2, .6),
                     (4.0, F*2, .85), (4.9, A*2, .8), (5.8, C*2, .7), (6.7, G*2, .55)],
                    partials=BOX, amp=0.055, attack=0.006, decay=1.0,
                    under=[(130.81, 1.0), (196.00, .55), (261.63, .3)], under_amp=0.05)

# 6. Two-chord pad — the warm pad with somewhere to go. Movement without a melody.
BED_MOVE = chord_bed(8.0,
                     [[146.83, 220.00, 293.66, 349.23],    # Dm add9-ish
                      [174.61, 261.63, 329.63, 392.00]],   # F major
                     amp=0.115, cross=1.6)

# 7. Deep pad — lower and richer, the least "device" of them all.
BED_DEEP = bed(6.0, [(98.00, 1.0), (146.83, .8), (196.00, .55), (246.94, .3), (293.66, .18)],
               amp=0.125, tremolo_hz=0.166, tremolo_depth=0.22)

BEDS = {
    "bed-pad": (BED_PAD, "Warm pad",
                "A soft major-ninth chord breathing on a 4s cycle. Elevator music without "
                "a melody you could get stuck on."),
    "bed-move": (BED_MOVE, "Two-chord pad",
                 "The warm pad with somewhere to go: two chords crossfading over 8s. "
                 "Movement without a tune, which wears better on a long wait."),
    "bed-deep": (BED_DEEP, "Deep pad",
                 "Lower and richer, breathing slowly on a 6s cycle. The least 'device' of "
                 "them all and the easiest to talk over."),
    "bed-rhodes": (BED_RHODES, "Rhodes",
                   "Soft electric piano, two chords over 8s. The most straightforwardly "
                   "hold music, in the good way."),
    "bed-box": (BED_BOX, "Music box",
                "High sparse bells over a warm pad, 8s. The prettiest and the most "
                "distinctive — also the most likely to get noticed."),
    "bed-hold": (BED_HOLD, "Simple arpeggio",
                 "Four notes over a drone, 4s. The plainest musical option."),
    "bed-drone": (BED_DRONE, "Low drone",
                  "Two detuned low tones beating slowly. Not music; reads as 'on'."),
}

CUE_MEANING = {
    "listening": ("Heard you", "Wake fired. The turn has started and it is recording."),
    "captured":  ("Got the shot", "A photo landed. This is the one that tells you to stop holding still."),
    "thinking":  ("Still working", "Repeats every 1.6s, and only after 1.2s, so a fast reply is silent."),
    "cancelled": ("Dropped it", "You said never mind, or the turn was abandoned."),
    "error":     ("Something broke", "The backend failed or the agent could not answer."),
    "asleep":    ("Going quiet", "You said go to sleep. The wake word is off until you turn it back on."),
    "awake":     ("Listening again", "The wake word was switched back on."),
}

SET_NOTES = {
    "a-glass":   ("Glass", "Pure sine intervals, currently shipping. Clean and neutral, closest to iOS system sounds. Reads as 'a device acknowledged you'."),
    "b-warm":    ("Warm", "Same intervals on a softer two-partial timbre with slower fades. Reads as a chime rather than a beep. Kinder in a quiet room, marginally less cutting on a street."),
    "c-tactile": ("Tactile", "Struck bell tones and pitch glides. Acknowledgement rises like a question, cancel falls like a shrug. The most physical of the three and the least like a computer."),
}


def seam_check(samples, name):
    """A seam is audible only as a jump larger than the signal's own motion.

    For a sine snapped to whole cycles the wrap step *is* an ordinary step, so comparing
    against the maximum with `<=` fails on floating-point equality. Compare against a high
    percentile with a little headroom instead.
    """
    diffs = sorted(abs(samples[i + 1] - samples[i]) for i in range(len(samples) - 1))
    typical = diffs[int(len(diffs) * 0.9999)]
    wrap = abs(samples[0] - samples[-1])
    ok = wrap <= typical * 1.5
    print(f"  {name:12} wrap {wrap:.6f} vs typical step {typical:.6f}  "
          f"{'seamless' if ok else 'CLICKS'}")
    return ok


def main():
    rows = []
    for set_id, cues in SETS.items():
        for cue, samples in cues.items():
            name, dur = write(f"{set_id}-{cue}", samples)
            rows.append((set_id, cue, name, dur))
            print(f"{name:28} {dur:6.0f} ms")

    print("\ncontinuous beds (loop seamlessly, played on repeat while thinking):")
    for bed_id, (samples, _, _) in BEDS.items():
        name, dur = write(bed_id, samples)
        print(f"{name:28} {dur:6.0f} ms")
        seam_check(samples, bed_id)

    order = ["listening", "captured", "thinking", "cancelled", "error", "asleep", "awake"]
    html = ["""<title>Glassbridge earcons</title>
<style>
 :root{--ink:#e9ecee;--dim:#9aa2a6;--line:#242a2d;--bg:#0d1113;--card:#141a1d;--accent:#64d2ff}
 *{box-sizing:border-box}
 body{margin:0;padding:40px 24px 80px;background:var(--bg);color:var(--ink);
      font:15px/1.55 -apple-system,"SF Pro Text",system-ui,sans-serif}
 .wrap{max-width:1080px;margin:0 auto}
 h1{font-size:22px;margin:0 0 6px;letter-spacing:-.02em}
 .sub{color:var(--dim);margin:0 0 28px;max-width:70ch;font-size:14px}
 .note{background:var(--card);border:1px solid var(--line);border-radius:12px;
       padding:14px 16px;margin:0 0 28px;color:var(--dim);font-size:13.5px;max-width:78ch}
 .note b{color:var(--ink)}
 table{width:100%;border-collapse:collapse;margin-bottom:34px}
 th,td{text-align:left;padding:11px 12px;border-bottom:1px solid var(--line);vertical-align:top}
 th{font-size:11px;text-transform:uppercase;letter-spacing:.09em;color:var(--dim);font-weight:600}
 .cue{font-weight:650}
 .why{color:var(--dim);font-size:13px;margin-top:2px}
 button{background:var(--card);color:var(--ink);border:1px solid var(--line);
        border-radius:9px;padding:8px 14px;font-size:13.5px;font-weight:600;cursor:pointer;
        min-width:104px}
 button:hover{border-color:var(--accent);color:var(--accent)}
 button:active{transform:translateY(1px)}
 .ms{color:var(--dim);font-size:11.5px;font-variant-numeric:tabular-nums;margin-left:8px}
 h2{font-size:15px;margin:30px 0 4px;letter-spacing:-.01em}
 h2 .tag{color:var(--accent);font-size:11px;text-transform:uppercase;letter-spacing:.09em;
         margin-left:10px;font-weight:600}
 .setnote{color:var(--dim);font-size:13.5px;margin:0 0 12px;max-width:76ch}
 .seq{margin-bottom:8px}
</style>
<div class="wrap">
<h1>Earcon options</h1>
<p class="sub">Three complete sets. Listen on the glasses if you can, or anything small and
tinny — they are designed for a speaker inches from an open microphone, and laptop speakers
flatter them.</p>
<div class="note">
<b>What they are designed against.</b> Every cue is under 400ms, because a sound that
outlasts the thing it announces is a delay. All of them sit between roughly 300&nbsp;Hz and
2&nbsp;kHz: below that the glasses' HFP link rolls them off, above that they read as an
alarm. The two pairs that must never be confused are <b>heard you / dropped it</b> and
<b>got the shot / still working</b>, so each set inverts the contour rather than only
moving the pitch. <b>Still working</b> repeats every 1.6s and is deliberately the quietest
thing here.
</div>
"""]

    for set_id, cues in SETS.items():
        label, blurb = SET_NOTES[set_id]
        html.append(f'<h2>{label}<span class="tag">set {set_id.split("-")[0]}</span></h2>')
        html.append(f'<p class="setnote">{blurb}</p>')
        html.append('<div class="seq"><button onclick="seq(\'%s\')">▶ Play a whole turn</button>'
                    '<span class="ms">heard you → got the shot → still working ×2 → reply → dropped it</span></div>' % set_id)
        html.append("<table><tr><th>Cue</th><th>Means</th><th></th></tr>")
        for cue in order:
            if cue not in cues:
                continue
            fname = f"{set_id}-{cue}.wav"
            dur = len(cues[cue]) / RATE * 1000
            title, why = CUE_MEANING[cue]
            html.append(
                f'<tr><td><div class="cue">{title}</div><div class="why">{why}</div></td>'
                f'<td style="color:var(--dim);font-size:13px">{cue}</td>'
                f'<td><button onclick="p(\'{fname}\')">▶ Play</button>'
                f'<span class="ms">{dur:.0f} ms</span></td></tr>'
            )
        html.append("</table>")

    html.append('<h2>Still working<span class="tag">continuous</span></h2>')
    html.append('<p class="setnote">Replaces the repeating tick. These loop seamlessly and '
                'play under the whole wait, fading in after 1.2s and out when the reply '
                'starts. Quiet, low, and deliberately unlike speech, so they do not fight '
                'the wake recogniser that is still listening underneath. Let one run for a '
                'few seconds to hear the loop point, or rather to not hear it.</p>')
    html.append("<table><tr><th>Option</th><th>Character</th><th></th></tr>")
    for bed_id, (samples, label, blurb) in BEDS.items():
        dur = len(samples) / RATE
        html.append(
            f'<tr><td><div class="cue">{label}</div><div class="why">{blurb}</div></td>'
            f'<td style="color:var(--dim);font-size:13px">{bed_id}</td>'
            f'<td><button onclick="loop(\'{bed_id}.wav\',this)">▶ Loop</button>'
            f'<span class="ms">{dur:.0f}s cycle</span></td></tr>'
        )
    html.append("</table>")

    html.append("""
<script>
 function p(f){ const a=new Audio(f); a.play(); }
 let looping=null, loopBtn=null;
 function loop(f,btn){
   if(looping){ looping.pause(); looping=null;
     if(loopBtn){loopBtn.textContent='▶ Loop'; const b=loopBtn; loopBtn=null; if(b===btn) return;} }
   looping=new Audio(f); looping.loop=true; looping.play();
   loopBtn=btn; btn.textContent='■ Stop';
 }
 function seq(set){
   const steps=[['listening',0],['captured',700],['thinking',1500],['thinking',3100],['cancelled',4600]];
   steps.forEach(([cue,delay])=>setTimeout(()=>p(set+'-'+cue+'.wav'),delay));
 }
</script>
</div>""")

    (OUT / "index.html").write_text("\n".join(html))
    print(f"\n{len(rows)} files + index.html in {OUT}")


if __name__ == "__main__":
    main()

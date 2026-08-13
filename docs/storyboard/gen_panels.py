import base64, json, os, urllib.request
from concurrent.futures import ThreadPoolExecutor

secrets = {}
with open(os.path.expanduser("~/.claude/secrets")) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            secrets[k] = v.strip('"')
KEY = secrets["OPENAI_API_KEY"]

OUT = os.path.dirname(os.path.abspath(__file__))

STYLE = (
    "Cinematic storyboard panel, consistent illustrated style across a series: "
    "desaturated blue-slate environment, single warm amber key light, "
    "clean geometric shapes with soft film grain, limited palette, calm and modern, "
    "shallow depth of field. Absolutely no text, no words, no letters, no captions, "
    "no numbers, no user interface overlays, no logos."
)

PANELS = [
    ("01-aisle",
     "Wide shot from behind and slightly above: a person in a casual jacket stands in a dim "
     "hardware store aisle wearing dark rounded smart glasses, holding a single small metal bolt "
     "up toward the light to inspect it. Rows of small parts bins fill the walls on both sides."),
    ("02-pov",
     "Extreme close first-person point of view: a hand holds a small hex bolt in sharp focus in "
     "the center foreground, thread detail visible. Behind it, rows of identical parts bins fall "
     "away into soft blur. The framing feels like looking through eyewear."),
    ("03-tap",
     "Tight profile close-up: a fingertip presses the temple arm of dark smart glasses on a "
     "person's head. A small warm amber point of light sits at the hinge. Background is a soft "
     "blur of store shelving."),
    ("04-relay",
     "Quiet conceptual wide shot: a thin warm amber thread of light travels from a pair of smart "
     "glasses, down to a phone in a jacket pocket, then far across the frame to a laptop glowing "
     "on a desk in a distant room. Three points connected by one continuous line of light."),
    ("05-listen",
     "Close-up three-quarter portrait: a person wearing dark smart glasses tilts their head "
     "slightly, listening, eyes focused on something off frame. A soft amber glow sits near the "
     "temple of the glasses. Their expression is the small moment of understanding something."),
    ("06-pick",
     "Medium shot: the same person reaches confidently into one specific parts bin. Every "
     "surrounding bin sits in cool blue shadow while the chosen bin alone is lit in warm amber. "
     "Their posture is decisive, already turning to leave."),
]


def gen(item):
    name, scene = item
    body = json.dumps({
        "model": "gpt-image-1",
        "prompt": f"{scene}\n\n{STYLE}",
        "n": 1,
        "size": "1536x1024",
        "quality": "high",
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/images/generations",
        data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        return f"{name}: HTTP {e.code} {e.read()[:400].decode(errors='replace')}"
    except Exception as e:
        return f"{name}: {type(e).__name__} {e}"

    d = resp["data"][0]
    path = os.path.join(OUT, f"panel-{name}.png")
    if "b64_json" in d:
        with open(path, "wb") as f:
            f.write(base64.b64decode(d["b64_json"]))
    else:
        urllib.request.urlretrieve(d["url"], path)
    return f"{name}: saved {os.path.getsize(path) // 1024}KB"


with ThreadPoolExecutor(max_workers=6) as ex:
    for line in ex.map(gen, PANELS):
        print(line, flush=True)
print("ALL DONE", flush=True)

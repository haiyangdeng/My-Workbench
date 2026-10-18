#!/usr/bin/python3 -I
"""Installs dark-mode artwork into Assets.xcassets as StudioHeroDark, StudioVideoDark, StudioAudioDark,
StudioCodeDark and StudioDesignDark. Reads hero/video/audio/code/design (.png, .jpg, .jpeg or .webp) from
docs/design/dark-theme/artwork, or from the folder given as the first argument, converts them to PNG with
sips, and checks sizes. Missing files are skipped; the app then keeps its drawn stand-in for that slot."""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "docs/design/dark-theme/artwork")
SLOTS = {"hero": ("StudioHeroDark", 1600, 600), "video": ("StudioVideoDark", 900, 700), "audio": ("StudioAudioDark", 900, 700),
         "code": ("StudioCodeDark", 900, 700), "design": ("StudioDesignDark", 900, 700)}


def size(path):
    out = subprocess.run(["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True).stdout
    values = [int(line.split()[-1]) for line in out.splitlines() if "pixel" in line]
    return tuple(values) if len(values) == 2 else (0, 0)


installed, problems = [], []
for key, (asset, min_width, min_height) in SLOTS.items():
    source = next((os.path.join(SOURCE, key + ext) for ext in (".png", ".jpg", ".jpeg", ".webp", ".PNG", ".JPG") if os.path.exists(os.path.join(SOURCE, key + ext))), None)
    if not source:
        continue
    width, height = size(source)
    if width < min_width or height < min_height:
        problems.append(f"{key}: {width}x{height} is smaller than {min_width}x{min_height}")
        continue
    folder = os.path.join(ROOT, "Assets.xcassets", asset + ".imageset")
    os.makedirs(folder, exist_ok=True)
    target = os.path.join(folder, "image.png")
    result = subprocess.run(["/usr/bin/sips", "-s", "format", "png", source, "--out", target], capture_output=True, text=True)
    if result.returncode != 0:
        problems.append(f"{key}: conversion failed: {result.stderr.strip()}")
        continue
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "image.png", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, f, indent=2)
    installed.append(f"{key} -> {asset} ({width}x{height})")

for line in installed:
    print("installed", line)
for line in problems:
    print("skipped", line)
if not installed and not problems:
    print("No artwork found in", SOURCE, "- expected hero/video/audio/code/design .png/.jpg/.webp")
sys.exit(1 if problems else 0)

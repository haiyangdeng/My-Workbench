#!/usr/bin/python3 -I
"""Installs a dark style's artwork into Assets.xcassets.

  python3 -I scripts/install_dark_artwork.py                     # ink:   docs/design/dark-theme/artwork  -> Studio…Dark
  python3 -I scripts/install_dark_artwork.py --style pixel       # pixel: docs/design/pixel-theme/artwork -> Studio…Pixel
  python3 -I scripts/install_dark_artwork.py --trim 8 [folder]   # cut 8 px from every edge first (screenshot frames)

Reads hero/video/audio/code/design (.png, .jpg, .jpeg or .webp) from the style's folder, or from the folder given,
converts them to PNG with sips and checks sizes. Missing files are skipped; the app then falls back for that slot."""
import argparse, json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STYLES = {"ink": ("Dark", "docs/design/dark-theme/artwork"), "pixel": ("Pixel", "docs/design/pixel-theme/artwork")}
SLOTS = {"hero": ("StudioHero", 1600, 600), "video": ("StudioVideo", 900, 700), "audio": ("StudioAudio", 900, 700),
         "code": ("StudioCode", 900, 700), "design": ("StudioDesign", 900, 700)}

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("folder", nargs="?", help="folder with hero/video/audio/code/design images")
parser.add_argument("--style", choices=sorted(STYLES), default="ink")
parser.add_argument("--trim", type=int, default=0, help="pixels to cut from every edge before installing")
args = parser.parse_args()
suffix, default_folder = STYLES[args.style]
SOURCE = args.folder or os.path.join(ROOT, default_folder)


def size(path):
    out = subprocess.run(["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True).stdout
    values = [int(line.split()[-1]) for line in out.splitlines() if line.strip().startswith(("pixelWidth:", "pixelHeight:"))]
    return tuple(values) if len(values) == 2 else (0, 0)


installed, problems = [], []
for key, (base, min_width, min_height) in SLOTS.items():
    asset = base + suffix
    source = next((os.path.join(SOURCE, key + ext) for ext in (".png", ".jpg", ".jpeg", ".webp", ".PNG", ".JPG") if os.path.exists(os.path.join(SOURCE, key + ext))), None)
    if not source:
        continue
    width, height = size(source)
    width, height = width - 2 * args.trim, height - 2 * args.trim
    if width < min_width or height < min_height:
        problems.append(f"{key}: {width}x{height} is smaller than {min_width}x{min_height}")
        continue
    folder = os.path.join(ROOT, "Assets.xcassets", asset + ".imageset")
    os.makedirs(folder, exist_ok=True)
    target = os.path.join(folder, "image.png")
    result = subprocess.run(["/usr/bin/sips", "-s", "format", "png", source, "--out", target], capture_output=True, text=True)
    if result.returncode == 0 and args.trim:
        # sips crops around the center, so this removes the same amount from every edge.
        result = subprocess.run(["/usr/bin/sips", "-c", str(height), str(width), target], capture_output=True, text=True)
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

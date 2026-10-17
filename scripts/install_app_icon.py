"""Export an approved square master to Apple's required AppIcon bitmap sizes."""
from pathlib import Path
import json
import subprocess
root = Path(__file__).resolve().parents[1]
master = root / 'docs/design/icon-v04/master.png'
folder = root / 'Assets.xcassets/AppIcon.appiconset'
contents = json.loads((folder / 'Contents.json').read_text())
for item in contents['images']:
    edge = int(item['size'].split('x')[0]) * int(item['scale'][0])
    subprocess.run(['/usr/bin/sips', '-z', str(edge), str(edge), str(master), '--out', str(folder / item['filename'])], check=True, stdout=subprocess.DEVNULL)
print('Exported all 10 macOS AppIcon sizes, preserving alpha.')

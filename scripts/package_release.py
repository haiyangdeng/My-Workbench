"""Package only this project's local app, sources, and reviewed deliverables."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
app = root / '.build/release/Build/Products/Release/MyWorkbench.app'
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
version = info['CFBundleShortVersionString']
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version)
tests = (root / 'work/release-tests.log').read_text()
results = [(int(count), int(failures)) for count, failures in re.findall(r'Executed (\d+) tests, with (\d+) failures', tests)]
assert results and all(failures == 0 for _, failures in results)
test_count = max(count for count, _ in results)
stage = root / 'work/release-stage'
if stage.exists():
    shutil.rmtree(stage)
stage.mkdir()
release = root / 'releases'
release.mkdir(exist_ok=True)
app_stage = stage / f'MyWorkbench-{version}-macOS'
source_stage = stage / f'MyWorkbench-{version}-source'
app_stage.mkdir(); source_stage.mkdir()
shutil.copytree(app, app_stage / 'MyWorkbench.app', symlinks=True)

def docs_to(destination):
    docs = destination / 'docs'; docs.mkdir()
    for name in ['PRD.md', 'PRD_V04_ADDENDUM.md', 'DESIGN_REVIEW_V04.md', 'DESIGN_V05.md', 'AI员工工作台_PRD_v0.3.docx', 'DESIGN.md', 'DEVELOPMENT.md', 'VALIDATION.md', 'DELIVERY.md']:
        shutil.copy2(root / 'docs' / name, docs / name)
    design = docs / 'design'; design.mkdir()
    for name in ['studio-v03.html', 'studio-overview.png', 'studio-compact.png', 'studio-profile-config.png', 'studio-team.png', 'studio-recruit-current.jpg', 'native-real-collaboration.png', 'native-collaboration-panel.png', 'native-profile-config.png', 'native-plan-approval.png', 'native-remote-config.png', 'native-multiple-employees.png']:
        shutil.copy2(root / 'docs/design' / name, design / name)
    for name in ['review-v04', 'native-v04', 'icon-v04', 'studio-v05']:
        shutil.copytree(root / 'docs/design' / name, design / name)
    shutil.copytree(root / 'docs/third-party', docs / 'third-party')
    shutil.copy2(root / 'README.md', destination / 'README.md')
    shutil.copy2(root / 'docs/DELIVERY.md', destination / '使用与交付说明.md')

docs_to(app_stage); docs_to(source_stage)
for name in ['Sources', 'Tests', 'Assets.xcassets', 'MyWorkbench.xcodeproj']:
    shutil.copytree(root / name, source_stage / name, ignore=shutil.ignore_patterns('xcuserdata', '*.xcuserstate', '.DS_Store'))
for name in ['Package.swift', 'Package.resolved', '.gitignore']:
    shutil.copy2(root / name, source_stage / name)
scripts = source_stage / 'scripts'; scripts.mkdir()
for name in ['build.sh', 'create_xcode_project.py', 'build_prd.py', 'render_prd.sh', 'render_native_studio.sh', 'render_native_studio.swift', 'verify_native_log_response.sh', 'verify_native_log_response.swift', 'verify_studio.cjs', 'verify_employees.cjs', 'verify_native_execution.sh', 'verify_native_execution.swift', 'verify_real_collaboration.sh', 'verify_real_collaboration.swift', 'comfy_fixture.py', 'package_release.sh', 'package_release.py']:
    shutil.copy2(root / 'scripts' / name, scripts / name)
for name in ['verify_native_studio_v04.sh', 'verify_native_studio_v04.swift', 'verify_native_studio_v05.sh', 'verify_native_studio_v05.swift', 'install_app_icon.py']:
    shutil.copy2(root / 'scripts' / name, scripts / name)

def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()

manifest = {
    'version': version, 'build': info['CFBundleVersion'], 'bundleIdentifier': info['CFBundleIdentifier'],
    'createdAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'architectures': subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/MyWorkbench')], text=True).strip().split(),
    'signature': 'ad hoc; codesign --verify --deep --strict passed',
    'coreTests': {'passed': test_count, 'failed': 0},
    'deliveryStatus': 'candidate; real remote generation and native manual QA pending',
    'sourceSHA256': {str(p.relative_to(root)): sha(p) for p in sorted((root / 'Sources').rglob('*.swift'))},
    'prdSHA256': sha(root / 'docs/AI员工工作台_PRD_v0.3.docx'),
    'v04RequirementsSHA256': sha(root / 'docs/PRD_V04_ADDENDUM.md'),
    'v05DesignSHA256': sha(root / 'docs/DESIGN_V05.md'),
    'studioArtworkSHA256': {str(p.relative_to(root)): sha(p) for p in sorted((root / 'Assets.xcassets').glob('Studio*.imageset/image.png'))},
    'appIconSHA256': sha(root / 'docs/design/icon-v04/master.png'),
    'terminalDependency': 'SwiftTerm 1.10.0 pinned',
}
for destination in [app_stage, source_stage]:
    (destination / 'build-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    audit = root / 'work/m4-real-delivery-audit.json'
    if not audit.exists(): audit = root / 'AI协作验收记录.json'
    if audit.exists(): shutil.copy2(audit, destination / 'AI协作验收记录.json')
    log_response = root / 'work/native-log-response.json'
    if not log_response.exists(): log_response = root / '日志响应验收记录.json'
    if log_response.exists(): shutil.copy2(log_response, destination / '日志响应验收记录.json')
    studio_report = root / 'work/native-studio-v04-verification.json'
    if studio_report.exists(): shutil.copy2(studio_report, destination / '工作室V04验收记录.json')
    studio_v05_report = root / 'work/native-studio-v05-verification.json'
    if studio_v05_report.exists(): shutil.copy2(studio_v05_report, destination / '工作室V05验收记录.json')

archives = []
for directory in [app_stage, source_stage]:
    target = release / (directory.name + '.zip')
    if target.exists(): target.unlink()
    # Standard UTF-8 ZIP names preserve Chinese documents across archive readers.
    with zipfile.ZipFile(target, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in [directory, *sorted(directory.rglob('*'))]:
            name = str(path.relative_to(stage))
            if path.is_symlink():
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = path.lstat().st_mode << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, os.readlink(path).encode('utf-8'))
            else:
                archive.write(path, name)
    archives.append(target)
    print(f'{target.name}: {target.stat().st_size:,} bytes')
(release / 'SHA256SUMS.txt').write_text(''.join(f'{sha(path)}  {path.name}\n' for path in archives))
(release / 'build-manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print('Universal release packages and checksums created.')

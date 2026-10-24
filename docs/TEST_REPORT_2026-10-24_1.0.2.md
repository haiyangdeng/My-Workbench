# Workbench 1.0.2: review fixes and verification

Date: 2026-10-24. Baseline: `2139a36`, Workbench 1.0.1 (build 10). Release: **1.0.2 (build 11)**.

A code review of the 1.0.1 changes found 11 issues. All of them are fixed in 1.0.2.

## Fixes

| Finding | Behavior in 1.0.2 | Covered by |
| --- | --- | --- |
| Approving a production plan refused the user's own edits | The approval sheet's template and server pickers only list what the request allowed. If approval still finds a step outside that scope, the error asks the user, not the director, to pick again | `verify_review_fixes`: refusal on response and approval, approval wording, picker scope |
| One failed copy dropped the whole Git baseline | A file that can't be copied keeps its fingerprint. The rest of the baseline, the changed-file list and the review evidence still work | `testGitBaselineKeepsFingerprintOnlyForFilesOverTheCopyLimit` |
| Every Edit run copied all modified and untracked files | Copies are capped at 8 MB per file and 256 MB per run. Files beyond the caps diff against the last commit, with a note that the diff includes earlier edits | Same test, with a file one byte over the limit |
| Workbench overwrote an agent's own `changes.diff` | Workbench saves its record as `output/.workbench/changes.diff` and refuses a symbolic link in place of that folder | `verify_review_fixes`, saved Git evidence |
| Chat change records showed up as assets | The record is left out of the asset library and project asset counts; it still appears in that run's own file list | `testChangeEvidenceIsKeptApartFromDeliverables` |
| The baseline ignored a failed `git diff` | Its output is only used when git exits with 0 | Code review |
| Saved diffs exposed absolute paths | Every header line before the first hunk is rewritten to `a/…` and `b/…`, including `Binary files … differ`. Git prints absolute paths without their leading `/`, which the 1.0.1 rewrite never matched, so 1.0.1 diffs of pre-modified files contained the project and temp folder paths | `testGitDiffSinceBaselineHidesAbsolutePathsInBinaryAndHeaderLines`, plus a header check in the Unicode path test |
| Pixel sidebar icon downscaled with nearest-neighbor | The 1024 px icon is filtered when drawn at 38 pt in every look | `verify_review_fixes`, style icons |
| Artifact lookups walked every archive folder | `url(for:)` checks that the file's real location is inside the run's real output folder, without a per-folder walk | `testArchiveRejectsReplacedOutputAndAncestorDirectories` |
| The homepage Copy button hid its result from screen readers | The button's name comes from its text, and a status region announces "copied" or "selected" | Browser check |
| A folder could be swapped between the archive check and the create | `prepare` checks the folders again after creating them | `testArchiveRejectsReplacedOutputAndAncestorDirectories` |

## Upgrading from 1.0.1

- Chat turns recorded by 1.0.1 have no record at the new path, so their diff view shows the live diff, as for records before 1.0.1.
- `changes.diff` files saved by 1.0.1 stay in the asset library, because they can't be told apart from files an agent wrote.

## Verification

- `swift test`: **120 tests, 0 failures**.
- `zsh scripts/verify_review_fixes.sh`: 7 checks passed, with no model calls and no GPU requests.
- `zsh scripts/verify_m6m7.sh`: 13 checks passed. `zsh scripts/verify_m9.sh`: 10 checks passed. Both use stand-in CLIs.
- Homepage on a local server: the copy button's name, visible label and status messages were checked, and the label resets after 1.8 seconds.

No paid models or GPUs were called, and the user's workspace database was not read or written.

## Installer

`zsh scripts/make_dmg.sh` built the universal Release app. The DMG, mounted read-only, was checked as follows:

- Version **1.0.2**, build **11**, minimum macOS **14.0**.
- The executable contains **x86_64** and **arm64**.
- `codesign --verify --deep --strict` passes; the app is still ad hoc signed.
- `Assets.car` contains `StudioIconPixel`, and the volume has an Applications shortcut.
- The app in the ZIP has the same version and build.
- `hdiutil verify` and the SHA-256 checksums of the DMG and ZIP pass.

The release files are `Workbench-1.0.2.dmg`, `Workbench-1.0.2-macOS.zip` and `Workbench-1.0.2-SHA256SUMS.txt`.

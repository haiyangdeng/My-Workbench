# Workbench full test pass and fixes — 2026-10-24

## Scope

- **Code:** the working tree on top of commit `1a5da6e` (“M9 all”), plus the uncommitted style work.
- **Measured against:** PRD v0.6 and [REVIEW_2026-10-18.md](REVIEW_2026-10-18.md).
- **CLIs:** as agreed, Codex is the only CLI run for real. Claude Code is covered by configuration checks only, and you will connect it yourself. The GPU server is covered with a stand-in `ssh` until your server is online.

**Test machine:** Intel Core i7-9750H (x86_64), macOS 26.6.2, Xcode 26.2, Codex CLI 0.164.0 (signed in), Claude Code 2.1.287 (signed out).

## Verdict

**Feature-complete for v0.6, with every finding from this pass fixed.**

- All automated checks pass:
  - 111 unit tests;
  - M5–M9, CRUD and the new server checks;
  - the older native checks, including two scripts that were broken;
  - the theme renders.
- Codex was run for real: 25 of 26 scenarios pass, plus a Codex-directed image through an SSH server.
- The one remaining Codex item is Codex's own one-time “Trust this folder?” prompt when a session continues in the terminal.

Three things are still open, and none of them can be closed from this Mac alone:

1. A run with your real GPU server.
2. Claude Code signed in, which also covers the cross-CLI half of A45 and A47.
3. A hands-on pass through the UI.

## What the first pass found and what changed

| ID | Problem found | Fix | Proof |
| --- | --- | --- | --- |
| B1 | A budget of 0 or below removed the GPU cap | `BudgetCap`: a cap must be a finite number above 0, and a plan with generate steps needs one. Checked in the approval form, the store and “adjust budget” | Unit test; server check |
| B2 | Running multi-variant jobs reserved only one variant, with no re-check between variants | Running jobs reserve their full variant count. Before each further variant, the remaining room is checked against actual time used; if it doesn't fit, the step stops and the plan pauses | Unit and M8 checks |
| B3 | Codex reconnect errors made a successful test prompt show as failed. Seen in 19 of 21 real runs | Errors before `turn.completed` are kept as “recovered” and logged, but don't fail the turn | Real TL-06 now passes; unit test |
| B4 | The changed-file list missed edits to files the user had already modified | Files that were already changed are compared by content hash before and after the turn | Real CH-11b now passes; unit test |
| B5 | A reviewer could not see the files a step changed in the project, so the Codex reviewer returned “blocked” every time | An Edit step in a git project saves `changes.diff` (file list and diff) with its outputs, and reviewers receive it as evidence | Real A45b: the Codex reviewer passed both steps |
| B6 | Stop left the commands Codex had started still running: Codex puts each command in its own process group | The runner records every process under a CLI and stops them all on Stop, timeout or exit, matching each by PID and start time | Real A41: no leftover `sleep`; 2 new tests |
| B7 | A signed-out CLI failed only after about 2 minutes of Codex retries | Before a turn or step, the login is checked again (at most every 10 minutes, no model call). A signed-out CLI fails at once with the login message | Real A44 |
| B8 | A usage limit showed only as raw CLI text | It now gets its own message, with the CLI's retry time | Unit test |
| B9 | Every real turn took about 2 minutes. An app opened from Finder doesn't get your shell's `HTTPS_PROXY`, so Codex's WebSocket timed out before falling back to HTTPS | CLIs now receive the macOS system proxy, unless the app already has proxy variables or the CLI turns this off | Real turns: 128 s → **22 s** on average; reconnects in 0 of 22 runs (19 of 21 before) |
| G1 | MD-16: the director always got every template and every enabled server | A scope menu next to the director switch. The default is the project modules' templates and the servers whose last check passed. The scope is saved with the message and limits both the schema and the prompt | Build and checks |
| G2 | MD-02: server health was not refreshed while jobs ran | Refreshed every 30 s while jobs run, without re-reading the node list | Server check |
| G3 | CH-13: ⌘K search had no categories or filters | Category results, plus category and module filters for projects, conversations, employees and tasks | Build |
| T1 | Two V04-era scripts no longer compiled | They now include every app source, as the newer scripts do | Both pass |

## Added in this pass

**CLI configuration coverage (Claude Code ready for you to connect).**

- Each CLI definition can now carry:
  - environment variables, saved with the definition and exported;
  - secret variables, kept in the Keychain and never exported;
  - a system-proxy switch.

  This covers setups such as `ANTHROPIC_BASE_URL` with `ANTHROPIC_AUTH_TOKEN`. Run logs list the added variable names, never their values.
- The Appendix A values for Claude Code and Codex are in [docs/cli-examples](cli-examples/README.md) as importable files. The app still ships none of them. A unit test pins the exact argv each file produces in every mode.
- `python3 -I scripts/verify_cli_flags.py` found every flag and option value in the installed `claude` 2.1.287 and `codex` 0.164.0 help, without calling a model.
- Claude Code's own flows (stream-json, resume, plan and acceptEdits, JSON schema, permission denials, review) keep passing in M5–M7 with the stand-in CLI.

**On-demand GPU servers ([guide](GPU_SERVERS.md)).**

- **SSH login:** host alias or address, user, port, key file or a password kept in the Keychain (passed only through `SSH_ASKPASS`), a host-key policy (“trust a new host”, still refusing a changed key), and the ComfyUI address seen from the host.
- **Lifecycle:**
  - start and stop commands, plus a wait until the server is ready;
  - a staged connection test;
  - the tunnel opens on its own before a job;
  - a job on a stopped server is not submitted;
  - a tunnel that drops mid-job reopens while polling continues;
  - ssh errors are explained in plain language.
- `zsh scripts/verify_servers.sh` covers all of this with a stand-in `ssh` (`scripts/fixtures/ssh_like.py`). With `--real-codex`, Codex directed one image through the SSH server: it planned, the tunnel opened on its own, the image ran, and Codex reviewed it, in 62 s.

## Results

### Automated

| Check | Result |
| --- | --- |
| Unit tests (`swift test`) | ✅ 111 (94 before; new: reliability, process tree, server config, CLI examples) |
| Debug build; universal Release build, signature, x86_64 + arm64 | ✅ |
| Theme renders | ✅ 16 |
| M5 15 · M6/M7 13 · M8 9 · M9 10 · CRUD 10 checks | ✅ |
| Server checks (`verify_servers.sh`) | ✅ 8 checks (9 with `--real-codex`) |
| Older native checks (execution, log response, studio v04/v05, studio render) | ✅ |
| CLI flag audit (`verify_cli_flags.py`) | ✅ Claude Code and Codex |

### Real Codex (`scripts/verify_real_codex.sh`), final run

25 of 26 passed in 8 minutes. The first run took 37 minutes before the proxy fix.

| Area | Cases |
| --- | --- |
| Setup | ✅ A34 name → path under Finder's PATH · TL-05 version · A35 login · TL-06 test prompt |
| Chat | ✅ CH-01 reply · A38 activity before exit and log archived · A39 resume · usage recorded · A37 Read-only (no file changed, even when asked to write) and Edit · CH-11 changed files, including an already-modified file |
| Control | ✅ A42 queue · A40 interrupted on restart, resumed after restart · A41 stop (no leftover process) · A44 signed out and missing executable |
| Terminal | ⚠️ A43a: Codex shows its own “Trust this folder?” prompt the first time a folder is opened interactively; the user chooses once · ✅ A43b chat continues afterwards |
| Work | ✅ CH-09 reply → task → accepted · CH-12 parallel, forced Read-only · A45 Codex lead plan, two steps, Codex reviewer **pass** on both, wrap-up |
| Media | ✅ A51 Codex director plan, nothing submitted before approval · A53 Codex opened the generated image and asked for rework with reasons |

Each run's details are in `work/real-codex-qa/<time>/real-codex-report.json`. The first runs (usage limit, then 20 of 26) are kept there too.

## Still open

| Item | Why it is open | What closes it |
| --- | --- | --- |
| A55: real cloud GPU | Your server is started only when needed | One run with the server: test connection, start, one image, video and audio job through the director |
| Claude Code for real; the cross-CLI half of A45 and A47 | You will connect it | After `claude auth login` (or a relay set up through the environment variables): test prompt, then rerun `verify_real_codex.sh` adapted to Claude |
| A43a | Codex asks once per folder whether to trust it | Choose “Trust and continue” once per project folder. Nothing to fix in Workbench |
| Hands-on UI pass | Clicks, keyboard, drag and drop, VoiceOver, menus and sheets, switching styles | A guided click-through with computer use, or by you |
| Apple Silicon | Only this Intel Mac was used | Run the universal build on an M-series Mac |
| MD-04 extras, PJ-09 | P2 items not in v0.6: provider-specific integrations, tags and nested categories | Later, if needed |

No commits were made.

# Workbench — Product Requirements v0.6

Date: 2026-10-17 · Status: approved, revision 2 · App baseline: 0.5.0 (build 6)

Revision 2 (2026-10-17): the app ships no built-in CLI types. The user adds every CLI by hand, and the app prompts the user to add one wherever a CLI is needed but missing. §6.1 was rewritten, and §1, §3, §5, §6.6, §7, §8, §10–§12 and Appendix A were updated to match.

This is now the source of truth for product scope. It replaces the Chinese PRD v0.3 ([PRD.md](PRD.md)) and the [V04 addendum](PRD_V04_ADDENDUM.md) wherever they conflict. Requirements in those documents that this PRD does not change stay in force (see §6.6). The current visual design is described in [DESIGN_V05.md](DESIGN_V05.md). Changes to the UI that this PRD needs will go into a DESIGN_V06 document before the UI work starts.

## 1 Summary

Workbench is a native macOS hub for all of the user's AI tools. It brings the AI CLIs the user adds (for example Claude Code or Codex) and remote generation servers (ComfyUI on cloud GPUs) into one app. Work is organized by four modules (Code, Video, Audio, Design) and by user-defined project categories.

The user works through a chat box. They pick one agent, or select several and let them split the work between them. In the Video, Audio and Design modules, a coding agent acts as the **director**: it turns a brief into concrete ComfyUI jobs, which the workbench runs on the user's cloud servers after the user approves the plan and its budget.

v0.6 moves the product from an "AI employee task board" to an "AI tool hub with chat and teams". The execution engine built in 0.3–0.5 stays underneath: process control, run archive, plans, dependency scheduling, review, the ComfyUI client and the PTY terminal.

## 2 Current state (assessment, 2026-10-17)

The 0.5.0 code is a working engine, not a UI shell. The sources match the 0.5.0 release manifest, and all 46 core tests pass. The gaps below are against the requirements the user gave on 2026-10-17 (R1–R5).

| Requirement | What exists in 0.5.0 | Gap |
| --- | --- | --- |
| R1 Add AI tools flexibly | Three hard-coded adapters (`ToolAdapter`): Generic CLI, Codex, ComfyUI. A generic CLI is an absolute path plus an argv list with `{input}` and `{output}`. The login check is built in for Codex only; other tools need a hand-written status command. | No Claude Code support. A new CLI cannot declare streaming output, session resume, structured output or access levels without code changes. No auto-detection or presets. |
| R2 Code: chat box, pick one agent or a team that splits the work | The bottom "idea" bar pre-fills a one-shot task form. There is one agent per task, and its output appears as a raw log. A planner that only works with Codex splits a goal across *all* enabled agents, with dependencies, review and limited rework (verified with real Codex calls on 2026-10-02). A PTY terminal handles interactive CLI use. | No conversations, no follow-up turns, no session resume, no streaming transcript. The user cannot pick a subset of agents for a team. Planning and review only work with Codex. All plan steps write to the same folder with nothing coordinating the writes. |
| R3 Video: cloud ComfyUI directed by an agent | The ComfyUI client can submit, poll, cancel by ID, and download with size limits. It supports an SSH tunnel and keeps the token in the Keychain. Each tool holds one workflow with a single `{input}` text substitution. A Codex plan step can send text to a ComfyUI agent. | No list of servers, health checks or queue view. One workflow per connection, with no named parameters (seed, size, frames) and no file inputs (no upload). No media previews. The reviewer only reads text, so it can't judge images or video. No budget enforcement. Never run against a real server. |
| R4 Audio and Design work like Video | Same as R3. The modules are just labels with artwork. | Same as R3, plus audio and image previews. |
| R5 Category management across projects | A project has a name, folder and goal; the UI has one "current project" picker. | No categories, no archive status, no overview or filtering across projects. |

Other findings:

- **The app has never done real work on this Mac.** The local database holds only the onboarding demo: a `printf` tool, a test employee and one draft task with no runs.
- **CLIs on this Mac.** Claude Code 2.1.287 is installed at `~/.local/bin/claude` and has every headless feature this PRD needs (Appendix A). Codex is **not** on the PATH (`~/.codex` exists but the binary is missing), so it must be reinstalled before Codex work is tested.
- **Code structure.** `WorkbenchStore.swift` (44 KB) and `WorkbenchView.swift` (71 KB) each hold a whole layer in one file, and the store runs on the main thread. Streaming chat and media work will need separate stores and views. This affects implementation order, not scope.
- **Open QA items** from [VALIDATION.md](VALIDATION.md): hands-on click, keyboard and VoiceOver testing; a run on Apple Silicon; a real ComfyUI generation.

## 3 Goals and non-goals

Goals:

- **G1** Add any AI CLI by hand with one form and no code change. The app ships no built-in CLI types; wherever a CLI is needed but missing, it prompts the user to add one.
- **G2** Do code work from a chat box, with follow-up turns, live output, a stop button, and one or several agents per message.
- **G3** Do video, audio and design work through a director agent. It plans ComfyUI jobs on cloud servers, the user approves the plan and budget, and the workbench runs the jobs and collects the outputs.
- **G4** Find any project, conversation or output across all projects by category and module.
- **G5** Keep the v0.3 safety guarantees: commands are visible, the user approves before files are written or money is spent, and no progress or result is ever faked.

Non-goals for v0.6:

- Creating, starting or stopping cloud GPU instances. The user runs their own servers; P2 allows the user to run their own start/stop commands by hand.
- Generation services other than ComfyUI (for example ElevenLabs or Suno APIs). Planned as a P2 HTTP adapter.
- Web-only AI tools that have no CLI or API.
- Accounts, billing, multi-device sync, team sharing, RAG or knowledge retrieval, local model hosting.
- Public signing, notarization, App Store distribution, platforms other than macOS.
- Changing the UI language. The UI stays Chinese; this PRD uses English terms (see §4).

## 4 Concepts

| Term | Meaning | Current UI label |
| --- | --- | --- |
| Module | One of Code, Video, Audio, Design. The user can add more (V04 rules). Each module defines a way of working. | 工作区 |
| Connection | A configured AI CLI or ComfyUI server. Shared by all projects. | 工具连接 |
| CLI definition | Describes how the workbench drives one CLI: executable, argv templates, output format, sessions, structured output, access level flags, login commands. Always written by the user; the app ships none. | new (part of 工具连接) |
| Agent | A named role bound to one CLI connection: name, avatar, instructions, module(s), maximum access level, default model. Several agents may share a connection. | AI 员工 |
| Server | A ComfyUI server, usually on a cloud GPU and often reached through an SSH tunnel. | new (part of 工具连接) |
| Workflow template | An imported ComfyUI API workflow with named parameters and declared outputs. | new |
| Category | A user-defined group of projects (for example "Client work" or "YouTube series"). Each project has exactly one category. | new |
| Project | A unit of work with a folder, a category and one or more modules. | 项目 |
| Conversation | A chat thread inside a project. | new |
| Turn | One agent's reply to one message. Each turn is a run. | new |
| Session | The CLI's own conversation ID for one agent in one conversation, used to resume that conversation. | new |
| Plan | A list of steps with dependencies. A **team plan** comes from a lead agent; a **production plan** comes from a director. | 协作计划 |
| Run | One execution, with a snapshot of its inputs, a log, output files and a final state (unchanged from v0.3). | 执行 |
| Asset | An archived output file with its full history of how it was made. | 素材 |

## 5 Key flows

**F1 Add Claude Code and fix a bug.** The user types a message, and the composer says no CLI has been added yet, with an "Add CLI" button; the message is kept. In the form the user names the CLI "Claude Code", enters `claude` (resolved to `~/.local/bin/claude`) and fills in the templates, copying them from the example in Appendix A. The version and login checks pass, and the workbench offers to create a "Claude" agent in the Code module. The user opens a project and types "fix the crash in the parser" with Claude selected and access set to Edit. The reply streams in, file edits appear as compact lines, and the turn ends as Replied. A follow-up ("add a test for it") resumes the same session.

**F2 A team splits a feature.** In the same project, the user selects Claude Code and Codex, sets Team mode with Claude as lead, and asks for "add CSV export with tests". Claude returns a plan with four steps across both agents. The user reassigns one step and approves. Steps run in dependency order; only one write step touches the folder at a time. The user accepts each step, or a reviewer agent does.

**F3 Make a short video on a cloud GPU.** In a Video project the user registers a cloud server (SSH alias `gpu-1`) and imports two workflows: text-to-image keyframes and image-to-video. They map each workflow's parameters (prompt, seed, size, reference image, frames). The user then picks a director agent and writes a 20-second brief. The director returns a production plan:

1. Write the shot list (agent step).
2. Generate four keyframes (generate steps).
3. Animate each keyframe (generate steps that depend on step 2).
4. Join the clips with ffmpeg (command step).

The plan card shows the estimated GPU minutes and cost, and the user approves it with a budget cap. The workbench uploads the inputs, runs the jobs, downloads the outputs and shows previews. The director reviews keyframes taken from each clip and asks to redo one shot with a new seed. The redo becomes a new run; the old one is kept.

**F4 Organize projects.** The user creates the categories "Client", "Channel" and "Experiments", and drags projects into them on the All Projects page. They filter Assets by "Channel" to see every output for their channel.

## 6 Requirements

Priorities: **P0** is required for the milestone listed in §10, **P1** should ship in v0.6 after the P0 items, **P2** comes later.

### 6.1 CLI connections (TL)

The app ships no built-in CLI types. Every CLI, Claude Code and Codex included, is added by hand through the same form. Appendix A has example values the user can copy. ComfyUI servers are not CLIs and are added separately (§6.4).

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| TL-01 | P0 | Manual CLI definitions | Connections → Add CLI opens one form for every CLI. Nothing is pre-filled for any particular product. |
| TL-02 | P0 | Prompt when missing | When no CLI has been added, every place that needs one shows "Add CLI" and keeps what the user already typed: the composer, the agent form, the team and director pickers, and Home. When a CLI's executable no longer exists or can't be run, the CLI shows as Missing with "Fix path", and any run that needs it is blocked with the same prompt instead of failing. |
| TL-03 | P0 | Executable | An absolute path picked with "Choose file…" (hidden folders visible) or typed in. Alternatively, a command name such as `claude`, which is resolved once through the user's login shell; the resulting absolute path is what gets saved. |
| TL-04 | P0 | Invocation templates | An argv template for a new turn, plus an optional one for resuming a session, and an optional one for continuing a session interactively in the terminal (used by CH-08). Placeholders: `{prompt}`, `{session_id}`, `{output}`, `{workdir}`, `{model}`, `{instructions}`, `{schema}`, `{schema_file}`. There are optional argv fragments for the model, for structured output, and for each access level. Every placeholder becomes exactly one argv element; there is no shell expansion. If no template uses `{instructions}`, the agent's instructions are put in front of the prompt, unless "Include agent instructions" is off. |
| TL-05 | P0 | Output format | The output can be **Plain text** (all of stdout is the reply), **stream-json events** (the format Claude Code emits) or **JSONL events** (the format Codex emits). The format decides how the reply text, tool activity, session ID and usage are read. The session ID is either assigned by the workbench through `{session_id}`, or read from the output. |
| TL-06 | P0 | Testing a CLI | Optional version and login-status commands (exit 0 means logged in; optional text that means logged out) cost nothing and create no run. The login command runs in the built-in terminal. "Send test prompt" is a separate, explicit action, labeled as using the account's quota. |
| TL-07 | P0 | Access levels | Each agent has a maximum level: **Read-only** or **Edit in project**. A level whose flags the CLI definition leaves empty can't be used with that CLI. If a CLI defines no access flags at all, the workbench does not manage its access and says so on the CLI card. The form shows the full argv for each level and warns when the flags contain a known approval-bypass option (for example `bypassPermissions`, `--dangerously-skip-permissions`, `danger-full-access`, `--yolo`). |
| TL-08 | P1 | Usage display | When the CLI reports cost or tokens, they are stored per run and summed per conversation and per project. |
| TL-09 | P1 | Export and import | A CLI definition can be exported to and imported from JSON, without credentials. |
| TL-10 | P1 | Duplicate | A CLI definition can be copied as the starting point for a new one. |
| TL-11 | P1 | Per-connection limits | Each CLI can have its own concurrency limit, on top of the global limit. |
| TL-12 | P1 | Version drift | When the detected version changes, the CLI is marked "needs re-check" (extends v0.3 F07). |

Agents (AG):

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| AG-01 | P0 | Agent fields | Adds module(s), maximum access level and default model to the existing agent fields (name, avatar, role, instructions, CLI, enabled). |
| AG-02 | P0 | Shared connections | Several agents can use one connection. Each keeps its own sessions and instructions. |
| AG-03 | P0 | Visible prompt | The run detail shows the full prompt sent, including the agent's instructions, plus the argv, folder and added environment variables. |

### 6.2 Chat (CH)

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| CH-01 | P0 | Composer | Available on Home and inside a project. It has a text field, attachments (file paths; nothing is uploaded), an agent picker (chips and `@mention`), a mode switch (Single or Team; Parallel is P1) and an access level for the turn, capped at the agent's maximum. Enter sends and Shift+Enter adds a new line. On Home the composer asks for a project, defaulting to the last one used. The agent picker shows each agent's login status. |
| CH-02 | P0 | Conversations | Each conversation belongs to one project. The title comes from the first message and can be edited. Conversations are listed per project, most recent activity first. |
| CH-03 | P0 | Streaming reply | Single mode runs the selected agent in the project folder. Text appears as it arrives. Tool activity shows as compact lines (file edited, command run, search) that can be expanded. The end of the turn shows its state, duration and usage when known. The raw event log is archived with the run. |
| CH-04 | P0 | Follow-up turns | Each pair of conversation and agent keeps the CLI's own session ID, and follow-ups resume it. If resuming fails, the reason is shown with a "Start new session" option. (P1: the new session starts with a summary of the transcript.) |
| CH-05 | P0 | Queueing | A message sent to an agent that is still working is queued and clearly marked. The user can cancel a queued message. |
| CH-06 | P0 | Stop | Stops the turn's process group, as in v0.3 §4. Partial output is kept and the turn is marked Stopped. |
| CH-07 | P0 | Turn states and errors | Turn states are Queued, Running, Replied, Failed, Stopped, Timed out and Interrupted. Chat turns do not need acceptance; tracked work does (CH-09). Each failure says what to do next: not logged in, executable missing, action denied by the CLI, or non-zero exit (with the exit code). |
| CH-08 | P0 | Open in Terminal | Opens the PTY terminal with the same agent resuming the same session in the project folder, so the user can answer interactive prompts. Back in the chat, the next message continues that session. |
| CH-09 | P0 | Promote | Any reply can become a tracked task with acceptance criteria, and its files can be added to Assets. |
| CH-10 | P0 | Restart | Turns that were running when the app quit become Interrupted. Nothing is sent again automatically. |
| CH-11 | P1 | Changed files | For Edit turns in a git repository, the files changed during the turn are listed, with a diff view. Nothing is reverted automatically. |
| CH-12 | P1 | Parallel mode | Sends the same message to 2–4 agents as separate sessions and shows the results side by side. Edit access in this mode needs worktree isolation (TM-08); without it, the turns are forced to Read-only. |
| CH-13 | P1 | Search | ⌘K also finds conversations and categories, with filters by category, project and module. |

### 6.3 Team mode (TM)

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| TM-01 | P0 | Team selection | The user selects two or more agents and a lead (by default the first one selected). The lead may also do steps. |
| TM-02 | P0 | Any agent can lead or review | Structured output uses the CLI's schema flag when it has one. Otherwise the prompt asks for JSON, and the workbench validates it. Invalid JSON gets one automatic repair attempt, then an error is shown. |
| TM-03 | P0 | Planning input | Planning runs in the lead's existing session in this conversation, so earlier messages are context. The lead receives the user's message, the project goal, and a roster of the **selected agents only** (name, role, instructions, modules, maximum access). It returns 1–20 steps, each with an agent, title, input, acceptance criteria, dependencies and a requested access level no higher than that agent's maximum. The v0.3 validation rules apply: unique IDs, valid agents, no cycles. |
| TM-04 | P0 | Plan card | Shown in the transcript. The user can edit the text, reassign agents, change dependencies, and add or remove steps, then approves. Nothing runs before approval. |
| TM-05 | P0 | Execution | A step starts once all its dependencies are accepted (existing scheduler). Each step runs in a fresh session of its agent, with the step input and references to the accepted output files from earlier steps. Step cards in the transcript stream each step's output. |
| TM-06 | P0 | Write coordination | At most one Edit-level run per folder at any time, counting both chat turns and team steps. Read-only runs can run at the same time, up to the global limit. A blocked step shows "waiting for folder". |
| TM-07 | P0 | Review | By default the user accepts each step. Alternatively, a reviewer agent that has no production step in the plan returns pass, rework or blocked. Rework is limited to 0–2 rounds, and every round's runs are kept (v0.3 §9). |
| TM-08 | P1 | Worktree isolation | In git projects, Edit steps can run in their own git worktree on a new branch. After acceptance the user sees the diff and chooses to merge or discard. Merge conflicts are left to the user, in the terminal. |
| TM-09 | P1 | Lead wrap-up | Once every step is accepted, the lead posts a summary to the conversation. |
| TM-10 | P0 | Pause, stop, continue | Behaves as in v0.3 acceptance case A26. A restart never starts steps on its own. |

### 6.4 Media studio: Video, Audio, Design (MD)

The three media modules work the same way. They differ only in their templates, their previews and the director's starting instructions:

- **Video:** script → shot list → keyframes → image-to-video → assembly.
- **Audio:** script → voice or music → mix.
- **Design:** brief → concepts → variants → upscale.

These starting instructions can be edited. No third-party workflows are bundled except one small test template.

Servers:

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| MD-01 | P0 | Server list | The user can register several ComfyUI servers. Each has a name and base URL, and optionally: an SSH tunnel (host alias from `~/.ssh/config`, ports, bound to localhost only), a bearer token kept in the Keychain, an hourly price used for estimates, a maximum download size, and a job limit (default 1). |
| MD-02 | P0 | Health check | Runs on demand and while jobs are active. It shows whether the server is reachable, its ComfyUI version, GPU name and VRAM, queue length, and whether it supports cancelling a single job. A server without single-job cancel cannot be used for jobs (existing rule). |
| MD-03 | P1 | Node check | Before a template runs on a server, the workbench checks that every node type it uses is installed there and lists any that are missing. |
| MD-04 | P2 | Start/stop commands | Optional user-defined start and stop commands (for example a cloud provider's CLI), run only when the user clicks them on the server card. |

Workflow templates:

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| MD-05 | P0 | Template library | Import an API-format workflow JSON of up to 5 MB, and give it a name, module(s), a description (directors read it) and an optional thumbnail. |
| MD-06 | P0 | Parameter mapping | The user picks node inputs to expose as named parameters. Types: text, integer, number, seed, boolean, choice, and image, audio or video file. Each has a default, limits or choices, and a description. Inputs that are not exposed keep their workflow values. Existing `{input}` workflows are migrated to a single text parameter called `input`. |
| MD-07 | P0 | Output mapping | The user marks output nodes and the media type each produces. Outputs from unmarked nodes are still listed, but flagged. |
| MD-08 | P0 | File inputs | Local files are uploaded to the server's input folder before the job is submitted, within a size limit. The uploaded name is recorded on the run. |

Runs and outputs:

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| MD-09 | P0 | Manual run | Any template can be run from a form, without an agent: pick a server, fill in the parameters, review the summary, submit. A "random" seed is turned into a concrete number before submission and recorded. |
| MD-10 | P0 | Job lifecycle | Same as v0.3 §9: stable run ID, `prompt_id` saved, state read from the server, cancel only by ID, an unclear submission becomes Interrupted, downloads are size-checked into the run archive, and a restart never resubmits. |
| MD-11 | P0 | Previews | Images: grid, zoom, side-by-side compare. Video: player, frame scrubbing, duration, resolution and frame rate. Audio: player with waveform and duration. Every output can be revealed in Finder. |
| MD-12 | P0 | History | Each media asset records its project, module, template (with a version hash), parameters, seed, server, `prompt_id`, plan step and run. |
| MD-13 | P1 | Variants | A generate step can ask for up to 8 seeds. The user chooses which variants feed later steps. |
| MD-14 | P1 | Runtime learning | The workbench records how long each template takes on each server and uses the median for estimates. |
| MD-15 | P1 | Export | Accepted outputs can be copied into the project folder, either by hand or automatically. |

Director:

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| MD-16 | P0 | Director mode | In a Video, Audio or Design conversation, the user picks a director agent and the templates and servers it may use. By default that is the module's templates and all healthy servers. The director receives the brief, the attachments, the template catalog (names, descriptions, parameter schemas) and the server list with price notes. It returns a production plan made of three kinds of step: **generate** (template, parameters, and inputs from attachments or earlier outputs), **agent** (for example writing a script or shot list) and **command** (a configured CLI tool such as ffmpeg). Each step has dependencies and acceptance criteria. |
| MD-17 | P0 | Approval before spending | The plan card shows each generate step's final parameters and server, with estimated GPU time and cost. Estimates are labeled as estimates, and shown as "unknown" when there is no price or history. Nothing is submitted before approval. |
| MD-18 | P0 | Budget cap | Each plan has a cap in GPU minutes or estimated cost. Before the next job would go over the cap, the workbench stops submitting and pauses the plan. Jobs already running continue unless the user stops them. |
| MD-19 | P0 | Director review | After a generate step, the director may get evidence: images as files (for agents that can open images), video as N keyframes extracted locally plus its metadata, and audio as metadata only. It returns pass, rework (with new parameters) or blocked. Rework creates a new run, limited to 0–2 rounds. The review must state what evidence it saw, and it must not claim to have watched or listened to anything beyond that evidence. |

### 6.5 Projects and categories (PJ)

| ID | Pri | Requirement | Observable behavior |
| --- | --- | --- | --- |
| PJ-01 | P0 | Categories | Create, rename, recolor, reorder and delete categories. Names are unique and at most 40 characters. "Uncategorized" is built in and cannot be deleted. Deleting a category asks for confirmation and moves its projects to Uncategorized. |
| PJ-02 | P0 | Project fields | Name, exactly one category, one or more modules, a folder, a goal, and a status (Active or Archived). A folder is required for Code. For media-only projects the folder defaults to one created in the app's archive and can be changed. |
| PJ-03 | P0 | All Projects page | Projects are grouped by category in collapsible sections. Filters: category, module, status, text. Sort: last activity, name or created date. Each card shows the modules and counts of conversations, running work, items awaiting review and assets. |
| PJ-04 | P0 | Moving projects | A project can be moved to another category by dragging it, or with a menu command that also works from the keyboard. Moving changes no runs, tasks or sessions. |
| PJ-05 | P0 | Archive | Archived projects are hidden by default and read-only: no new turns or runs. Their data is kept. |
| PJ-06 | P0 | Filters across projects | The Assets, Conversations and Tasks pages can be filtered by category, project and module. |
| PJ-07 | P0 | Migration | Existing projects move to Uncategorized. Their modules are inferred from the agents they used, with Code as the fallback. No IDs change. |
| PJ-08 | P1 | Home counts | Home module cards show counts across all projects. Clicking a card opens All Projects filtered to that module. |
| PJ-09 | P2 | Tags and nesting | Tags in addition to categories, and nested categories. |

### 6.6 What carries over from v0.3 and V04

Still in force: the run model (stable task IDs, a new run for every execution, snapshots, no overwriting), the task states, killing the whole process group on stop or timeout, remote cancellation only by ID, credentials staying with each CLI's own login (tokens in the Keychain only), SQLite with `schemaVersion`, a backup before every migration, keeping corrupted data untouched, never running anything automatically after a restart, and not showing fake progress. Acceptance cases A01–A33 remain release gates.

Changed by this PRD:

1. v0.3 treated free chat as a later addition; chat (§6.2) is now the main way to work.
2. Planning and review work with any agent, not only Codex.
3. ComfyUI workflows use named parameters instead of a single `{input}` (old workflows still work).
4. Projects gain categories, modules and an archive status.
5. Chat turns do not need acceptance, but tracked tasks and plan steps still do.
6. The hard-coded Codex adapter is removed. Every CLI, including existing Codex and generic tools, becomes a CLI definition written by the user (§6.1, §8).

## 7 Safety, permissions and cost

- **Everything is visible.** Every run shows the exact argv, folder, added environment variables and full prompt (AG-03).
- **Writes are limited.** Access levels are capped per agent, the form warns about flags that bypass the CLI's own approvals (TL-07), and only one writer runs per folder (TM-06).
- **Spending needs approval.** No GPU job is submitted without an approved plan or an explicit manual submit. Every plan has a budget cap (MD-18), and estimates are always labeled as estimates.
- **Agent output is data, not commands.** Plans can only reference agents, templates, servers and tools that already exist, within the access the user granted. Text from an agent cannot add tools, register servers or raise an access level. Files and outputs given to directors and reviewers are treated as untrusted input, and what comes back is checked against a schema.
- **Credentials stay with their owners.** Each CLI manages its own login. Server tokens live only in the Keychain. Logs hide any secret the workbench holds.

## 8 Data model changes

The schema moves from version 3 to 4. Before migrating, the workbench writes a backup to `workspace.pre-v06.sqlite`, and the migration runs as one transaction.

- **New:**
  - `Category` (id, name, color, icon, order)
  - `Conversation` (id, projectID, title, timestamps)
  - `Message` (id, conversationID, role, text, attachments, mode, targets)
  - `AgentSession` (conversationID, agentID, CLI, native session ID, last used, state)
  - `ComfyServer`
  - `WorkflowTemplate` (workflow JSON, version hash, parameters, outputs, modules)
- **Changed:**
  - `WorkProject` gains categoryID, modules and status.
  - `Employee` (Agent) gains modules, maxAccess and model.
  - `ToolConfig` becomes the CLI definition: templates, output format, session strategy, structured-output fragment, access level flags, version and login commands.
  - `TaskRun` gains conversation, message and session references, usage, uploaded inputs and generation parameters.
  - `PlanStep` gains a kind (agent, generate or command), template and parameters, and a requested access level.
  - `CollaborationPlan` gains its type (team or production), lead or director, budget cap and amount spent.
- **Legacy:** each `comfyUI` tool becomes one server plus one template with an `input` parameter. `codex` and `command` tools become ordinary CLI definitions with the same behavior: a `codex` tool gets templates equivalent to what the old adapter built, and a `command` tool keeps its argv with instructions switched off. After that, no code path treats any CLI specially.

## 9 UI changes

These describe behavior only; the visuals belong in DESIGN_V06.

- **Sidebar:**
  - "项目任务" becomes **Projects**: All Projects grouped by category, and a project page with tabs for Conversations, Tasks, Plans and Assets.
  - "工具连接" gets tabs for Agents & CLIs, Servers and Workflow templates.
- **Bottom bar:** the "idea" input bar becomes the chat composer (CH-01). It keeps its current place and look.
- **Transcript:** a new view with message bubbles, compact tool activity lines, plan cards, step cards, and inline media previews.
- **Media previews:** image grid and compare, video player with scrubbing, audio player with waveform.
- **Home:** stays as designed in V05. Module cards add counts across projects (PJ-08).

## 10 Milestones

| Milestone | Scope | Exit criteria |
| --- | --- | --- |
| M5 Foundations | TL-01–07, AG-01–03, PJ-01–07, schema v4 migration | A34–A37, A56–A59. Claude Code and Codex, added by hand from the Appendix A examples, pass the version and login checks and answer a test prompt. |
| M6 Chat | CH-01–10 | A38–A44. A real Claude Code conversation with several turns edits a git repository, survives a stop and an app restart, and continues in the terminal. |
| M7 Team | TM-01–07, TM-10 | A45–A47. A real plan with Claude Code as lead and Codex as a worker, run on a sample repository. |
| M8 Media | MD-01, 02, 05–12, 16–19 | A48–A55. Real cloud server runs of one image, one video and one audio workflow through a director. |
| M9 Finish v0.6 | All remaining P1 items | P1 cases are added to VALIDATION.md as each item ships. |

M5 comes first because everything else depends on it. Once M5 is done, the server, template and manual-run part of M8 (MD-01, 02, 05–12) can be built alongside M6 and M7, since it touches different code. The director part (MD-16–19) needs M7's plan engine. Each milestone ends with a VALIDATION.md entry that lists what was proven and what was not.

Status on 2026-10-18: M5–M9 are implemented with the fixture checks recorded in [VALIDATION.md](VALIDATION.md). The product is now named **Workbench**. The independent [PRD review](REVIEW_2026-10-18.md) found four reproducible issues, including budget enforcement gaps; implementation does not mean final acceptance. Codex login and a single real reply have been confirmed on this Mac, with a test-result classification bug. Real multi-turn editing and cross-CLI collaboration, A55 on a real cloud GPU, and hands-on interaction and accessibility testing remain open.

## 11 Acceptance cases

| Case | Steps and expected result | Gate |
| --- | --- | --- |
| A34 | With no CLI added, the composer, agent form and Home all show "Add CLI" and keep the user's text. A CLI typed as a command name is saved as an absolute path and runs when the app is launched from Finder. A CLI whose executable has been moved shows as Missing, and runs that need it are blocked with "Fix path". | P0 M5 |
| A35 | Login checks for Claude Code and Codex, both added by hand, tell apart logged in, logged out and check failed. No model is called and no run is created. | P0 M5 |
| A36 | Custom CLI: a prompt containing quotes, `;`, `$(…)` and line breaks arrives as one argv element. The resume template is used on the second turn. | P0 M5 |
| A37 | A Read-only Claude Code turn leaves the project's file hashes unchanged; an Edit turn can change them. A level whose flags contain a known bypass option shows a warning. | P0 M5 |
| A38 | Reply text appears before the process exits. Tool activity is summarized, and the raw log is archived. | P0 M6 |
| A39 | A second message resumes the same native session (the agent remembers a fact from the first turn). The session ID is recorded. | P0 M6 |
| A40 | A conversation resumes after an app restart. A turn running at quit becomes Interrupted and is not sent again. | P0 M6 |
| A41 | Stopping mid-turn ends the process group within the v0.3 limits and keeps the partial output. The next message resumes the session or says why it can't. | P0 M6 |
| A42 | A message to a busy agent is queued and runs afterwards. Cancelling a queued message stops it from running. | P0 M6 |
| A43 | "Open in Terminal" continues the same session interactively, and the chat continues it afterwards. | P0 M6 |
| A44 | A logged-out CLI, a missing executable and an action denied by the CLI each show a different message. | P0 M6 |
| A45 | A Claude Code lead plans work for Claude Code and Codex, using only the selected agents. Invalid and cyclic plans are rejected. An edited plan runs, and nothing ran before approval. | P0 M7 |
| A46 | Two Edit steps on the same folder never overlap in time, while two Read-only steps do. | P0 M7 |
| A47 | A reviewer using a different CLI than the producer returns pass or rework. Rework stops at the limit, and old runs are kept. | P0 M7 |
| A48 | Two servers are registered, and their health checks show GPU, VRAM and queue. A server without single-job cancel is blocked from running jobs. | P0 M8 |
| A49 | A template is imported and its parameters mapped. An old `{input}` workflow migrates and still runs. | P0 M8 |
| A50 | A manual run with an image parameter uploads the image, submits and downloads the outputs. The random seed is recorded as a number, and running again with the same parameters reuses it. | P0 M8 |
| A51 | A director turns a video brief into a plan with generate and command steps, and estimates are shown. Nothing is submitted before approval. | P0 M8 |
| A52 | A plan reaching its budget cap stops submitting and pauses. A running job continues unless the user stops it. | P0 M8 |
| A53 | A review based on keyframes asks for rework with new parameters, which creates a new run within the limit. An audio review is marked as based on metadata only. | P0 M8 |
| A54 | Image grid and compare, video scrubbing and audio waveform playback all work on downloaded outputs. | P0 M8 |
| A55 | On a real cloud GPU server reached through an SSH tunnel, one image, one video and one audio workflow complete through a director, with their `prompt_id`s recorded. This needs a server, workflows and a budget from the user. | P0 M8 |
| A56 | Categories can be created, renamed, reordered and deleted. Deleting one moves its projects to Uncategorized, and names stay unique. | P0 M5 |
| A57 | The v3→v4 migration writes a backup, puts existing projects in Uncategorized, and leaves IDs, runs and tasks unchanged. A failed migration rolls back. | P0 M5 |
| A58 | All Projects filters by category, module and status. Archived projects are hidden and read-only. | P0 M5 |
| A59 | Filtering Assets by a category shows only assets from that category's projects. | P0 M5 |

## 12 Open questions

1. **Cloud GPU provider.** Which provider or providers do you use, and how is ComfyUI reached: an SSH tunnel, or public HTTPS with a token? This affects MD-01 and MD-04.
2. **ComfyUI version.** Do your servers run a recent enough ComfyUI to support cancelling a single job? Without it, the current rule blocks job submission.
3. ~~More CLIs~~ Resolved in revision 2: no CLI is built in; every CLI is added by hand.
4. **Team writes.** This PRD runs Edit steps one at a time in the project folder and makes git worktrees an option (TM-08, P1). Should worktrees be the default instead?
5. **Media outputs.** Should accepted outputs stay only in the app archive, or also be copied into the project folder automatically (MD-15)?
6. **Categories.** This PRD gives each project one category. Do you also need tags or nested categories soon?
7. ~~Bypass modes~~ Resolved in revision 2: there are no presets. The user writes every flag, and the form warns about known bypass options.

## Appendix A Example CLI definitions

This appendix is documentation only; the app ships none of it. The user copies the values into the Add CLI form. The Claude Code flags were confirmed in the `--help` output of Claude Code 2.1.287 on this Mac on 2026-10-17, and the exact access level flags are settled by acceptance case A37. Codex 0.163.0 is now installed and logged in on this Mac; the flag positions below were checked with its local help. Real single-turn output completed, with the test-result classification issue documented in the review. Enter each argument on its own line in the form; `{flags}` must precede `resume` so sandbox flags remain on `exec`.

| Field | Claude Code | Codex |
| --- | --- | --- |
| Executable | `claude` (resolved to `~/.local/bin/claude`) | `codex` |
| New turn | `-p {prompt} --output-format stream-json --verbose --include-partial-messages --session-id {session_id}` | `exec {flags} --json --skip-git-repo-check -- {prompt}` |
| Resume | `-p {prompt} --output-format stream-json --verbose --include-partial-messages --resume {session_id}` | `exec {flags} resume --json --skip-git-repo-check -- {session_id} {prompt}` |
| Continue in terminal | `--resume {session_id}` | `--sandbox read-only resume {session_id}` |
| Output format | stream-json events; session ID assigned by the workbench | JSONL events; session ID read from the output |
| Instructions | `--append-system-prompt {instructions}` | in front of the prompt (default) |
| Model | `--model {model}` | `--model {model}` |
| Structured output | `--json-schema {schema}` | `--output-schema {schema_file}` |
| Read-only | `--permission-mode plan`, or `--permission-mode dontAsk` with only reading tools allowed | `--sandbox read-only` |
| Edit in project | `--permission-mode acceptEdits` | `--sandbox workspace-write --add-dir {output}` |
| Version | `--version` | `--version` |
| Login status | `auth status` (logged-out text: `"loggedIn": false`) | `login status` (logged-out text: `Not logged in`) |
| Login | `auth login` | `login` |

Flags that bypass approvals and trigger the TL-07 warning: Claude Code `--permission-mode bypassPermissions` and `--dangerously-skip-permissions`; Codex `--sandbox danger-full-access` and `--dangerously-bypass-approvals-and-sandbox`.

ComfyUI endpoints used: `POST /prompt`, `GET /history/{id}`, `GET /queue`, `GET /view`, `POST /upload/image`, `GET /system_stats`, `GET /object_info`, and `/api/jobs` (list and cancel).

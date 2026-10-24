# Workbench 0.4.0 验证记录

2026年10月2日。M0至M4的代码已实现，本机候选交付包已构建；真实远程制作与原生人工操作尚有验收项。以下区分核心测试、原型、原生集成、实际AI请求与外部服务，不将模拟成功记为业务完成。

## 当前结论

| 范围 | 验证结果 | 证据 |
| --- | --- | --- |
| PRD与设计 | v0.3 Word与Markdown同源；10页逐页检查中文、表格、分页与链接 | docs/PRD.md、AI员工工作台_PRD_v0.3.docx；work/prd-v03-render |
| Swift核心与PTY | 46项XCTest通过，0失败，包含工作区迁移与真实PTY | work/release-tests.log；Tests/WorkbenchCoreTests |
| 原型 | 20类空间交互及20类员工与草稿配置检查通过；1440×960、1100×800、1100×720 | work/studio-check.json、employee-check.json；scripts/verify_studio.cjs、verify_employees.cjs |
| 原生组件 | 11张NSHostingView渲染检查，含空状态、多员工、头像、深色、小窗口、真实协作、计划编辑和远程配置 | work/studio-render；scripts/render_native_studio.sh |
| 本地执行 | 真进程、双通道日志、独立run、产物、交接、并发和恢复集成通过 | work/final-native-verification.log |
| 工具版本检测 | 实际进程使用版本专用参数；检测结果经SQLite重启恢复；更新后重新检测；非零退出保留stderr提示，不启动业务任务 | work/final-native-verification.log；scripts/verify_native_execution.swift |
| 草稿移出与恢复 | 确认后移出活动列表、不能执行或分配；SQLite重启后可恢复原编号与输入；已执行记录拒绝移出 | work/final-native-verification.log；scripts/verify_native_execution.swift |
| 长日志组件响应 | 100,000行完整归档，实际NSHostingView更新中主线程最长间隔0.178秒；停止回调至终态1.09秒 | work/native-log-response.json；scripts/verify_native_log_response.sh |
| Codex单任务 | 已登录CLI实际非交互请求、最终回复归档与人工验收通过 | 实际task 8446B866-1C36-4A59-B43C-5D1CE9DF31CA，run 5800C7E6-4E87-40E3-BF9A-0B17A8907A4F |
| 未登录诊断 | 隔离空CODEX_HOME的真实login status非零退出；保留Not logged in诊断；原登录未改 | work/final-native-verification.log及对应QA目录/codex-login-failure.log |
| ComfyUI接口 | 本地HTTP合约测试通过提交、查询、下载、取消和恢复；未执行图像生成 | work/final-native-verification.log；scripts/comfy_fixture.py |
| 钥匙串 | 随机测试账号新增、读取、更新、删除通过；无真实凭证，测试条目已清理 | work/keychain-native-qa.log |
| M4确定性协作 | 跨区依赖、一次返工、独立审核、暂停、整计划停止、零返工上限、重启继续和不重复生产通过 | work/final-native-verification.log |
| M4实际AI协作 | AI拆解、Mia视觉文稿、Nova依赖交付、Atlas审核；2份交付通过且独立内容复核通过 | work/m4-real-collaboration-recheck.log、m4-real-delivery-audit.json |

Release构建成功，Universal二进制包含x86_64与arm64；codesign深度严格校验通过。应用包与源码包ZIP完整性、SHA-256、当前与打包源码哈希及解压后App签名均通过。证据为work/release-build.log、release-tests.log、release-signature.log与releases/build-manifest.json。编译兼容macOS 14及以上；实际运行验证来自当前Intel、macOS 26.6.2、Xcode 26.2环境。Apple Silicon尚未在该硬件或macOS 14机器运行。

## PRD验收对应

| 用例 | 已取得证据 | 尚需完成 |
| --- | --- | --- |
| A01–A05 | 空格路径、字面参数、stdout/stderr、非零退出、无权限、人工验收状态；真实进程与Store集成 | 原生人工操作检查 |
| A06–A07 | 所属进程组停止、忽略TERM的父子进程退出、短超时状态和日志 | 对主动脱离进程组的守护程序不作停止保证 |
| A08–A10 | SQLite重启、损坏保留、版本拒绝、写入失败回滚、新run与旧文件保留 | 无新增核心缺口 |
| A11 | 跨项目路径拒绝；来源run产物归属验证；显式交接创建下游草稿 | 原生文件选择人工复核 |
| A12 | 100,000行完整落盘、显示缓存有界、UTF8跨块测试；实际原生组件布局与停止回调响应测试通过 | 真人滚动、点击停止和键盘操作仍需检查 |
| A13 | 实际Codex请求与独立未登录诊断；失败日志保留 | 未登录exec完整UI操作路径未人工检查 |
| A14–A18 | 空状态和窗口渲染；原型键盘、搜索、分配确认；原生同类接口与操作入口已实现 | 原生键盘、VoiceOver、拖拽确认、氛围跨重启人工检查 |
| A19–A22 | 原生Store交接、重复保护、多员工编辑、头像缩略图及源图移除后恢复；JSON迁移与备份，不虚构未启动run | 原生表单与文件选择人工检查 |
| A23 | HTTP合约、精确编号、取消后查询、其他作业保留、下载限额/完整性、重启不重发、预检查失败不记为已提交 | 指定真实ComfyUI服务、工作流及预算后，完成真实生成；可选SSH实际隧道验证 |
| A24–A25 | 真实AI计划与跨区生产/审核；循环、重复、无效员工拒绝；有限返工的确定性验证 | 图像、音视频内容仍由人工验收，不属于当前文本AI审核能力 |
| A26 | 暂停不停止当前任务、整计划取消、重启暂停、继续只启动未开始步骤；审核不足暂停，复审不重复生产 | 原生整个操作路径人工复核 |

## 实际AI协作记录

工作区：work/collaboration-qa/FF3D39BA-5D19-4BD4-B109-1142BF948B9C。项目272FDBF3-B568-4D3B-BA9F-386C235AD14E，计划3549D3B8-F06C-4A96-839B-C2B6F6990B63。使用已登录Codex的只读模式，共6次真实请求：规划1次、生产2次、审核3次。

首次审核因仅给文件路径而无法读取正文，正确返回blocked；修正证据传入后对同一生产run复审。原blocked记录保留，未重跑生产。两份最终交付分别为103与111字符，包含完全相同的3个色值，第二份恰有3条编号检查项；独立脚本核对与AI结论一致。6个run、3条审核记录与1个计划重启后保留。

| 交付 | 来源run | 状态 |
| --- | --- | --- |
| 撰写工作室视觉规范 / Mia | 9063868D-680B-4940-ABA6-C6DA9781D7F0 | 产物已验收，生产仅1次 |
| 撰写实现检查清单 / Nova | 67C4F193-684B-439C-BF73-43E83D9D5B0A | 依赖前序交付，产物已验收，生产仅1次 |

这次结果证明文本协作闭环及中断后复审有效，不证明图像、音乐、视频的语义审核或复杂软件项目可自动交付。

## 可重复执行

    zsh scripts/build.sh
    zsh scripts/verify_native_execution.sh --collaboration --codex-login-failure
    zsh scripts/verify_native_execution.sh --keychain
    zsh scripts/render_native_studio.sh
    zsh scripts/verify_native_log_response.sh

长日志测试曾复现SwiftUI Text布局占用主线程并影响停止响应；替换为只读NSTextView后通过。测试在隔离工作区生成中文日志、持续布局真实任务详情并触发Store停止，不调用模型，也不操作用户桌面。结果不是人工滚动或VoiceOver验收。

HTTP测试先启动scripts/comfy_fixture.py，使用其打印的本地URL运行verify_native_execution.sh --remote-fixture URL。它只产生测试文本。verify_real_collaboration.sh会使用登录账户发起真实模型请求，不属于默认构建检查。

原生渲染检查使用隔离数据，不能替代真人键盘与辅助功能操作。异常退出也不能证明CLI脱离进程组或远程作业已停止，恢复必须检查旧任务。公共签名、公证和App Store发行不在本次本机交付范围。

## 工作室V04新增验证

0.4.0构建5覆盖用户确认的卡片UI、默认浅色、动态工作区、内置终端和新图标。46项自动测试通过，含5个工作区及认证状态用例和2个真实PTY用例。SQLite v2迁移前备份为可独立读取的数据库，未知旧部门保留，改名不修改历史执行快照，六个工作区重启后保留。

scripts/verify_native_studio_v04.sh在隔离SQLite、隔离偏好和自有NSHostingView中检查八张原生组件画面。系统深色时默认浅色通过实际像素检查；主动选择深色后渲染墨绿界面。检查覆盖1440×900、1100×720、多员工、员工终端和工作区新增及编辑表单。常用任务按钮固定在员工详情底部，小窗口仍可见。

登录检测的已登录、未登录、失败、未配置通过确定性本机CLI验证，不调用AI；检测不创建业务任务或run。真实PTY测试检查目录、交互输入、中文和emoji、ANSI、调整行列、Ctrl-C；组件集成验证收起复用、元信息重启不启动进程、结束终端不误停管理任务。终端账号登录、实际输入法、粘贴和VoiceOver仍需真人检查。

原有执行与协作回归通过，证据为work/v04-execution-qa.log；十万行日志重新验证，主线程最长间隔0.169秒，停止到终态1.082秒，完整日志100000行，见work/native-log-response.json。新版图标已导出macOS全部10个尺寸，1024和32像素图像尺寸及透明通道已检查；原生顶部缩小显示已检查。

证据：work/native-studio-v04-verification.json、work/v04-tests.log、work/v04-native-qa.log、docs/design/native-v04。源码包和应用包附带V04需求补充与组件验收记录。当前组件和后端检查不能替代原生人工操作、Apple Silicon及旧系统实机验证。实际ComfyUI生成仍需指定服务、工作流与预算。


## 工作室V05参考图实现验证（2026-10-06）

版本0.5.0，构建6。本轮只调整原生界面、导航与任务输入衔接，继续使用既有SQLite和执行服务。46项自动测试全部通过（work/v05-tests.log），Debug与Universal Release构建通过，Release含x86_64/arm64并通过codesign严格校验。

scripts/verify_native_studio_v05.sh使用隔离SQLite、偏好设置和独立.app宿主加载真实Assets.car，输出13张原生SwiftUI组件快照。覆盖1560×1008、1440×900、1100×720；系统深色下默认浅色；主动选择深色；空首页；员工、知识库、工作流；想法预填表单；终端员工详情；工作区编辑与六区布局。默认1440×900下四张卡片、添加入口和输入栏均可见，小窗口通过滚动继续查看。

实际截图中AI横幅和四区插画的亮度标准差均超过0.08、彩色像素比例均超过8%，避免图片只在磁盘存在而实际未绘制的误判。测试员工与草稿明确属于隔离样例，未写入真实用户数据库，也未调用AI或远程生成服务。

页面浏览/渲染不创建run、不修改草稿；空首页没有虚构员工或任务。新增六区及编辑名称后，重读SQLite确认员工归属和任务编号保留。内置PTY收到真实中文与ANSI命令输出，收起重开保留同一会话。完整报告为work/native-studio-v05-verification.json；截图归档在docs/design/studio-v05/native。

限制：离屏宿主未暴露可执行的AX导航节点，本轮没有声称完成真实点击导航、输入法、粘贴、VoiceOver或拖拽操作验收。预填表单截图验证组件内容，取消保留/保存跳转经过代码检查，仍需完整真人交互复核。Apple Silicon及macOS 14实机、指定ComfyUI真实生成仍沿用此前未完成状态。


## M5 Foundations (2026-10-18)

Scope: PRD v0.6 revision 2, items TL-01–07, AG-01–03, PJ-01–07 and the schema 4 migration. The app ships no built-in CLI; every CLI is added by hand.

| Check | Result | Evidence |
| --- | --- | --- |
| Core tests | 62 passed, 0 failed (46 existing + 16 new for CLI templates, output parsing, login shell lookup, categories, filters and the v3→v4 migration) | `swift test` |
| App build | Debug build succeeded with no warnings in the app or core sources | `zsh scripts/build.sh` |
| A34 | A fresh store has no CLI, agent or demo task; Home, the composer and the agent form prompt "添加 CLI". `claude` typed as a command name resolved through the login shell to `/Users/ocean/.local/bin/claude`. A CLI whose executable moved is shown as missing and its run is blocked with "修正路径"; nothing launches. | `zsh scripts/verify_m5.sh` → `work/m5-qa/m5-verification.json` |
| A35 | Fixture login check returned logged out, failed and logged in for the three states. Real Claude Code 2.1.287 `auth status` was classified as logged out under Finder's minimal PATH. Neither check created a run or sent a prompt. | same |
| A36 | A prompt containing quotes, `;`, `$(…)`, a line break and `{output}` reached the CLI as one literal argv element; nothing was expanded. | same |
| A37 | With a fake CLI using the Appendix A Claude Code flags: the read-only run passed `--permission-mode plan` and left the project's files unchanged; the edit run passed `acceptEdits` and changed a file; a read-only agent asking for edit was capped at read-only; a CLI with no edit flags refused an edit run before launch. | same |
| Planning with any CLI | The planner ran a non-Codex CLI read-only, passed the schema through the user's structured-output flag, and the plan decoded from `result.json`. | same |
| A56–A59 | Categories added, renamed, reordered and deleted (projects moved to Uncategorized); duplicate and reserved names rejected; filters by category, module and status; archived projects hidden and read-only; assets filtered by category came only from that category's projects; everything survived a restart. | same |
| A57 | A v3 database migrated through the app store: `workspace.pre-v06.sqlite` written, the Codex adapter turned into an ordinary CLI definition, projects in Uncategorized with an inferred module. A copy of this Mac's real database (schema 3) also migrated, and reloading it gave identical data; the original was not touched. | same; scratch copy |
| Snapshots | 16 offscreen renders: Home and Tools without a CLI, Add/Edit CLI form, CLI list with a missing CLI and a failed test prompt, agent and task forms, All Projects (1440×900, 1100×720, dark), project detail, category manager, project form, assets with filters. | `work/m5-qa/snapshots` |

Not yet verified:

- Real Claude Code runs. The standalone `claude` CLI on this Mac is not logged in (`auth status` reports `loggedIn: false`), so a real test prompt and A37 with the real model are pending until the user runs "在终端登录" for that CLI. The exact read-only flag (`plan` versus `dontAsk` with reading tools) is still to be confirmed against the real model.
- Codex is not installed on this Mac, so its Appendix A values are unverified.
- Hands-on clicking, keyboard, drag and drop, alerts and VoiceOver. Snapshots render the views but do not prove these interactions.


## M6 Chat and M7 Team mode (2026-10-18)

Scope: PRD v0.6 CH-01–10 with CH-12 and CH-13, TM-01–07 with TM-09 and TM-10. The input bar is now a chat composer: pick agents with @, choose single, parallel or team mode and the access for the turn. Each project page has 对话 / 任务 / 计划 / 素材 tabs.

| Check | Result | Evidence |
| --- | --- | --- |
| Core tests | 70 passed, 0 failed (8 new for conversations, sessions, transcript context, restart recovery, failure messages, permission denials and the plan schema) | `swift test` |
| A38 | Reply text appeared in the transcript while the CLI was still running; the raw event log was archived with the run. | `zsh scripts/verify_m6m7.sh` → `work/m6m7-qa/m6m7-verification.json` |
| A39 | A follow-up resumed the same native session with `--resume`, and the agent recalled a codeword from turn 1. | same |
| A40 | A second store opened while a turn ran saw it as Interrupted; it was not sent again, and the conversation then resumed its session. | same |
| A41 | Stop ended the turn in under 4 seconds and kept the partial reply; the next message resumed the session. | same |
| A42 | Messages to a busy agent queued and ran afterwards; a cancelled queued message never reached the CLI. | same |
| A43 | "在终端继续" opened the CLI interactively on the same session in the built-in terminal; the chat then continued that session. | same |
| A44 | A logged-out CLI, an action the CLI denied, and a missing executable each produced a different message. | same |
| CH-09, CH-12 | A reply became a draft task; a parallel message reached two CLIs as separate sessions, forced read-only. | same |
| A45 | A Claude Code lead planned for Claude Code and Codex using only the selected agents; a cyclic plan was rejected and repaired once; nothing ran before approval; an edited plan ran. | same |
| A46 | Two Edit steps in one folder never overlapped, while two Read-only steps ran at the same time. | same |
| A47 | Claude Code reviewing Codex asked for one rework, then passed; both runs were kept. | same |
| TM-09 | After every step was accepted, the lead posted a wrap-up in the conversation. | same |
| Snapshots | 10 offscreen renders: project conversation (1440×900, 1100×720, dark), transcript, team plan with step progress, failure messages, pending plan card, plan approval sheet, composer in team and home modes. | `work/m6m7-qa/snapshots` |

Both CLIs in these checks are fixtures (`scripts/fixtures/claude_like.py` and `codex_like.py`) that speak each CLI's output format without calling a model. Real Claude Code and Codex runs still wait on the user logging in to those CLIs; the exact read-only flag for Claude Code is still to be confirmed against the real model. Hands-on clicking, keyboard, drag and drop and VoiceOver remain untested.


## M8 Media studio (2026-10-18)

Scope: PRD v0.6 MD-01, MD-02, MD-05–12, MD-16–19, plus MD-14 (runtime learning). Connections now list CLIs, production servers and workflow templates. A generation job runs as a task: files are uploaded, the template's parameters are written into the workflow, random seeds become numbers before submission, and the outputs are downloaded (size-checked) into the run's archive. In a chat, one agent can act as director and write a production plan with agent, generate and command steps; the user edits it, sets a GPU-minute or cost cap and starts it.

| Check | Result | Evidence |
| --- | --- | --- |
| Core tests | 79 passed, 0 failed (9 new for template suggestion, parameter parsing and limits, workflow resolution, mapping validation, runtime estimates, production plans, legacy ComfyUI conversion, server health and multipart upload) | `swift test` |
| A48 | Two servers registered. Health showed ComfyUI version, GPU, VRAM and queue; a server without single-job cancel was shown as unusable, and a job sent to it failed before anything was posted. A running job was cancelled by its ID. | `zsh scripts/verify_m8.sh` → `work/m8-qa/m8-verification.json` |
| A49 | Templates imported with suggested parameters (prompt, seed, image, frames, steps) and outputs; limits edited. A legacy `{input}` ComfyUI tool became a server and a template, keeping the text around the placeholder. | same |
| A50 | A manual run uploaded the reference image, submitted the mapped values with a concrete seed, downloaded the output; "用相同参数再运行" reused the seed. | same |
| A51 | A director turned a video brief into a 5-step plan (agent, 3 generate, command) with estimates; nothing was submitted before approval. | same |
| A52 | With a 0.5-minute cap, the plan paused before the next job would go over, while the job already running finished; raising the budget and resuming continued the plan. | same |
| A53 | The director reviewed the image file and asked for one rework with seed 1234 (new run, old one kept); the video was judged from 4 locally extracted keyframes plus metadata; the audio review was marked metadata-only. Reviews run read-only in an evidence folder, never in the project. | same |
| Command step | The ffmpeg stand-in received the accepted clip and narration files through `{input:…}` and wrote `final.mp4` into `{output}`; the director posted a wrap-up. | same |
| A54, MD-12 | Waveform read from the downloaded WAV; video duration, size and frame rate read from the MP4; each output records template version, seed, server and prompt ID. | same |
| Snapshots | 8 offscreen renders: Connections with servers and templates, template mapping, manual run, server form, production conversation with step results, production approval, assets with history, project page. | `work/m8-qa/snapshots` |

The ComfyUI servers in these checks are local fixtures (`scripts/fixtures/comfy_media.py`) that return prepared PNG, MP4 and WAV files; no model ran. **A55 is not done**: a real cloud GPU run of an image, a video and an audio workflow needs the user's server, workflows and budget. Video frames appear black in offscreen snapshots because AVKit does not draw into an offscreen capture; the keyframe extraction shows the files decode. Playback controls, clicks and VoiceOver still need hands-on testing.


## M9 Finishing v0.6 (2026-10-18)

Scope: the remaining P1 items: TL-08–12, CH-11, TM-08, MD-03, MD-13, MD-15 and PJ-08 (CH-12, CH-13, TM-09 and MD-14 shipped with M6–M8).

| Check | Result | Evidence |
| --- | --- | --- |
| Core tests | 83 passed, 0 failed (4 new: git status parsing, a real temporary repository with worktrees, merge and a forced conflict, CLI definition files, missing nodes and variant limits) | `swift test` |
| TL-09, TL-10 | A CLI definition exported without its ID or detected version and imported as a new CLI; duplicating kept the templates under a new identity; a non-definition file was refused. | `zsh scripts/verify_m9.sh` → `work/m9-qa/m9-verification.json` |
| TL-11 | With a limit of 1 on a CLI, turns in two different conversations ran one after the other. | same |
| TL-12 | A changed `--version` output flagged the CLI "needs re-check"; a successful login check cleared it. Versions are re-read quietly at launch. | same |
| TL-08 | Usage summed per conversation, per project and per CLI. | same |
| CH-11 | An Edit turn in a git project listed the file it changed and showed its diff; a Read-only turn listed nothing. | same |
| TM-08 | With worktrees on, two Edit steps ran at the same time in their own worktrees; the project was untouched until the first merge; the second merge conflicted and was left to the user, then discarded; the step branches were removed. | same |
| MD-03 | The server's node list showed a template's missing node; running it failed before anything was submitted. | same |
| MD-13 | Three variants ran with seeds 100, 101 and 102; acceptance required a pick; only the picked file went on. | same |
| MD-15 | Accepting copied the picked file into the project's "Workbench 导出" folder; exporting again did not overwrite. | same |
| PJ-08 | Home module cards show how many projects use each module and open the filtered project list. | same |

The harness found and led to fixes for three bugs: a step could start in the project folder while its worktree was still being created; a newly prepared worktree step waited for an unrelated event before starting; and variants with the same output file name were taken for files already downloaded.

## Regression and release build (2026-10-18)

- `swift test`: 83 passed, 0 failed.
- `scripts/verify_m5.sh` 15 checks, `scripts/verify_m6m7.sh` 13 checks, `scripts/verify_m8.sh` 9 checks, `scripts/verify_m9.sh` 10 checks: all passed.
- Earlier scripts still pass: `verify_native_execution.sh` (execution, retry, handoff, version detection, draft lifecycle), `verify_native_studio_v05.sh` (13 home and page renders), `verify_native_log_response.sh` (100,000-line log stays responsive).
- Debug build and Universal Release build (x86_64 and arm64) succeeded with no warnings in the app or core sources.

Still not verified: real Claude Code and Codex runs (the standalone CLIs need the user's login; Codex is not installed), A55 on a real cloud GPU with the user's server, workflows and budget, and hands-on clicking, keyboard, drag and drop, alerts and VoiceOver.


## Workbench 改名与独立 PRD 检查（2026-10-18）

本节更新此前“Codex 未安装”的旧状态：本机已安装 Codex 0.163.0，登录及单次真实回复已在此前排查确认；重试后成功仍显示失败是已知的结果判定问题，不能把真实回复完成当作多轮和团队协作验收。

- 核心自动测试：83 项通过、0 失败（改名前基线和改名后的 Release 流程均通过）。
- 四组集成验证：M5 15 项、M6/M7 13 项、M8 9 项、M9 10 项，共 47 项通过；共生成 39 张界面快照。证据为 `work/workbench-review-m5.log`、`work/workbench-review-m6m7.log`、`work/workbench-review-m8.log`、`work/workbench-review-m9.log` 及各 QA 目录下的 JSON 报告。
- 隔离边界复现：四项问题均确认，结果见 `work/prd-review-regressions.json`。这些是已知缺陷的复现，不是缺陷已修复的证明。
- Debug 与 Universal Release 构建成功；Release 包含 x86_64、arm64，ad hoc 签名严格校验通过。
- 两种构建的 `CFBundleDisplayName`、`CFBundleName`、`CFBundleExecutable` 都为 `Workbench`；应用标识仍为 `com.ocean.myworkbench`。首页快照 `work/m5-qa/snapshots/m5-home.png` 已检查，左上角显示首字母大写的 Workbench。
- 打包脚本纳入当前 PRD v0.6、检查报告、M5–M9 验证脚本与 fixtures；生成 Workbench 应用包、源码包和 SHA-256 校验文件。
- 验证脚本显式使用 Xcode 的 macOS 26.2 SDK；当前环境预设的 Command Line Tools SDK 为 26.5，直接混用会导致 SwiftTerm 模块 SDK 不匹配。此为构建环境配置差异，本轮未改业务代码处理它。
- 没有新增真实模型或云 GPU 请求，没有使用真实工作台数据库运行验证。

检查报告见 [REVIEW_2026-10-18.md](REVIEW_2026-10-18.md)。常规模拟验证通过，但仍有四项已复现问题与两项源码确认的需求缺口。真实多轮编辑、跨 CLI 团队、A55 云 GPU 图像/视频/音频、人工交互及跨硬件运行仍未验收。

## 员工与各模块管理补齐（2026-10-18，构建 7）

- 核心测试 94 项通过、0 失败；新增 11 项对象管理测试，覆盖成员关系、删除关联、运行及远程未知状态保护、自动审核步骤、旧计划引用已删除模板和 SQLite 重启。证据：`work/release-tests.log`。
- 真实 Store 集成 10 组通过：员工与 CLI 新增编辑、跨工作区成员增删、分类移除、任务编辑及历史保留、产物重命名与删除、对话删除后拒绝发送/重试/转任务、服务器和模板删除、计划删除、CLI 换绑保护、删除后的重启结果。使用独立数据库和本地 printf，无真实模型请求。证据：`work/crud-qa/crud-verification.json`、`work/crud-integration.log`。
- 6 张新增原生离屏快照已检查：员工目录、工作区成员详情、员工编辑、任务编辑、添加已有员工、工具连接。表单单独渲染时，系统表单以外区域为透明背景；这些图不等于实际窗口的点击验收。
- 原有回归：M5 15 项、M6/M7 13 项、M8 9 项、M9 10 项最终均通过，共 47 项，生成 39 张快照。日志：`work/crud-regression-m5.log`、`work/crud-regression-m6m7.log`、`work/crud-regression-m8-repeat.log`、`work/crud-regression-m9.log`。
- M8 首次在等待“取消远程作业”时失败，隔离记录显示任务变为 interrupted，提示“服务端队列与历史中未找到任务，状态待确认”；未改程序直接复跑通过。从查询与取消的代码时序推断，仍存在取消确认和队列读取的竞争，不能据复跑通过宣称已修复。首次日志保存在 `work/crud-regression-m8-first-attempt.log`，任务日志和数据库位置见 `work/crud-cancel-observation.json`。本轮未修改取消流程；新增删除保护会拒绝删除该状态的任务及相关资源。
- Debug 与 Universal Release 构建成功，应用名为 Workbench、0.5.0 构建 7；Release 包含 x86_64 / arm64，ad hoc 签名严格校验通过。此记录仍不代表原生人工点击、VoiceOver、真实远程业务或双硬件验收。

入口与删除语义见 [OBJECT_MANAGEMENT.md](OBJECT_MANAGEMENT.md)。此次删除保留历史快照、消息、归档及用户文件，不提供自动清盘或恢复入口。此前独立检查报告中的四项问题和两项需求缺口继续保留。

## Dark theme as default (2026-10-18)

- Dark (“夜幕 · 深色”) is now the default appearance, stored under the new preference key `studioThemeV06`. The dark colors and artwork slots are described in [the dark theme note](design/dark-theme/README.md).
- `zsh scripts/render_theme_preview.sh`: 9 offscreen renders in `work/theme-qa` (7 dark, 2 light), passed. Checked by eye against the dark reference:
  - home at 1440×900 and 1100×720
  - empty home
  - AI 员工
  - 工具连接
  - 设置
  - light home
- The five dark images from the user are installed with `scripts/install_dark_artwork.py`: `StudioHeroDark` at 1916×821, and `StudioVideoDark`, `StudioAudioDark`, `StudioCodeDark` and `StudioDesignDark` at 1448×1086 each. Codex image generation was not used, because it hit the ChatGPT usage limit.
  - The sources are kept in `docs/design/dark-theme/artwork/`.
  - The 9 renders were redone with the images, and the theme checks still pass.
  - Compared by eye with the reference: the whole sphere stays in the banner at 1440×900 and 1100×720, and each card object sits below its title.
- Core tests: 94 passed, 0 failures.
- Regression, all passed:
  - M5: 15 checks
  - M6/M7: 13 checks
  - M8: 9 checks
  - M9: 10 checks
  - CRUD: 10 checks
- Debug build succeeded. Release packaging was not rerun.
- The last change only touched the banner and card artwork layout. Core tests and M5–M9/CRUD were not rerun after it; their results above come from the build before the images were installed.
- Still not verified: the dark theme in hands-on use (clicks, VoiceOver, sheets opened from menus), and window sizes other than 1440×900 and 1100×720.

## Pixel style (2026-10-24)

- Added a third style, “像素 · 深色”, selectable in Settings. Ink stays the default. The pixel style has its own palette, stepped corners, hard shadows, block buttons and pixel artwork; see [the pixel style note](design/pixel-theme/README.md).
- The five pixel images from the user are installed as `StudioHeroPixel` (1900×805) and `StudioVideoPixel` (1432×1070), plus `StudioAudioPixel`, `StudioCodePixel` and `StudioDesignPixel` (1520×1008 each).
  - They were installed with `--trim 8`, which cuts the light screenshot frames found on the top and left edges of the audio, code and design sources.
  - A re-measure after trimming shows even edge brightness on all three.
- `zsh scripts/render_theme_preview.sh`: 16 offscreen renders, passed.
  - Six pixel pages: home at 1440×900 and 1100×720, empty home, AI 员工, 工具连接, 设置.
  - An ink home rendered after the pixel pages matches the first ink render (sidebar brightness within 0.005), and the pixel palette differs from ink.
  - Checked by eye: no doubled text on the block buttons, readable captions on their plates, stepped corners on cards, buttons, fields and the composer.
- Core tests: 94 passed, 0 failures.
- Regression, all passed:
  - M5: 15 checks
  - M6/M7: 13 checks
  - M8: 9 checks
  - M9: 10 checks
  - CRUD: 10 checks
- Debug build succeeded. The Xcode project was regenerated for the new `PixelStyle.swift`; project settings are unchanged.
- Still not verified:
  - Switching styles by hand in the running app. Only offscreen renders cover the switch.
  - Project cards, the inspector and sheets in pixel style; they keep rounded corners.
  - VoiceOver.

## Full test pass, fixes, CLI coverage and on-demand servers (2026-10-24)

The details are in [TEST_REPORT_2026-10-24.md](TEST_REPORT_2026-10-24.md).

- **Fixed and covered by tests:**
  - B1–B9: budget caps, variant reservation, recovered CLI errors, changed files, reviewer evidence, Stop reaching the CLI's commands, the login check before a run, the usage-limit message, and the system proxy for CLIs.
  - G1–G3: director scope, health refresh while jobs run, and search filters.
  - T1: the two stale scripts.
- **Automated:**
  - 111 unit tests.
  - Debug build, and a universal Release build (signature and both architectures checked).
  - 16 theme renders.
  - M5 15, M6/M7 13, M8 9, M9 10 and CRUD 10 checks.
  - Server checks: 8 (9 with `--real-codex`).
  - Older native checks, including the two scripts that compile again.
  - The CLI flag audit for Claude Code 2.1.287 and Codex 0.164.0.
- **Real Codex 0.164.0:**
  - 25 of 26 scenarios passed in 8 minutes; average turn 22 s, against 128 s before the proxy fix.
  - The exception is A43a: Codex's own “Trust this folder?” prompt the first time a session continues in the terminal.
  - Codex also directed one image through an SSH server in 62 s.
- **Not verified:**
  - A55 on your GPU server.
  - Claude Code with a real model.
  - A hands-on UI pass.
  - Apple Silicon.

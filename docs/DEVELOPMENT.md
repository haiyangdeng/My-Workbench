# AI员工工作台开发方案

本项目使用SwiftUI工作室界面、可独立测试的Swift核心、系统SQLite和CLI或HTTP适配器，开发范围覆盖PRD的M0至M4。业务记录与执行分离：员工可以编辑，任务编号保持稳定，每次执行保留独立快照、日志和产物。

## 1 工程与环境

目标为macOS 14及以上。当前开发机为Intel、macOS 26.6.2；使用已有Xcode 26.2、Swift 6.2.3和macOS SDK 26.2，Swift 5语言模式。不改变系统xcode-select，不安装额外数据库、Python后端或本地模型。

```bash
export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
zsh scripts/build.sh
```

MyWorkbench.xcodeproj为原生应用工程，Package.swift用于核心测试。增加Swift源文件后运行scripts/create_xcode_project.py同步工程。脚本不承诺其他机器上存在相同Xcode路径，可通过DEVELOPER_DIR指定安装。

## 2 模块与数据

WorkbenchView呈现动态工作区卡片、上方项目桌和对象详情；ConfigurationSheet编辑工具、员工和任务；ExecutionViews承载产物、交接、远程配置；CollaborationViews承载AI规划、计划确认与协作状态。WorkbenchStore在主线程管理数据、有限并发、依赖调度、审核和恢复。

ReadOnlyTextView将只读NSTextView嵌入SwiftUI，承载日志和文本预览，使用按需文本布局并保留选区与滚动位置。活动任务过滤archivedAt，草稿移出和恢复以事务保存；schemaVersion 3兼容迁移原有schemaVersion 2数据，不改变任务编号。移出限制为从未执行、未加入计划、未被依赖的独立草稿。

WorkbenchCore不依赖SwiftUI。ProcessRunner拥有每次CLI的进程组；RunArchive与RunLog管理文件和日志；ComfyClient管理HTTP提交、查询、取消和下载；ReviewEvidence只读取明确归属的产物；CredentialVault管理钥匙串凭证。

| 实体 | 主要字段与约束 |
| --- | --- |
| ToolConfig | executable、argv、adapter、enabled、timeout、versionArguments、remote；无明文凭证 |
| Employee | 稳定id、姓名、头像缩略图或符号、职位、部门、职责、toolID、enabled |
| WorkProject | 稳定id、名称、明确选择的工作目录与目标 |
| WorkTask | 稳定id、projectID、employeeID、输入、验收、状态、依赖、planID、审核来源和可选archivedAt |
| TaskRun | 独立id、taskID、员工工具快照、实际输入与argv、目录、日志、时间、退出码及远程编号 |
| WorkArtifact | 来源task与run、projectID、归档相对路径、类型、大小、验收状态 |
| WorkHandoff | 来源run、目标员工、文件引用、目标、参数、约束、检查、疑问和目标草稿 |
| CollaborationPlan | 项目、步骤任务编号、审核员工、返工上限、暂停状态与批准时间 |
| ReviewRecord | 来源run和审核run、pass或rework或blocked、证据说明 |

默认保存于~/Library/Application Support/MyWorkbench/workspace.sqlite。SQLite按实体表保存带编号的Codable记录，整次变更在事务内提交；失败回滚。schemaVersion为2，未知版本与损坏数据保留原文件并禁用写入。旧workspace.json保留，并额外创建workspace.pre-sqlite-backup.json；只导入一次。旧版真实执行转换为run，未启动或仅取消排队的任务不能被虚构为历史执行。

归档目录为Archives/projects/项目编号/runs/执行编号，未归属任务使用unassigned。execution.log保存完整输出，output保存本次产物。缩略图内嵌员工配置，不依赖源图片。

## 3 本地执行

命令使用绝对路径和独立argv，通过posix_spawn启动；stdin连接/dev/null。参数中的{input}和{output}只作字符串替换，不调用eval或构造shell命令。注册shell本身属于用户明确指定的CLI接口。拒绝无法传入POSIX argv的空字符。

每个run创建独立进程组。stdout和stderr在两个读取队列排空，UTF8增量解码避免中文跨块乱码。日志立即在锁保护下落盘，主线程每150ms批量刷新；显示缓存超过128KiB后保留最近字符，完整日志不截断。结束时先排空管道，再保存终态。

默认并发1个，可设2个。任务先持久化为排队，只有容量与依赖允许时启动；run快照在进程启动前保存。停止先向本次进程组发送SIGTERM，1秒后仍未结束升级SIGKILL；超时有独立状态。工具默认超时1800秒，上限24小时。进程主动脱离所属组的守护程序不属于支持范围。

退出0进入待验收。重试和返工添加新run，保留旧结果。停用员工禁止新任务，停用工具禁止新执行，已有记录保留。工具版本检测由用户主动发起，使用独立argv与10秒上限，不表示已经登录或业务验收成功。

## 4 产物与交接

自动收集本次output目录内的普通文件，跳过符号链接；访问时再次核对项目与run路径，拒绝越界引用。用户主动导入的文件复制到本次归档，同名文件添加版本序号。文本预览有大小上限；图片显示预览，其他媒体由系统应用打开；Finder定位保持来源可查。

验收同时确认本次run及已归档产物；验收后新增的导入文件仍需单独检查。交接必须来自已完成的任务和已验收run，文件必须归属于该run及项目。确认交接只创建下游草稿，不执行；保存同一个交接编号不能创建第二个草稿。

任务依赖使用已验收前序run的文件引用组装执行输入，不自动扫描其他项目。草稿拖拽分配和详情选择负责人都需要确认，已经执行的任务不能换人。

## 5 Codex适配

注册时选择Codex，保存可执行绝对路径。普通任务使用exec、--json、明确sandbox以及--output-last-message，将最终回复归档到result.md。默认read-only；用户选择workspace-write后才允许写入项目及明确的本次产物目录。保留CLI自身登录和权限控制，不复制认证文件，不使用绕过审批与沙箱选项。

规划和审核强制使用read-only、--output-schema和result.json；允许无Git的素材项目使用只读结构化请求。规划传入目标与启用员工信息，不执行生产。审核由归档证据直接输入，避免仅提供文件路径却声称已阅读；不足、截断或不支持的媒体要求blocked并人工检查。最后回复仅作为JSON数据解析，不执行其中的权限或命令指令。

真实调用需要CLI已登录。工具启动、登录状态、模型请求成功和业务验收分别记录；非零退出保留诊断，用户在CLI自身完成登录或修正配置后重试。

## 6 ComfyUI与SSH

ComfyClient使用URLSession及服务端队列与历史接口。配置必须为API格式工作流，文本占位符通过JSON值递归替换。提交前核对job接口，提交前后保存客户端编号和prompt_id；不在断线后自动重发POST。恢复只查询已有编号。

取消仅调用api/jobs/编号/cancel，随后检查本任务的队列与历史。缺少单任务取消能力时显示兼容限制，不回退到全局interrupt。当前接口依据ComfyUI官方服务端实现，实际服务器版本需验证。

远程产物先记录服务位置、类型和HEAD大小。用户主动下载时检查配置上限，URLSession下载到临时文件，核对服务声明与实际大小，再复制进本次归档。没有文件大小或超过限额时不下载。HTTP重定向不自动跟随；Bearer凭证从钥匙串读取，不进入工具快照或日志。

SSH调用系统/usr/bin/ssh，使用已有配置别名、BatchMode、ExitOnForwardFailure与StrictHostKeyChecking，只绑定127.0.0.1。隧道启动与ComfyUI连接检测是不同状态；未完成主机信任或密钥配置时保留SSH诊断，由用户按正常SSH流程处理。断开隧道不能证明远程生成已停止。

## 7 协作与恢复

PlanDraft在确认前验证1至20步、编号唯一、启用员工与工具、依赖存在及无环。确认计划在同一事务中保存步骤与CollaborationPlan；生产任务排队等待依赖全部完成。默认逐步人工验收，可选独立AI审核员工。

审核任务引用具体sourceRunID，ReviewRecord保存来源和审核run。只有当前候选仍对应该run时才能应用结论。pass验收当前候选并放行下游；rework在0至2次上限内创建新run；blocked、超限或执行失败暂停后续。已完成步骤不因继续计划重复执行。人工可以检查候选、提交复审或处理失败后继续。

App正常关闭时阻止遗留运行任务，退出时断开本应用隧道。异常重启将运行或排队记录转为已中断，计划暂停；用户确认继续后仅恢复从未启动的步骤，已有run需单独确认状态。远程恢复不得重提工作流。

## 8 验证入口

```bash
zsh scripts/build.sh
zsh scripts/verify_native_execution.sh --collaboration
python3 scripts/comfy_fixture.py
# 使用fixture实际打印的回环URL
zsh scripts/verify_native_execution.sh --remote-fixture http://127.0.0.1:实际端口
zsh scripts/verify_real_collaboration.sh
zsh scripts/render_native_studio.sh
zsh scripts/verify_native_log_response.sh
```

前两类确定性验证不调用模型；ComfyUI fixture是本地HTTP合约测试，不产生图像，也不替代真实远程服务器验收。verify_real_collaboration会使用已登录Codex账户，实际调用规划、生产及审核；需要主动运行并核对账户预算。验收结果、任务编号与限制记录于VALIDATION.md。

官方依据：[Apple POSIX spawn说明](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/posix_spawn.2.html)、[Codex非交互模式](https://learn.chatgpt.com/docs/non-interactive-mode)、[ComfyUI官方服务端](https://github.com/Comfy-Org/ComfyUI/blob/master/server.py)。

## 工作室V04与终端

WorkArea保存工作区，Employee.workspaceID以稳定编号关联；迁移不修改历史执行快照。SQLite升级前调用sqlite3_backup保存数据库，备份使用DELETE日志模式，以便单文件读取，再事务保存新成员映射和版本。新数据版本为3。

TerminalWorkspace独立管理按需会话、关闭面板、结束和元信息，TerminalSession使用SwiftTerm的AppKit终端与本地PTY；任务调度仍由ProcessRunner管理。SwiftTerm固定1.10.0，Xcode与SwiftPM均保存解析结果，兼容当前环境，无需Metal工具链。原生渲染脚本链接Debug构建的SwiftTerm.o，需先执行build.sh。

登录结果仅存内存，修改路径、适配器或检测argv会使旧结果失效。Codex明确的未登录诊断与其他失败分开处理；通用CLI按配置的状态argv和退出码检测。终端历史只保存元信息，不保存命令和输出，也不自动启动旧进程。

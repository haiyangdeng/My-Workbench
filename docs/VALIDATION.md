# My Workbench 0.4.0 验证记录

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

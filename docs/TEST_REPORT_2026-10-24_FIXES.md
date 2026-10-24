# Workbench 审查修复、像素 Icon 与官网改版验收

日期：2026-10-24。基线：`cf40e53`，Workbench 1.0.0（构建 9）；本次修复发布版本为 **1.0.1（构建 10）**。

## 六项问题

| 审查项 | 修复后的行为 | 验证 |
| --- | --- | --- |
| P1 归档输出目录符号链接越界 | 准备、枚举、导入、读取产物共用目录校验；逐层拒绝 root 以下被替换的 project、runs、run、output 目录 | 临时目录中替换四类目录，均拒绝读写，未向外部目录复制文件；原有归档/迁移用例通过 |
| P1 项目归档后队列继续执行 | 排队任务、生成任务、聊天回复冻结；实际启动入口再次检查；取消项目归档后恢复调度 | 其他项目占用名额时归档排队项目，标记文件没有写入；恢复后才执行；生成入口无请求；聊天排队同样冻结/恢复。已经开始的执行允许结束 |
| P2 命令步骤绕过 CLI 并发限制 | 调度按照实际执行的命令工具计算额度，与使用相同 CLI 的聊天共同计数 | 全局额度 2、命令 CLI 额度 1，两条命令及一条聊天全程至多一个执行 |
| P2 中文和特殊 Git 路径解析错误 | status 和文件列表使用 NUL 分隔；识别重命名双记录；传入文件采用 literal pathspec | 中文、双引号、换行、箭头、冒号和星号名称，以及预先已有的重命名，均通过真实 Git 仓库测试 |
| P2 CLI 提交代码后遗漏改动 | 记录执行前 HEAD，并临时复制原先已变更的文件；对比实际执行前内容；步骤和聊天都保存 changes.diff，聊天优先显示归档差异 | 干净仓库改动后提交、原先脏文件继续修改后提交、已有用户修改直接提交、首个提交、还原文件均通过。已有用户修改不会成为本次新增行；中文文件提交后的证据已验证 |
| P2 导演越过所选资源范围 | 接收计划和批准计划两个入口均校验原请求所选模板、服务器；越范围响应进入修正流程，批准失败不创建任务 | 分别使用排除模板/服务器，两个入口均拒绝；范围内计划可正常接收 |

Git 基线副本在临时目录中保存，仅复制执行前已经变更的文件，生命周期结束自动清理，不暂存文件、不创建提交、不更改 Git refs。较早版本没有归档差异的聊天保留原有实时差异查看方式。

## 图标与界面风格

使用内置 imagegen 工具，基于用户上传的原版图标生成像素版，保留 W 形工作间与四张工作台。原图、用途及完整提示词在 `docs/design/icon-pixel/`。

- Pixel：侧栏使用 `StudioIconPixel`，运行时 Dock 同步使用像素图标。
- Ink、Paper：侧栏及运行时 Dock 恢复原版 `AppIcon`。
- 风格首启读取与切换共用同一入口；偏好仍使用原有保存机制。
- Finder 中安装包/应用文件自身的图标仍是原版。运行时 Dock 切换不修改应用包或签名。

隔离偏好下依次渲染 Pixel → Ink → Paper → Pixel，并将 Dock 返回图片和目标资源统一栅格化为 64×64 后比较。每个通道平均误差小于 1/255；AppKit 会重新编码图片，因而不比较 TIFF 文件字节。

## 官网

保留现有像素插画、靛蓝夜色和像素字体，重做品牌首屏、四色工作区卡片、协作流程、制作能力、风格预览、本地数据说明、下载与首次启动区域。

新增三种风格的可操作预览（含方向键/Home/End）、截图放大与 Escape 关闭；站点品牌和 favicon 使用新像素图标。应用截图来自真实 SwiftUI 离屏渲染，并已更新像素侧栏图标。页面及资源为静态文件，继续兼容现有 GitHub Pages 工作流和项目子路径。

实际浏览器检查：

- 390×844、768×1024、1280×800：未发现横向溢出。
- Pixel/Ink/Paper 预览图片、图标、说明及选中状态同步切换。
- 键盘切换、截图弹层、Escape 关闭及焦点返回可用。
- 图片无加载失败，站内锚点目标存在，浏览器无 error/warn 日志。
- JavaScript 语法检查通过。

## 执行证据

- `work/review-2026-10-24/fix-core-tests.log`：**117 tests, 0 failures**。
- `work/review-2026-10-24/fix-debug-build.log`：**BUILD SUCCEEDED**，Bundle Version **10**。
- `work/review-fixes-qa/verification.json`：**7 组检查通过**，modelCalls=0，gpuRequests=0。
- `scripts/verify_review_fixes.sh` / `.swift`：可重复运行的 Store 与原生图标回归，依赖已完成的 Debug 构建。
- `Tests/WorkbenchCoreTests/ReviewRegressionTests.swift`：归档与 Git 回归。
- `work/review-fixes-qa/home-{pixel,ink,paper}.png`：真实原生界面。
- `work/review-fixes-qa/site-{desktop,mobile,workspaces,full}.jpg`：浏览器截图。
- `work/review-2026-10-24/fix-site-renders.log`：官网所用原生界面重新渲染记录。
- `git diff --check` 通过。

本次没有调用真实付费模型或 GPU，没有读写用户的正式工作区数据库。此处记录发布前本地验证；代码与官网部署状态以本次提交和 Homepage 工作流为准，安装包验证见下文。原有 `.claude/` 未修改。

## 1.0.1 正式安装包验证

使用 `scripts/make_dmg.sh` 生成 Release 通用程序，**BUILD SUCCEEDED**。DMG 只读挂载后验证：

- 应用版本 **1.0.1**，构建号 **10**，最低 macOS **14.0**。
- 可执行文件包含 **x86_64 / arm64** 两种架构。
- `codesign --verify --deep --strict` 通过；仍为 ad hoc 签名。
- `Assets.car` 包含 `StudioIconPixel`；卷内 Applications 快捷方式正确。
- ZIP 内应用版本与 DMG 一致。
- `hdiutil verify` 及 DMG/ZIP SHA-256 校验通过。

产物为 `Workbench-1.0.1.dmg`、`Workbench-1.0.1-macOS.zip`、`Workbench-1.0.1-SHA256SUMS.txt`。验证记录在 `work/review-2026-10-24/release-1.0.1-verification.json`，完整构建日志在 `work/release-build.log`。

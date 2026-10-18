import AppKit
import SwiftUI
import SwiftTerm

@main struct StudioV05Verification {
    @MainActor static func wait(_ condition: () -> Bool, timeout: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Verification timed out")
    }

    // Inspect only objects owned by this component harness; this does not access other apps.
    @MainActor static func accessibilityElements(in view: NSView) -> [any NSAccessibilityProtocol] {
        var queue: [Any] = [view]
        var seen = Set<ObjectIdentifier>()
        var result: [any NSAccessibilityProtocol] = []
        while !queue.isEmpty && seen.count < 5000 {
            let node = queue.removeFirst()
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let element = node as? any NSAccessibilityProtocol {
                result.append(element)
                queue.append(contentsOf: element.accessibilityChildren() ?? [])
            }
            if let childView = node as? NSView { queue.append(contentsOf: childView.subviews) }
        }
        return result
    }

    @MainActor static func terminalText(_ session: TerminalSession) -> String {
        let emulator = session.terminal.getTerminal()
        return (0..<emulator.rows).compactMap { row in
            emulator.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { emulator.getCharacter(for: $0) })
        }.joined(separator: "\n")
    }

    @MainActor static func pixelMetrics(_ bitmap: NSBitmapImageRep, region: CGRect, logicalSize: CGSize) -> (deviation: Double, colorFraction: Double) {
        let scaleX = Double(bitmap.pixelsWide) / logicalSize.width
        let scaleY = Double(bitmap.pixelsHigh) / logicalSize.height
        var luminance: [Double] = []
        var colorful = 0
        for y in stride(from: Int(region.minY), to: Int(region.maxY), by: 5) {
            for x in stride(from: Int(region.minX), to: Int(region.maxX), by: 5) {
                guard let color = bitmap.colorAt(x: Int(Double(x) * scaleX), y: Int(Double(y) * scaleY))?.usingColorSpace(.deviceRGB) else { continue }
                let red = Double(color.redComponent), green = Double(color.greenComponent), blue = Double(color.blueComponent)
                luminance.append(red * 0.2126 + green * 0.7152 + blue * 0.0722)
                if max(red, green, blue) - min(red, green, blue) > 0.18 { colorful += 1 }
            }
        }
        precondition(!luminance.isEmpty, "No screenshot pixels were sampled")
        let mean = luminance.reduce(0, +) / Double(luminance.count)
        let variance = luminance.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(luminance.count)
        return (sqrt(variance), Double(colorful) / Double(luminance.count))
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = project.appendingPathComponent("work/studio-v05-qa")
        let root = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "MyWorkbench.StudioV05.QA.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("paper", forKey: "studioThemeV06")
        precondition(Bundle.main.url(forResource: "Assets", withExtension: "car") != nil, "Run this harness as its app bundle so SwiftUI loads the compiled artwork catalog")

        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        precondition(store.storageAvailable)
        var tool = ToolConfig(name: "本机 CLI", executable: "/usr/bin/printf", arguments: ["%s\\n", "{input}"])
        tool.loginStatusArguments = ["fixture logged in\\n"]
        tool.loginArguments = ["fixture login complete\\n"]
        precondition(store.addTool(tool))
        let workProject = WorkProject(name: "我的创作工作室", directory: root.path, goal: "把一个想法做成可以交付的作品。")
        precondition(store.addProject(workProject))
        let names = [["Echo", "Kai"], ["Aria", "Finn"], ["Nova", "Atlas"], ["Mia", "Ash"]]
        let roles = ["影像创作", "声音制作", "开发工程师", "视觉设计"]
        let titles = [
            ["城市宣传片分镜生成", "产品演示视频剪辑", "短视频脚本优化"],
            ["旁白配音生成", "歌曲合成与改编", "音效设计"],
            ["前端页面开发", "API 接口调试", "功能需求分析"],
            ["海报视觉设计", "PPT 设计优化", "品牌视觉风格探索"]
        ]
        for (index, area) in store.workspaces.enumerated() {
            var members: [Employee] = []
            for member in 0..<2 {
                var employee = Employee(name: names[index][member], role: roles[index], department: area.name, instructions: "本机组件验证员工；使用 printf，不调用 AI 或远程服务。", toolID: tool.id, avatarSymbol: member == 0 ? area.icon : "sparkles")
                employee.workspaceID = area.id
                precondition(store.addEmployee(employee))
                members.append(employee)
            }
            for (number, title) in titles[index].enumerated().reversed() {
                var task = WorkTask(title: title, employeeID: members[number % 2].id, input: "仅创建草稿，禁止组件渲染期间发起执行。", workingDirectory: root.path, acceptance: "人工核对输出后再验收。")
                task.projectID = workProject.id
                precondition(store.addTask(task))
            }
        }
        let originalTasks = store.snapshot.tasks
        let originalEmployees = store.snapshot.employees
        precondition(originalTasks.count == 12 && originalEmployees.count == 8)
        store.checkLogin(tool.id)
        try await wait { store.loginChecks[tool.id]?.state == .loggedIn }
        precondition(store.snapshot.runs.isEmpty && store.snapshot.tasks == originalTasks)

        if let appIcon = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon-512-2x.png")) { _ = appIcon.setName("AppIcon") }
        let requiredAssets = ["StudioHero", "StudioVideo", "StudioAudio", "StudioCode", "StudioDesign"]
        for name in requiredAssets {
            let url = project.appendingPathComponent("Assets.xcassets/\(name).imageset/image.png")
            guard let image = NSImage(contentsOf: url) else { preconditionFailure("Missing native studio asset: \(url.path)") }
            precondition(image.size.width >= 256 && image.size.height >= 256, "Studio artwork must not be an icon-sized placeholder")
            _ = image.setName(name)
        }

        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminal-history.json"))
        let hosting = NSHostingView(rootView: AnyView(WorkbenchView(terminals: terminals, initialPage: .home, store: store).defaultAppStorage(preferences).id("home")))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1560, height: 1008), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { terminals.endAll(); window.orderOut(nil) }
        var screenshots: [[String: Any]] = []
        var artworkMeasurements: [[String: Any]] = []
        var terminalMeasurements: [[String: Any]] = []
        var navigationChecks: [String] = []
        var limitations = ["Rendered owned SwiftUI components offscreen; desktop keyboard, IME, clipboard, VoiceOver and hardware manual QA remain separate."]

        func assertNoExecution() {
            precondition(store.snapshot.runs.isEmpty && store.activeRuns.isEmpty, "Browsing the UI must not execute tasks")
            precondition(store.snapshot.tasks == originalTasks, "Browsing the UI must not alter draft tasks")
        }
        func screenshot(_ name: String, width: CGFloat = 1560, height: CGFloat = 1008, osDark: Bool = false, assertLight: Bool = false) async throws {
            window.appearance = NSAppearance(named: osDark ? .darkAqua : .aqua)
            hosting.appearance = window.appearance
            window.setContentSize(NSSize(width: width, height: height))
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 650_000_000)
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), let png = capture(hosting, bitmap: bitmap) else { preconditionFailure("Could not render \(name)") }
            let path = output.appendingPathComponent("\(name).png")
            try png.write(to: path)
            if assertLight {
                let points = [(12, Int(height * 0.65)), (90, Int(height * 0.70)), (Int(width - 15), Int(height - 15))]
                let lightPixels = points.compactMap { x, y -> NSColor? in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }.filter { $0.redComponent > 0.82 && $0.greenComponent > 0.82 && $0.blueComponent > 0.82 }
                precondition(lightPixels.count >= 2, "The default studio must remain light under an OS dark appearance")
            }
            if name == "native-v05-home-1560" {
                let regions: [(String, CGRect)] = [
                    ("hero", CGRect(x: 820, y: 60, width: 440, height: 200)),
                    ("video", CGRect(x: 245, y: 385, width: 305, height: 135)),
                    ("audio", CGRect(x: 905, y: 385, width: 305, height: 135)),
                    ("code", CGRect(x: 245, y: 710, width: 305, height: 130)),
                    ("design", CGRect(x: 905, y: 710, width: 305, height: 130))
                ]
                for (asset, region) in regions {
                    let metrics = pixelMetrics(bitmap, region: region, logicalSize: CGSize(width: width, height: height))
                    precondition(metrics.deviation > 0.08 && metrics.colorFraction > 0.08, "Rendered \(asset) artwork appears blank (contrast \(metrics.deviation), color fraction \(metrics.colorFraction))")
                    artworkMeasurements.append(["asset": asset, "luminanceStandardDeviation": metrics.deviation, "colorFraction": metrics.colorFraction])
                }
            }
            if name.hasPrefix("native-v05-terminal-") {
                let panelHeight: CGFloat = height < 800 ? 220 : 280
                let region = CGRect(x: 222, y: height - panelHeight + 82, width: width - 246, height: panelHeight - 110)
                let metrics = pixelMetrics(bitmap, region: region, logicalSize: CGSize(width: width, height: height))
                terminalMeasurements.append(["screenshot": name, "luminanceStandardDeviation": metrics.deviation])
                if metrics.deviation < 0.015 { limitations.append("\(name): offscreen bitmap did not capture terminal glyphs; PTY output was verified through the emulator separately.") }
            }
            screenshots.append(["name": name, "path": path.path, "width": Int(width), "height": Int(height), "osDark": osDark])
            print("Rendered \(name) \(Int(width))×\(Int(height))")
            assertNoExecution()
        }
        func show(_ page: StudioPage, selection: StudioSelection? = nil, source: WorkbenchStore? = nil, id: String) {
            hosting.rootView = AnyView(WorkbenchView(terminals: terminals, initialSelection: selection, initialPage: page, store: source ?? store).defaultAppStorage(preferences).id(id))
        }
        func press(_ identifier: String) async throws -> Bool {
            guard let control = accessibilityElements(in: hosting).first(where: { $0.accessibilityIdentifier() == identifier }) else { return false }
            precondition(control.accessibilityPerformPress(), "AX press failed for \(identifier)")
            try await Task.sleep(nanoseconds: 300_000_000)
            hosting.layoutSubtreeIfNeeded()
            assertNoExecution()
            return true
        }

        try await screenshot("native-v05-home-1560", assertLight: true)
        try await screenshot("native-v05-home-1440", width: 1440, height: 900, assertLight: true)
        try await screenshot("native-v05-home-compact", width: 1100, height: 720, osDark: true, assertLight: true)
        preferences.set("ink", forKey: "studioThemeV06")
        try await screenshot("native-v05-dark-home", width: 1440, height: 900, osDark: true)
        preferences.set("paper", forKey: "studioThemeV06")
        show(.home, id: "home-restored-paper")
        try await Task.sleep(nanoseconds: 300_000_000)

        // SwiftUI may omit some AX nodes in an offscreen host; report that limitation instead of claiming a click test passed.
        for page in [StudioPage.employees, .knowledge, .workflow, .home] {
            if try await press("studio.nav.\(page.rawValue)") {
                let pageWasExposed = accessibilityElements(in: hosting).contains { $0.accessibilityIdentifier() == "studio.page.\(page.rawValue)" }
                if pageWasExposed { navigationChecks.append(page.rawValue) }
                else { limitations.append("AX activated \(page.rawValue), but the offscreen page marker was unavailable; screenshot state is verified separately.") }
            } else { limitations.append("Offscreen host did not expose navigation control \(page.rawValue); no AX interaction coverage claimed.") }
        }
        let axDump = accessibilityElements(in: hosting).map { element -> [String: String] in
            ["id": element.accessibilityIdentifier() ?? "", "label": element.accessibilityLabel() ?? "", "role": element.accessibilityRole()?.rawValue ?? ""]
        }
        try JSONSerialization.data(withJSONObject: axDump, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("accessibility.json"))

        for (page, name) in [(StudioPage.employees, "employees"), (.knowledge, "knowledge"), (.workflow, "workflow")] {
            show(page, id: name)
            try await screenshot("native-v05-\(name)", width: 1440, height: 900)
        }
        let empty = WorkbenchStore(fileURL: root.appendingPathComponent("empty/workspace.sqlite"))
        precondition(empty.snapshot.employees.isEmpty && empty.snapshot.tasks.isEmpty)
        show(.home, source: empty, id: "empty")
        try await screenshot("native-v05-empty")
        precondition(empty.snapshot.employees.isEmpty && empty.snapshot.tasks.isEmpty && empty.snapshot.runs.isEmpty, "Empty UI must not invent demo data")

        let employee = store.snapshot.employees.first { $0.name == "Nova" }!
        let idea = "做一个轻巧的个人作品集网站\n使用浅色界面，展示我的项目与创作过程。"
        hosting.rootView = AnyView(ConfigurationSheet(kind: .task, store: store, preferredEmployeeID: employee.id, initialTaskInput: idea).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light).id("idea-draft"))
        try await screenshot("native-v05-idea-draft", width: 600, height: 660)
        terminals.open(employee: employee, tool: tool, directory: root.path)
        let session = terminals.selected!
        precondition(session.terminal.process.running)
        show(.home, selection: .employee(employee.id), id: "terminal-employee")
        try await Task.sleep(nanoseconds: 300_000_000)
        hosting.layoutSubtreeIfNeeded()
        // The command source splits this phrase, so an echoed command cannot satisfy the output assertion.
        session.send("/usr/bin/printf '\\033[32m%s%s ✓\\033[0m\\n' '中文' '终端验证'\n")
        try await wait({ terminalText(session).contains("中文终端验证 ✓") }, timeout: 12)
        precondition(session.terminal.process.running)
        try await screenshot("native-v05-terminal-employee", width: 1440, height: 900)
        try await screenshot("native-v05-terminal-compact", width: 1100, height: 720)
        terminals.isVisible = false
        terminals.open(employee: employee, tool: tool, directory: root.path)
        precondition(terminals.sessions.count == 1 && terminals.selected?.id == session.id, "Reopening must preserve the terminal process")
        terminals.endAll()
        terminals.isVisible = false
        assertNoExecution()

        let fifth = WorkArea(name: "研究工作区", icon: "book", color: "B79758", description: "把资料整理成可使用的知识")
        let sixth = WorkArea(name: "运营工作区", icon: "megaphone", color: "9A7B83", description: "为日常运营安排伙伴")
        precondition(store.addWorkspace(fifth) && store.addWorkspace(sixth))
        var edited = store.workspaces[2]
        edited.name = "产品开发工作区"
        edited.description = "把想法落地成应用"
        precondition(store.updateWorkspace(edited))
        let restored = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        precondition(restored.storageAvailable && restored.workspaces.count == 6)
        precondition(restored.snapshot.tasks == originalTasks && restored.snapshot.runs.isEmpty)
        precondition(restored.snapshot.employees.map(\.id) == originalEmployees.map(\.id))
        precondition(restored.employee(employee.id)?.workspaceID == edited.id && restored.employee(employee.id)?.department == edited.name)
        hosting.rootView = AnyView(WorkspaceConfigurationSheet(store: restored, areaToEdit: edited).preferredColorScheme(.light).id("edit"))
        try await screenshot("native-v05-workspace-edit", width: 760, height: 558)
        show(.home, source: restored, id: "six-workspaces")
        try await screenshot("native-v05-six-areas", width: 1440, height: 1100)

        let report: [String: Any] = [
            "passed": true,
            "workspace": root.path,
            "fixture": "Local printf tool, four default areas, eight employees, twelve unexecuted drafts. No network calls or user-data writes.",
            "checks": ["All five native artwork regions pass screenshot contrast and color checks", "Light theme remains light under OS dark mode", "Dark option and prefilled idea form render", "No browsing or rendering action creates or changes task execution", "Empty first-run state contains no invented staff or tasks", "Real PTY emits Chinese and ANSI output decoded by the emulator, and reopens the same session", "Six areas and renamed employee membership survive SQLite reload", "Task and employee identities survive workspace editing"],
            "artworkPixelMeasurements": artworkMeasurements,
            "terminalPixelMeasurements": terminalMeasurements,
            "terminalOutputVerified": "中文终端验证 ✓",
            "navigationActionChecks": navigationChecks,
            "screenshots": screenshots,
            "limitations": limitations
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: project.appendingPathComponent("work/native-studio-v05-verification.json"))
        print("Studio V05 native component checks passed; \(screenshots.count) screenshots, \(navigationChecks.count) verified AX navigation actions")
    }

    @MainActor private static func capture(_ view: NSView, bitmap: NSBitmapImageRep) -> Data? {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

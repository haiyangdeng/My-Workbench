import AppKit
import SwiftUI
import SwiftTerm

@main struct ThemePreview {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/theme-qa")
        let root = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "Workbench.ThemePreview.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        var tool = ToolConfig(name: "本地 CLI", executable: "/usr/bin/printf", arguments: ["%s", "{prompt}"])
        tool.versionArguments = []
        precondition(store.addTool(tool))
        var project = WorkProject(name: "我的创作项目", directory: root.path, goal: "把想法变成作品")
        project.moduleIDs = store.workspaces.map(\.id)
        precondition(store.addProject(project))
        let names = [["Echo", "Kai"], ["Aria", "Finn"], ["Nova", "Atlas"], ["Mia", "Ash"]]
        let titles = [["城市宣传片分镜", "短视频脚本优化"], ["旁白配音生成", "音效设计"], ["前端页面开发", "API 接口调试"], ["海报视觉设计", "PPT 设计优化"]]
        for (index, area) in store.workspaces.enumerated() {
            for member in 0..<2 {
                var employee = Employee(name: names[index][member], role: area.name, department: area.name, instructions: "仅供界面渲染，不执行模型请求。", toolID: tool.id, avatarSymbol: member == 0 ? area.icon : "sparkles")
                employee.workspaceID = area.id
                precondition(store.addEmployee(employee))
                var task = WorkTask(title: titles[index][member], employeeID: employee.id, input: "界面草稿", workingDirectory: root.path, acceptance: "人工验收")
                task.projectID = project.id
                precondition(store.addTask(task))
            }
        }
        let original = store.snapshot
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminals.json"))
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        defer { terminals.endAll(); window.orderOut(nil) }
        var screenshots: [String] = [], measurements: [[String: Any]] = []
        func render(_ name: String, page: StudioPage = .home, dark: Bool, osDark: Bool? = nil, width: CGFloat = 1440, height: CGFloat = 900, source: WorkbenchStore? = nil, editor: Bool = false) async throws {
            preferences.set(dark ? "ink" : "paper", forKey: "studioThemeV06")
            window.appearance = NSAppearance(named: (osDark ?? dark) ? .darkAqua : .aqua)
            hosting.appearance = window.appearance
            if editor {
                hosting.rootView = AnyView(ConfigurationSheet(kind: .employee, store: store, employeeToEdit: store.snapshot.employees.first).background(Theme.paper).preferredColorScheme(.dark).id(name))
            } else {
                hosting.rootView = AnyView(WorkbenchView(terminals: terminals, initialPage: page, store: source ?? store).defaultAppStorage(preferences).id(name))
            }
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 650_000_000); hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let target = output.appendingPathComponent(name + ".png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: target)
            screenshots.append(target.path)
            if page == .home && !editor {
                func meanAndBright(_ region: CGRect) -> (Double, Double) {
                    var values: [Double] = []
                    for y in stride(from: region.minY, to: region.maxY, by: 4) {
                        for x in stride(from: region.minX, to: region.maxX, by: 4) {
                            let c = bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / width), y: Int(y * CGFloat(bitmap.pixelsHigh) / height))!.usingColorSpace(.deviceRGB)!
                            values.append(0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent))
                        }
                    }
                    return (values.reduce(0, +) / Double(values.count), Double(values.filter { $0 > 0.75 }.count) / Double(values.count))
                }
                let sidebar = meanAndBright(CGRect(x: 15, y: 520, width: 155, height: 80))
                let hero = meanAndBright(CGRect(x: 205, y: 45, width: width - 230, height: 155))
                measurements.append(["name": name, "sidebarMean": sidebar.0, "heroMean": hero.0, "heroBrightFraction": hero.1])
                if dark { precondition(sidebar.0 < 0.25 && hero.0 < 0.45 && hero.1 < 0.10, "Dark artwork and chrome must stay dark") }
                else { precondition(sidebar.0 > 0.8 && hero.0 > 0.65, "Light mode must remain light, including under OS dark appearance") }
            }
            precondition(store.snapshot.tasks == original.tasks && store.snapshot.employees == original.employees && store.snapshot.runs.isEmpty && store.activeRuns.isEmpty && store.activeTurns.isEmpty, "Rendering must not change work or start execution")
            print("Rendered \(name)")
        }
        try await render("dark-home", dark: true)
        try await render("dark-compact", dark: true, width: 1100, height: 720)
        try await render("dark-employees", page: .employees, dark: true)
        try await render("dark-tools", page: .tools, dark: true)
        try await render("dark-settings", page: .settings, dark: true)
        try await render("dark-employee-editor", dark: true, width: 600, height: 740, editor: true)
        let empty = WorkbenchStore(fileURL: root.appendingPathComponent("empty/workspace.sqlite"))
        try await render("dark-empty", dark: true, source: empty)
        try await render("light-home", dark: false)
        try await render("light-os-dark", dark: false, osDark: true, width: 1100, height: 720)
        let report: [String: Any] = ["passed": true, "screenshots": screenshots, "measurements": measurements, "noExecution": true,
            "limitations": ["Native components rendered offscreen in an isolated workspace; desktop clicks, VoiceOver and hardware QA are separate."]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("theme-verification.json"))
        print("Theme preview passed: \(screenshots.count) native renders")
        exit(0)
    }
}

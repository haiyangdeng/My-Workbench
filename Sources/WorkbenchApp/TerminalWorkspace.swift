import AppKit
import SwiftUI
import SwiftTerm
import Darwin

@MainActor final class TerminalSession: NSObject, Identifiable, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let id = UUID()
    let employeeID: UUID?
    let toolID: UUID?
    let name: String
    let toolName: String
    let directory: String
    let isLogin: Bool
    let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 200))
    @Published var ended = false
    @Published var exitCode: Int32?
    var onEnd: (() -> Void)?

    init(employee: Employee?, tool: ToolConfig?, directory: String, login: Bool, extraEnvironment: [String: String] = [:], command: [String]? = nil) throws {
        employeeID = employee?.id; toolID = tool?.id; name = employee?.name ?? "本机"; toolName = tool?.name ?? "zsh"; self.directory = directory; isLogin = login
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), !directory.contains("\0"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw WorkbenchError.invalidDirectory }
        if let tool, tool.adapterKind == .comfyUI || !FileManager.default.isExecutableFile(atPath: tool.executable) { throw WorkbenchError.invalidExecutable }
        if login, tool?.authenticationLoginArguments == nil { throw WorkbenchError.invalidArguments }
        super.init()
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        configureAppearance(dark: false)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment { environment[key] = value }
        environment["TERM"] = "xterm-256color"; environment["LANG"] = "en_US.UTF-8"
        // A login, or an interactive resume of a chat session, runs the CLI itself; otherwise a login shell.
        let direct = login || (command != nil && tool != nil)
        let executable = direct ? tool!.executable : "/bin/zsh"
        let arguments = login ? tool!.authenticationLoginArguments! : (direct ? command! : ["-l"])
        guard !executable.contains("\0"), !arguments.contains(where: { $0.contains("\0") }) else { throw WorkbenchError.invalidArguments }
        terminal.startProcess(executable: executable, args: arguments, environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory)
        if !terminal.process.running { ended = true }
    }
    func configureAppearance(dark: Bool) {
        terminal.nativeBackgroundColor = dark ? NSColor(red: 0.10, green: 0.14, blue: 0.12, alpha: 1) : NSColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1)
        terminal.nativeForegroundColor = dark ? .white : NSColor(red: 0.16, green: 0.20, blue: 0.18, alpha: 1)
    }
    func send(_ command: String) { terminal.process.send(data: Array(command.utf8)[...]) }
    func launchCLI(_ tool: ToolConfig) {
        guard !isLogin, !ended, terminal.process.running, tcgetpgrp(terminal.process.childfd) == terminal.process.shellPid else { return }
        send("'" + tool.executable.replacingOccurrences(of: "'", with: "'\\''") + "'\n")
    }
    func interrupt() { terminal.process.send(data: [3][...]) }
    func finish() {
        guard !ended else { return }
        let pid = terminal.process.shellPid
        let foreground = tcgetpgrp(terminal.process.childfd)
        // Both IDs are read from this session's owned PTY; never signal the app's group.
        if foreground > 0 && foreground != getpgrp() { kill(-foreground, SIGHUP) }
        if pid > 0 && pid != getpgrp() { kill(-pid, SIGHUP); kill(pid, SIGKILL) }
        terminal.terminate(); ended = true
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        self.exitCode = exitCode.map { ($0 & 127) == 0 ? ($0 >> 8) & 255 : 128 + ($0 & 127) }; ended = true; onEnd?()
    }
}

struct TerminalBookmark: Identifiable, Codable {
    var id = UUID()
    var employeeID: UUID?
    var toolID: UUID?
    var name: String
    var directory: String
}

@MainActor final class TerminalWorkspace: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published var isVisible = false
    @Published var showsLog = false
    @Published var logTaskID: UUID?
    @Published var error: String?
    @Published private(set) var recent: [TerminalBookmark] = []
    static let defaultMetadataURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyWorkbench/terminal-history.json")
    private let metadataURL: URL?
    init(metadataURL: URL? = nil) {
        self.metadataURL = metadataURL
        if let metadataURL, FileManager.default.fileExists(atPath: metadataURL.path) {
            do { recent = try JSONDecoder().decode([TerminalBookmark].self, from: Data(contentsOf: metadataURL)) }
            catch { self.error = "终端历史读取失败，原文件已保留。" }
        }
    }
    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }
    var activeCount: Int { sessions.filter { !$0.ended }.count }
    func open(employee: Employee?, tool: ToolConfig?, directory: String, login: Bool = false, environment: [String: String] = [:], command: [String]? = nil, onLoginEnd: (() -> Void)? = nil) {
        if !login, command == nil, let existing = sessions.first(where: { !$0.ended && $0.employeeID == employee?.id && $0.toolID == tool?.id && $0.directory == directory }) {
            selectedID = existing.id; isVisible = true; showsLog = false; return
        }
        do {
            let session = try TerminalSession(employee: employee, tool: tool, directory: directory, login: login, extraEnvironment: environment, command: command)
            session.onEnd = { [weak self] in self?.objectWillChange.send(); onLoginEnd?() }
            sessions.append(session); selectedID = session.id; showsLog = false; isVisible = true
            recent.removeAll { $0.employeeID == employee?.id && $0.toolID == tool?.id && $0.directory == directory }
            recent.insert(TerminalBookmark(employeeID: employee?.id, toolID: tool?.id, name: session.name, directory: directory), at: 0)
            recent = Array(recent.prefix(12))
            if let metadataURL {
                do { try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(recent).write(to: metadataURL, options: .atomic) }
                catch { self.error = "会话已打开，但保存终端历史失败：\(error.localizedDescription)" }
            }
        } catch { self.error = error.localizedDescription }
    }
    func endSelected() { selected?.finish(); objectWillChange.send() }
    func endAll() { sessions.forEach { $0.finish() }; objectWillChange.send() }
}

struct EmbeddedTerminal: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var dark: Bool
    func makeNSView(context: Context) -> LocalProcessTerminalView { session.configureAppearance(dark: dark); return session.terminal }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) { session.configureAppearance(dark: dark) }
}

struct TerminalPanel: View {
    @ObservedObject var terminals: TerminalWorkspace
    @ObservedObject var store: WorkbenchStore
    var dark: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Button { terminals.showsLog = false } label: { Label("终端", systemImage: "terminal").foregroundStyle(terminals.showsLog ? .secondary : .primary) }.buttonStyle(.plain)
                Button { terminals.showsLog = true } label: { Label("任务日志", systemImage: "doc.text").foregroundStyle(terminals.showsLog ? .primary : .secondary) }.buttonStyle(.plain)
                if !terminals.showsLog {
                    Picker("会话", selection: $terminals.selectedID) { ForEach(terminals.sessions) { Text($0.name + ($0.ended ? " · 已结束" : "")).tag(Optional($0.id)) } }.labelsHidden().frame(maxWidth: 220)
                }
                Spacer()
                Menu("新会话") {
                    Button("本机终端") { terminals.open(employee: nil, tool: nil, directory: store.currentProject?.directory ?? FileManager.default.homeDirectoryForCurrentUser.path) }
                    ForEach(terminals.recent) { bookmark in
                        Button(bookmark.name + " · " + (bookmark.directory as NSString).lastPathComponent) {
                            terminals.open(employee: bookmark.employeeID.flatMap { store.employee($0) }, tool: bookmark.toolID.flatMap { store.tool($0) }, directory: bookmark.directory)
                        }.disabled(bookmark.employeeID != nil && store.employee(bookmark.employeeID!) == nil || bookmark.toolID != nil && store.tool(bookmark.toolID!) == nil)
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                if !terminals.showsLog {
                    Button("中断 ⌃C") { terminals.selected?.interrupt() }.disabled(terminals.selected?.ended != false)
                    Button("结束会话") { terminals.endSelected() }.disabled(terminals.selected?.ended != false)
                }
                Button { terminals.isVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("收起面板，保留会话").accessibilityLabel("收起终端面板")
            }.font(.system(size: 11)).padding(.horizontal, 20).frame(height: 42)
            Divider()
            if terminals.showsLog {
                HStack {
                    Picker("任务", selection: $terminals.logTaskID) { Text("选择任务").tag(Optional<UUID>.none); ForEach(store.visibleTasks) { Text($0.title).tag(Optional($0.id)) } }
                if let id = terminals.logTaskID, store.activeRuns[id] != nil { Button("停止此任务") { store.cancel(id) } }
                }.font(.system(size: 11)).padding(.horizontal, 20).frame(height: 35)
                ReadOnlyTextView(text: store.visibleTasks.first { $0.id == terminals.logTaskID }?.log ?? "选择任务查看执行日志。", pointSize: 11).padding(10)
            } else if let session = terminals.selected {
                HStack {
                    Text("员工 \(session.name)  ·  工具 \(session.toolName)")
                    Text(session.directory).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let id = session.toolID, let tool = store.tool(id), !session.ended, !session.isLogin {
                        Button("启动 CLI") { session.launchCLI(tool) }
                    }
                    if session.ended { Text("会话已结束" + session.exitCode.map { " · 退出码 \($0)" }.orEmpty) }
                    else { Text("本机交互会话") }
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 30)
                EmbeddedTerminal(session: session, dark: dark).id(session.id).padding(.horizontal, 16)
            } else { Text("从员工档案打开终端。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Divider()
            HStack { Text("手动命令与任务执行分别管理"); Spacer(); Text("关闭面板后保留当前会话") }.font(.system(size: 9)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 23)
        }.background(Theme.surface).overlay(alignment: .top) { Divider() }
    }
}

private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }

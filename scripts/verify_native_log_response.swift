import AppKit
import SwiftUI
import Foundation

private struct LiveTaskView: View {
    @ObservedObject var store: WorkbenchStore
    let taskID: UUID
    var body: some View {
        ScrollView {
            if let task = store.visibleTasks.first(where: { $0.id == taskID }) { TaskDetail(task: task, store: store).padding(22) }
        }.frame(width: 420, height: 800)
    }
}

@main struct NativeLogResponseVerification {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/log-response-qa/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        var tool = ToolConfig(name: "十万行日志响应检查", executable: "/bin/sh", arguments: ["-c", "/usr/bin/awk 'BEGIN { for (i=1;i<=100000;i++) print \"中文日志行 \" i; print \"__QA_100000_DONE__\"; }'; /bin/sleep 60"])
        tool.timeoutSeconds = 30; precondition(store.addTool(tool))
        let employee = Employee(name: "日志验证员", role: "本机验证", department: "开发部", instructions: "", toolID: tool.id)
        precondition(store.addEmployee(employee))
        let task = WorkTask(title: "十万行日志与停止响应", employeeID: employee.id, input: "本地确定性检查", workingDirectory: root.path, acceptance: "日志完整且主线程保持响应")
        precondition(store.addTask(task))
        let hosting = NSHostingView(rootView: LiveTaskView(store: store, taskID: task.id))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 420, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        defer { window.orderOut(nil) }
        store.run(task.id)
        let deadline = Date().addingTimeInterval(15)
        var last = Date(), maximumGap = 0.0, frames = 0
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded(); frames += 1
            if store.snapshot.tasks.first(where: { $0.id == task.id })!.log.contains("__QA_100000_DONE__") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
            let now = Date(); maximumGap = max(maximumGap, now.timeIntervalSince(last)); last = now
        }
        let running = store.snapshot.tasks.first { $0.id == task.id }!
        precondition(running.status == .running && running.log.contains("__QA_100000_DONE__"), "Generator did not finish before deadline")
        precondition(running.log.count <= 128000 && !running.log.contains("�"))
        let stopStarted = Date(); store.cancel(task.id)
        while store.activeRuns[task.id] != nil && Date().timeIntervalSince(stopStarted) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
        let stopSeconds = Date().timeIntervalSince(stopStarted)
        precondition(store.snapshot.tasks.first { $0.id == task.id }!.status == .cancelled)
        let run = store.runs(for: task.id)[0]
        let full = try String(contentsOf: URL(fileURLWithPath: run.logPath), encoding: .utf8)
        precondition(full.replacingOccurrences(of: "[stdout] ", with: "").components(separatedBy: "\n").filter { $0.hasPrefix("中文日志行 ") }.count == 100000)
        precondition(maximumGap < 1 && stopSeconds < 2, "Native component response exceeded acceptance threshold")
        let report: [String: Any] = ["passed": true, "lines": 100000, "layoutFrames": frames, "maximumMainActorGapSeconds": maximumGap, "stopCompletionSeconds": stopSeconds, "displayCharacters": running.log.count, "runID": run.id.uuidString, "workspace": root.path, "scope": "Live NSHostingView component and Store stop callback; human scrolling, keyboard, and VoiceOver remain unverified"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/native-log-response.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}

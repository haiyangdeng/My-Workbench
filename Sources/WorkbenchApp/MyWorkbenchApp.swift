import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: WorkbenchStore?
    var terminals: TerminalWorkspace?
    func applicationWillTerminate(_ notification: Notification) { store?.stopAllTunnels(); terminals?.endAll() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.runningID != nil || terminals?.activeCount ?? 0 > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "仍有任务或终端会话正在运行"
        alert.informativeText = "\(store?.activeRuns.count ?? 0) 项任务、\(store?.activeTurns.count ?? 0) 个对话回复、\(terminals?.activeCount ?? 0) 个终端会话。请先停止它们后再退出。"
        alert.addButton(withTitle: "返回工作台")
        alert.runModal()
        return .terminateCancel
    }
}

@main
struct MyWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = WorkbenchStore()
    @StateObject private var terminals = TerminalWorkspace(metadataURL: TerminalWorkspace.defaultMetadataURL)

    var body: some Scene {
        WindowGroup("Workbench") {
            WorkbenchView(terminals: terminals, store: store)
                // Buttons without a style of their own show the pointing hand too; AppKit controls get it from the monitor.
                .buttonStyle(.automaticPointer)
                .onAppear { delegate.store = store; delegate.terminals = terminals; PointerCursorMonitor.shared.install() }
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

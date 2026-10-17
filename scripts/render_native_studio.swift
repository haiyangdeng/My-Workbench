import AppKit
import SwiftUI

@MainActor func performRender() {

let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let isolatedURL = project.appendingPathComponent("work/studio-render/workspace.json")
try? FileManager.default.removeItem(at: isolatedURL)
let store = WorkbenchStore(fileURL: isolatedURL)
let hosting = NSHostingView(rootView: AnyView(WorkbenchView(store: store)))
let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = hosting
window.orderBack(nil)
func render(_ name: String, _ width: CGFloat, _ height: CGFloat, dark: Bool = false) {
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.setContentSize(NSSize(width: width, height: height))
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("Could not create bitmap") }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode PNG") }
    try! data.write(to: project.appendingPathComponent("work/studio-render/\(name).png"))
    print("Rendered \(name) \(width)×\(height)")
}
render("native-empty", 1440, 900)
store.addLocalExample()
render("native-configured", 1440, 900)
render("native-compact", 1100, 720)
render("native-dark", 1440, 900, dark: true)
let original = store.snapshot.employees[0]
let taskID = store.snapshot.tasks[0].id
let upload = project.appendingPathComponent("work/studio-render/upload-fixture.png")
try! Data(contentsOf: project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon-256-1x.png")).write(to: upload)
let photo = try! AvatarImageLoader.load(upload)
try! FileManager.default.removeItem(at: upload)
precondition(NSBitmapImageRep(data: photo)?.pixelsWide == 160, "Avatar should be a small thumbnail")
var edited = original
edited.name = "本地验证员 · 已配置"
edited.avatarImageData = photo
store.snapshot.tasks[0].employeeSnapshot = original
precondition(store.updateEmployee(edited), "Employee edit should save")
precondition(store.addEmployee(Employee(name: "Quinn", role: "测试工程师", department: "开发部", instructions: "复核结果", toolID: original.toolID, avatarSymbol: "cpu")), "Second employee should save")
let restored = WorkbenchStore(fileURL: isolatedURL)
precondition(restored.snapshot.employees.count == 2, "Same area should retain two employees")
precondition(restored.snapshot.tasks[0].id == taskID && restored.snapshot.tasks[0].employeeID == original.id, "Edit must preserve task identity")
precondition(restored.snapshot.tasks[0].employeeSnapshot == original, "Existing execution snapshot must remain unchanged")
precondition(restored.employee(original.id)?.avatarImageData == photo, "Avatar should survive source removal and reload")
hosting.rootView = AnyView(WorkbenchView(store: restored))
render("native-multiple-employees", 1100, 720)
hosting.rootView = AnyView(ConfigurationSheet(kind: .employee, store: restored, employeeToEdit: restored.employee(original.id)).background(Color(nsColor: .windowBackgroundColor)))
render("native-profile-config", 600, 660)
print("Native profile checks passed: edit, two employees, thumbnail, source independence, reload, task identity, execution snapshot")

let collaborationURL = project.appendingPathComponent("work/collaboration-qa/FF3D39BA-5D19-4BD4-B109-1142BF948B9C/workspace.sqlite")
if FileManager.default.fileExists(atPath: collaborationURL.path) {
    let collaborationStore = WorkbenchStore(fileURL: collaborationURL)
    hosting.rootView = AnyView(WorkbenchView(store: collaborationStore))
    render("native-real-collaboration", 1440, 900)
    hosting.rootView = AnyView(ScrollView { VStack(alignment: .leading, spacing: 15) { Text("项目协作记录").font(.title2); CollaborationPanel(store: collaborationStore, onTask: { _ in }) }.padding(25) }.background(Color(nsColor: .windowBackgroundColor)))
    render("native-collaboration-panel", 380, 620)
    let plan = collaborationStore.snapshot.plans[0]
    let productionTask = collaborationStore.snapshot.tasks.first { $0.id == plan.taskIDs[1] }!
    hosting.rootView = AnyView(ScrollView { TaskDetail(task: productionTask, store: collaborationStore).padding(25) }.background(Color(nsColor: .windowBackgroundColor)))
    render("native-delivery-detail", 440, 900)
    let planningTask = collaborationStore.snapshot.tasks.first { $0.purpose == .planning }!
    let draft = try! collaborationStore.planDraft(for: planningTask.id)
    hosting.rootView = AnyView(PlanApprovalSheet(draft: draft, planningTaskID: planningTask.id, projectID: plan.projectID, store: collaborationStore).background(Color(nsColor: .windowBackgroundColor)))
    render("native-plan-approval", 690, 680)
}
hosting.rootView = AnyView(RemoteToolConfigurationSheet(store: restored).background(Color(nsColor: .windowBackgroundColor)))
render("native-remote-config", 640, 690)
window.orderOut(nil)

}
MainActor.assumeIsolated { performRender() }

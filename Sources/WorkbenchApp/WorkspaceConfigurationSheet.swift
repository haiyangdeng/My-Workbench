import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0x708A73
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioStyle) private var style
    func makeBody(configuration: Configuration) -> some View {
        let pixel = colorScheme == .dark && style.isPixel
        return configuration.label.font(.system(size: 11, weight: pixel ? .bold : .medium)).padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.8))
            .background {
                if pixel {
                    PixelBlockBackground(fill: Theme.actionFill, radius: 8).opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.actionFill.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35))
                }
            }
            .pointerCursor(isEnabled)
    }
}

struct WorkspaceConfigurationSheet: View {
    @ObservedObject var store: WorkbenchStore
    var areaToEdit: WorkArea?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "sparkles"
    @State private var color = "708A73"
    @State private var description = ""
    private let icons = ["film", "waveform", "terminal", "paintpalette", "sparkles", "book", "megaphone", "chart.bar", "globe", "camera", "lightbulb", "leaf"]
    private let colors = ["B97255", "8D7D9A", "658398", "708A73", "B79758", "9A7B83"]
    private var valid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 40 && UInt32(color, radix: 16) != nil && color.count == 6 && store.storageAvailable && !store.workspaces.contains { $0.id != areaToEdit?.id && $0.name == trimmed }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(areaToEdit == nil ? "给新的伙伴，留一个位置。" : "让这个空间，更像你的工作室。").font(.system(size: 25, weight: .medium))
                    Text(areaToEdit == nil ? "添加工作区，再为它安排员工和任务。" : "名称和外观可以调整，员工与任务关联会保留。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plainPointer).accessibilityLabel("关闭工作区配置")
            }
            Divider()
            HStack(alignment: .top, spacing: 30) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        field("工作区名称") { TextField("例如：研究工作区", text: $name).textFieldStyle(.roundedBorder) }
                        field("用途说明") { TextField("这里的员工负责什么", text: $description, axis: .vertical).lineLimit(2...3).textFieldStyle(.roundedBorder) }
                        field("图标") {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(43), spacing: 8), count: 6), spacing: 8) {
                                ForEach(icons, id: \.self) { value in
                                    Button { icon = value } label: { Image(systemName: value).frame(width: 43, height: 39).background(Color(hex: color).opacity(icon == value ? 0.18 : 0.04), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: color).opacity(icon == value ? 0.8 : 0.12))) }.buttonStyle(.plainPointer).accessibilityLabel("图标 " + value).accessibilityValue(icon == value ? "已选择" : "未选择")
                                }
                            }
                        }
                        field("工作区主题色") {
                            HStack(spacing: 12) { ForEach(colors, id: \.self) { value in
                                Button { color = value } label: { Circle().fill(Color(hex: value)).frame(width: 31, height: 31).overlay { if color == value { Image(systemName: "checkmark").foregroundStyle(.white).font(.system(size: 11, weight: .bold)) } } }.buttonStyle(.plainPointer).accessibilityLabel("颜色 " + value)
                            } }
                            TextField("六位颜色值", text: $color).textFieldStyle(.roundedBorder).frame(width: 150).font(.system(size: 11, design: .monospaced))
                        }
                    }.padding(1)
                }.frame(width: 320)
                VStack(alignment: .leading, spacing: 15) {
                    Text("卡片预览").font(.system(size: 10)).tracking(1).foregroundStyle(.secondary)
                    preview
                    if let areaToEdit {
                        Text("\(store.employees(in: areaToEdit).count) 位员工和 \(store.tasks(in: areaToEdit).count) 项任务将继续留在这里。\n工具路径、项目目录和执行记录保持原有绑定。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
                    } else { Text("新工作区创建后，可以配置多位员工，每位员工单独设置头像、职责和 CLI。").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 340)
            Divider()
            HStack {
                Text(valid ? "设置将保存在本机。" : "名称需唯一，颜色为六位十六进制色值。").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(areaToEdit == nil ? "创建工作区" : "保存修改") { submit() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 760).background(Theme.paper).tint(Theme.blue)
        .onAppear { if let areaToEdit { name = areaToEdit.name; icon = areaToEdit.icon; color = areaToEdit.color; description = areaToEdit.description } }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.system(size: 12, weight: .medium)); content() }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color(hex: color)).frame(width: 42, height: 42).background(Color(hex: color).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) { Text(name.isEmpty ? "新的工作区" : name).font(.system(size: 16, weight: .semibold)).lineLimit(1); Text(description.isEmpty ? "让灵感在这里开始" : description).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
            }
            Divider()
            if let areaToEdit, !store.employees(in: areaToEdit).isEmpty {
                ForEach(store.employees(in: areaToEdit).prefix(3)) { member in HStack {
                    EmployeePortrait(symbol: member.avatarSymbol, imageData: member.avatarImageData, fallback: String(member.name.prefix(1)), tint: Color(hex: color)).frame(width: 33, height: 33)
                    VStack(alignment: .leading, spacing: 4) { Text(member.name); Text(member.role).foregroundStyle(.secondary) }.font(.system(size: 11)); Spacer()
                } }
            } else { Label("为这个空间安排第一位员工", systemImage: "person.badge.plus").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 10) }
            Divider()
            Text("＋ 添加员工                  新建任务 ↗").font(.system(size: 10)).foregroundStyle(Color(hex: color))
        }.padding(18).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: color).opacity(0.3)))
    }
    private func submit() {
        var area = areaToEdit ?? WorkArea(name: "")
        area.name = name.trimmingCharacters(in: .whitespacesAndNewlines); area.icon = icon; area.color = color.uppercased(); area.description = description
        if areaToEdit == nil ? store.addWorkspace(area) : store.updateWorkspace(area) { dismiss() }
    }
}

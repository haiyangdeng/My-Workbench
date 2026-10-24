import AppKit
import SwiftUI

enum StudioPage: String, CaseIterable, Identifiable {
    case home, employees, projects, tools, assets, knowledge, workflow, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .home: "我的工作室"
        case .employees: "AI 员工"
        case .projects: "项目"
        case .tools: "工具连接"
        case .assets: "素材库"
        case .knowledge: "知识库"
        case .workflow: "工作流"
        case .settings: "设置"
        }
    }
    var icon: String {
        switch self {
        case .home: "house"
        case .employees: "person.2"
        case .projects: "tray.full"
        case .tools: "point.3.connected.trianglepath.dotted"
        case .assets: "photo.on.rectangle.angled"
        case .knowledge: "books.vertical"
        case .workflow: "point.topleft.down.to.point.bottomright.curvepath"
        case .settings: "gearshape"
        }
    }
    var subtitle: String {
        switch self {
        case .home: "让每个想法，都有下一步。"
        case .employees: "找到合适的伙伴，一起把想法变成作品。"
        case .projects: "按分类整理所有项目，进入项目查看任务与产物。"
        case .tools: "连接你熟悉的 CLI 与制作服务。"
        case .assets: "每一份产物，都有可追溯的工作记录。"
        case .knowledge: "把员工职责、任务标准与验收经验留在工作室。"
        case .workflow: "安排分工、衔接任务，让协作有序发生。"
        case .settings: "为你的工作方式，留出合适的空间。"
        }
    }
}

/// Search box shared by the list pages: a quiet pill with a magnifier, readable in both themes.
struct StudioSearchField: View {
    @Environment(\.studioStyle) private var style
    var prompt: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.secondaryText) }
                    .buttonStyle(.plainPointer).help("清除搜索")
            }
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(Theme.input, in: StudioShape(15, pixel: style.isPixel))
        .overlay(StudioShape(15, pixel: style.isPixel).stroke(Theme.border, lineWidth: style.isPixel ? 2 : 1))
    }
}

enum StudioArtwork {
    static func index(for area: WorkArea) -> Int? { WorkArea.defaults.firstIndex { $0.id == area.id } }
    static func name(for area: WorkArea) -> String? {
        index(for: area).map { ["StudioVideo", "StudioAudio", "StudioCode", "StudioDesign"][$0] }
    }
    /// Module color. Default modules get a brighter variant in dark mode, matching the dark reference buttons.
    static func tint(for area: WorkArea) -> Color {
        if let index = index(for: area), area.color == WorkArea.defaults[index].color {
            return Theme.adaptive(["F76C2D", "6840E8", "2384FA", "3C8066"][index], ["F37A3A", "7D67EC", "3E8FF5", "3E9A7F"][index],
                                  pixel: ["FF9A1F", "A66BFF", "29ADFF", "2BD46F"][index])
        }
        return Color(hex: area.color)
    }
    /// Each dark style has its own artwork ("StudioVideoDark", "StudioVideoPixel" …). Pixel falls back to the ink set,
    /// and without either the app draws a stand-in.
    static func styledName(_ base: String, style: StudioStyle) -> String? {
        let candidates = style.isPixel ? ["Pixel", "Dark"] : style.isDark ? ["Dark"] : []
        return candidates.map { base + $0 }.first(where: hasImage)
    }
    static func hasImage(_ name: String) -> Bool { NSImage(named: name) != nil }
    @MainActor private static var topColors: [String: Color] = [:]
    /// Average color of the artwork's top strip, so the space above a bottom-aligned picture blends into it.
    @MainActor static func topColor(of name: String, _ image: NSImage) -> Color {
        if let cached = topColors[name] { return cached }
        var color = Theme.paper
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let strip = cgImage.cropping(to: CGRect(x: 0, y: 0, width: cgImage.width, height: max(1, cgImage.height / 20))) {
            let columns = 24, rows = 2
            var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(strip, in: CGRect(x: 0, y: 0, width: columns, height: rows))
                return true
            }
            if drawn {
                var sum = [0.0, 0.0, 0.0]
                for index in stride(from: 0, to: pixels.count, by: 4) { for channel in 0..<3 { sum[channel] += Double(pixels[index + channel]) } }
                let count = Double(columns * rows) * 255
                color = Color(.sRGB, red: sum[0] / count, green: sum[1] / count, blue: sum[2] / count)
            }
        }
        topColors[name] = color
        return color
    }
    static func accent(for area: WorkArea) -> Color {
        let base = NSColor(tint(for: area))
        return Theme.adaptive(base, base.blended(withFraction: 0.38, of: .white) ?? base)
    }
    static func taskTitle(for area: WorkArea) -> String {
        guard let index = index(for: area), area.name == WorkArea.defaults[index].name else { return "新建任务" }
        return ["新建影像任务", "新建声音任务", "新建开发任务", "新建视觉任务"][index]
    }
    static func note(for area: WorkArea) -> String {
        index(for: area).map { ["把想象\n变成画面", "用声音\n创造更多可能", "用代码\n连接无限可能", "让创意\n看得见"][$0] } ?? "让想法\n在这里发生"
    }
}

struct StudioSidebar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioStyle) private var style
    private var pixel: Bool { style.isPixel }
    @Binding var page: StudioPage
    var reviewCount: Int
    var onNavigate: () -> Void
    var onTerminal: () -> Void
    var onManage: () -> Void
    var terminalCount: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                if let icon = style.icon {
                    Image(nsImage: icon).resizable().interpolation(pixel ? .none : .high).scaledToFit().frame(width: 38, height: 38)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workbench").font(.system(size: pixel ? 16 : 18, weight: pixel ? .heavy : .bold, design: pixel ? .monospaced : .default))
                    Text("A PERSONAL AI STUDIO").font(.system(size: pixel ? 5.6 : 6.2, weight: .medium, design: pixel ? .monospaced : .default)).tracking(pixel ? 0.6 : 1.25).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 17).padding(.top, 44).padding(.bottom, 32)
            VStack(spacing: 5) {
                ForEach(StudioPage.allCases) { item in
                    Button { page = item; onNavigate() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.icon).font(.system(size: 16, weight: page == item ? .semibold : .regular)).frame(width: 21)
                            Text(item.title).font(.system(size: 14, weight: page == item ? .semibold : .medium))
                            Spacer(minLength: 0)
                            if item == .projects && reviewCount > 0 { Text("\(reviewCount)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.blue) }
                        }.padding(.horizontal, 13).frame(height: 43).contentShape(RoundedRectangle(cornerRadius: 13))
                            .foregroundStyle(colorScheme == .dark ? (page == item ? Theme.primaryText : Color(hex: "C9D2DC")) : .primary)
                            .background(page == item ? (colorScheme == .dark ? Theme.raised.opacity(0.9) : Theme.surface.opacity(0.75)) : .clear, in: StudioShape(13, pixel: pixel))
                            .overlay(StudioShape(13, pixel: pixel).strokeBorder(page == item ? (pixel ? Theme.blue : colorScheme == .dark ? Color(hex: "6B7686") : .white.opacity(0.95)) : .clear, lineWidth: pixel || colorScheme != .dark ? 2 : 1.2))
                    }.buttonStyle(.plainPointer).accessibilityIdentifier("studio.nav." + item.rawValue)
                        .accessibilityAddTraits(page == item ? [.isSelected] : [])
                }
            }.padding(.horizontal, 13)
            Spacer(minLength: 24)
            VStack(spacing: 7) {
                Button(action: onManage) { Label("管理工作区", systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading) }
                Button(action: onTerminal) {
                    HStack { Label("终端", systemImage: "terminal"); Spacer(); if terminalCount > 0 { Text("\(terminalCount)") } }
                }.accessibilityIdentifier("open-terminal")
            }.buttonStyle(.plainPointer).font(.system(size: 11)).foregroundStyle(.secondary).padding(26)
            HStack(spacing: 6) { Circle().fill(Theme.blue).frame(width: 5, height: 5); Text("本地工作室 · 数据保存在本机") }.font(.system(size: 8)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 24)
        }.frame(width: 198).background(Theme.sidebar)
            .overlay(alignment: .trailing) { Rectangle().fill(colorScheme == .dark ? Theme.border.opacity(0.8) : .white.opacity(0.5)).frame(width: pixel ? 2 : 1) }
    }
}

struct StudioHero: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioStyle) private var style
    var height: CGFloat
    var width: CGFloat
    private var dark: Bool { colorScheme == .dark }
    private var pixel: Bool { dark && style.isPixel }
    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geometry in
                // Dark mode uses its own artwork, never the light image under a tint.
                if dark, let name = StudioArtwork.styledName("StudioHero", style: style), let art = NSImage(named: name), art.size.width > 0 {
                    // Fit the art's central band to the banner height and keep its focal object near 66% of the width,
                    // blending both ends into the canvas, so a wide hero never loses its centerpiece to cropping.
                    let size = geometry.size
                    let height = size.height / 0.72, width = height * art.size.width / art.size.height
                    let desired = size.width * 0.66 - width * 0.12
                    let x = width >= size.width ? min(width / 2, max(size.width - width / 2, desired)) : desired
                    // Crop more from the bottom than the top so the whole sphere stays inside the banner.
                    let y = height / 2 - (height - size.height) * 0.2
                    ZStack {
                        Theme.paper
                        Image(nsImage: art).resizable().frame(width: width, height: height).position(x: x, y: y)
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: width, height: height).position(x: x, y: y))
                    }.frame(width: size.width, height: size.height).clipped()
                } else if dark {
                    HeroDarkArt()
                } else {
                    Image("StudioHero").resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }.accessibilityHidden(true)
            if dark {
                LinearGradient(stops: [.init(color: Theme.paper.opacity(0.88), location: 0), .init(color: Theme.paper.opacity(0.55), location: 0.32), .init(color: .clear, location: 0.58)], startPoint: .leading, endPoint: .trailing)
            } else {
                LinearGradient(colors: [Color(hex: "EDF5FB").opacity(0.92), Color(hex: "EDF5FB").opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
            }
            VStack(alignment: .leading, spacing: height > 240 ? 10 : 7) {
                Text("我的 AI 工作室").font(.system(size: width > 1150 ? 39 : 32, weight: pixel ? .heavy : .bold)).tracking(1).foregroundStyle(dark ? Color(hex: "F4F7FB") : Color(hex: "111C27"))
                    .shadow(color: pixel ? Color(hex: "1D63D8") : .clear, radius: 0, x: 3, y: 3)
                Group {
                    if pixel {
                        Text("> Make room for ideas_").font(.system(size: width > 1150 ? 24 : 20, weight: .bold, design: .monospaced)).foregroundStyle(Color(hex: "5FD3FF"))
                    } else {
                        Text("Make room for ideas.").font(.custom("Georgia-Italic", size: width > 1150 ? 29 : 24)).foregroundStyle(dark ? Color(hex: "8FBCEB") : Color(hex: "366F69"))
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("一个人，也是一支团队。")
                    Text("接入工具、安排员工，把想法交给你的 AI 伙伴。")
                }.font(.system(size: width > 1150 ? 16 : 13)).foregroundStyle(dark ? Color(hex: "C7D0DA") : Color(hex: "465F78")).padding(.top, 10)
            }.padding(.leading, width > 1150 ? 51 : 30)
            if width > 1180 {
                Text("让 AI 成为\n你最好的伙伴。").font(pixel ? .system(size: 18, weight: .bold, design: .monospaced) : .custom("STKaiti", size: 23)).tracking(pixel ? 2 : 3).lineSpacing(pixel ? 7 : 9)
                    .foregroundStyle(dark ? Color(hex: "EEF3F8") : Color(hex: "385674"))
                    .shadow(color: pixel ? .black.opacity(0.8) : dark ? .black.opacity(0.6) : .clear, radius: pixel ? 0 : 4, x: pixel ? 2 : 0, y: pixel ? 2 : 0)
                    .pixelPlate(pixel, border: Theme.blue)
                    .rotationEffect(.degrees(pixel ? 0 : -8)).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 52).padding(.top, 63)
            }
        }.frame(height: height).overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, Theme.paper], startPoint: .top, endPoint: .bottom).frame(height: dark ? 44 : 35)
        }
    }
}

struct StudioWorkspaceCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioStyle) private var style
    var area: WorkArea
    var members: [Employee]
    var tasks: [WorkTask]
    var height: CGFloat
    var available: Bool
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onEmployee: (Employee) -> Void
    var onAddEmployee: () -> Void
    var onTask: (WorkTask) -> Void
    var onNewTask: () -> Void
    var onAssign: (UUID, UUID) -> Bool
    var projectCount: Int = 0
    var onProjects: () -> Void = {}
    var onEditEmployee: (Employee) -> Void = { _ in }
    var onRemoveEmployee: (Employee) -> Void = { _ in }
    var onDeleteEmployee: (Employee) -> Void = { _ in }
    var onDeleteWorkspace: () -> Void = {}
    var onAddExistingEmployee: () -> Void = {}
    private var tint: Color { StudioArtwork.tint(for: area) }
    private var accent: Color { StudioArtwork.accent(for: area) }
    private var dark: Bool { colorScheme == .dark }
    private var pixel: Bool { dark && style.isPixel }
    private var currentTasks: [WorkTask] {
        let active = tasks.filter { ![WorkStatus.completed, .cancelled].contains($0.status) }
        return Array((active + tasks.filter { [.completed, .cancelled].contains($0.status) }).prefix(3))
    }
    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 570
            HStack(spacing: 0) {
                illustration(narrow: narrow).frame(width: geometry.size.width * (narrow ? 0.50 : 0.55))
                if dark { Rectangle().fill(Theme.border.opacity(0.9)).frame(width: pixel ? 2 : 1) }
                details(narrow: narrow)
                    .padding(.horizontal, narrow ? 15 : 22).padding(.vertical, height < 290 ? 19 : 23).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(dark ? Theme.surface : Theme.surface.opacity(0.84))
            }
        }.frame(height: height).background(dark ? Theme.surface : tint.opacity(0.035)).clipShape(StudioShape(dark ? 18 : 17, pixel: pixel))
            .overlay(StudioShape(dark ? 18 : 17, pixel: pixel).strokeBorder(dark ? Theme.border : tint.opacity(0.12), lineWidth: pixel ? 2 : 1))
            .studioShadow(pixel: pixel, color: dark ? .black.opacity(0.32) : tint.opacity(0.075), radius: dark ? 18 : 12, y: dark ? 8 : 5)
            .contextMenu { Button("查看工作区", action: onOpen); Button("编辑工作区", action: onEdit); Button("新增员工", action: onAddEmployee).disabled(!available); Button("添加已有员工", action: onAddExistingEmployee).disabled(!available); Divider(); Button("删除工作区", role: .destructive, action: onDeleteWorkspace).disabled(!available) }
    }
    private func details(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("我的 AI 员工").font(.system(size: 12, weight: .semibold)).foregroundStyle(dark ? Theme.primaryText : .primary)
                Spacer()
                Menu { Button("新增员工", action: onAddEmployee); Button("添加已有员工", action: onAddExistingEmployee) } label: { Image(systemName: "plus").font(.system(size: 10)) }.menuStyle(.borderlessButton).frame(width: 18).help("添加员工").disabled(!available)
            }
            memberStrip(narrow: narrow).frame(height: 40, alignment: .leading).padding(.top, 7)
            HStack {
                Text("工作区任务").font(.system(size: 12, weight: .semibold)).foregroundStyle(dark ? Theme.primaryText : .primary)
                Spacer()
                if projectCount > 0 { Button(action: onProjects) { Text("\(projectCount) 个项目 ›").font(.system(size: 10)) }.buttonStyle(.plainPointer).foregroundStyle(accent).help("查看用到这个工作区的所有项目").accessibilityIdentifier("home.projects." + area.id.uuidString) }
            }.padding(.top, narrow ? 15 : 20).padding(.bottom, 9)
            taskList(narrow: narrow)
            Spacer(minLength: 12)
            createButton(narrow: narrow)
        }
    }
    private func memberStrip(narrow: Bool) -> some View {
        HStack(spacing: narrow ? 5 : 7) {
            ForEach(Array(members.prefix(3))) { employee in
                Button { onEmployee(employee) } label: {
                    EmployeePortrait(symbol: employee.avatarSymbol, imageData: employee.avatarImageData, fallback: String(employee.name.prefix(1)), tint: accent).frame(width: narrow ? 27 : 33, height: narrow ? 27 : 33)
                }.buttonStyle(.plainPointer).help(employee.name + " · " + employee.role).accessibilityLabel("查看员工 " + employee.name)
                    .contextMenu {
                        Button("查看员工档案") { onEmployee(employee) }
                        Button("编辑员工") { onEditEmployee(employee) }
                        Button("移出当前工作区") { onRemoveEmployee(employee) }
                        Button("删除员工", role: .destructive) { onDeleteEmployee(employee) }
                    }
                    .dropDestination(for: String.self) { values, _ in
                        guard let value = values.first, let taskID = UUID(uuidString: value) else { return false }
                        return onAssign(taskID, employee.id)
                    }
            }
            if members.isEmpty {
                Button(action: onAddEmployee) { Label("安排第一位伙伴", systemImage: "person.badge.plus").font(.system(size: 10)) }.buttonStyle(.plainPointer).disabled(!available)
            } else {
                Text("\(members.count) 位员工").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
    private func taskList(narrow: Bool) -> some View {
        VStack(spacing: 7) {
            ForEach(currentTasks) { task in
                Button { onTask(task) } label: {
                    HStack(spacing: dark ? 7 : 5) {
                        Image(systemName: task.status == .completed ? "checkmark.square" : "doc.text").font(.system(size: dark ? 11 : 10)).foregroundStyle(accent)
                        Text(task.title).font(.system(size: narrow ? 10 : 11)).foregroundStyle(dark ? Theme.primaryText : .primary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(task.status.title).font(.system(size: 10)).foregroundStyle(dark ? Theme.secondaryText : .secondary)
                    }.padding(.horizontal, dark ? 9 : 6).frame(height: dark ? 28 : 23)
                        .background(dark ? AnyShapeStyle(Theme.raised) : AnyShapeStyle(tint.opacity(0.045)), in: StudioShape(dark ? 8 : 6, pixel: pixel))
                        .overlay(StudioShape(dark ? 8 : 6, pixel: pixel).fill(tint.opacity(dark ? 0.06 : 0)))
                }.buttonStyle(.plainPointer).draggable(task.status == .draft ? task.id.uuidString : "")
            }
            if currentTasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("灵感就绪，等你开始").font(.system(size: 11))
                    Text("创建任务后，在这里查看执行与验收状态。").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4)
                }.frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading).padding(.top, 3)
            }
        }
    }
    private func createButton(narrow: Bool) -> some View {
        let hasEnabledMember = members.contains { $0.enabled != false }
        return Button(action: hasEnabledMember ? onNewTask : onAddEmployee) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(hasEnabledMember ? StudioArtwork.taskTitle(for: area) : "添加 AI 员工")
            }
            .font(.system(size: narrow ? 11 : 12, weight: pixel ? .heavy : .semibold, design: pixel ? .monospaced : .default)).foregroundStyle(pixel ? Theme.pixelInk : .white)
            .frame(maxWidth: narrow ? .infinity : (dark ? 210 : 170)).frame(height: dark ? 42 : 39)
            .background {
                if pixel {
                    PixelBlockBackground(fill: tint)
                } else {
                    Capsule().fill(LinearGradient(colors: dark ? [accent, tint] : [tint, tint.opacity(0.88)], startPoint: dark ? .leading : .topLeading, endPoint: dark ? .trailing : .bottomTrailing))
                        .overlay(Capsule().stroke(dark ? Color.white.opacity(0.16) : .white.opacity(0.55)))
                }
            }
            .studioShadow(pixel: pixel, color: tint.opacity(dark ? 0.38 : 0.16), radius: dark ? 12 : 8, y: 4)
        }.buttonStyle(.plainPointer).disabled(!available).accessibilityIdentifier("create-task-" + area.id.uuidString)
    }
    private func illustration(narrow: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geometry in
                if dark, let base = StudioArtwork.name(for: area), let name = StudioArtwork.styledName(base, style: style), let art = NSImage(named: name), art.size.width > 0 {
                    // As in the dark reference: the art spans the card width and rests on the bottom edge, so the object
                    // sits below the title; the strip above fades into the art's own top color.
                    let size = geometry.size
                    let scale = max(size.width / art.size.width, size.height * 0.78 / art.size.height)
                    let width = art.size.width * scale, height = art.size.height * scale
                    ZStack {
                        StudioArtwork.topColor(of: name, art)
                        Image(nsImage: art).resizable().frame(width: width, height: height)
                            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28)], startPoint: .top, endPoint: .bottom))
                            // In wide cards, sink the art by a tenth: the cropped strip is reflective floor, and the object clears
                            // the title. Narrow cards are tall enough already, and their open button sits bottom left.
                            .position(x: size.width / 2, y: size.height - height / 2 + (size.height > size.width ? 0 : height * 0.10))
                    }.frame(width: size.width, height: size.height).clipped()
                } else if dark {
                    ModuleDarkArt(kind: .of(area), tint: tint)
                } else if let name = StudioArtwork.name(for: area) {
                    Image(name).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    LinearGradient(colors: [tint.opacity(0.06), tint.opacity(0.27), tint.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: area.icon).font(.system(size: 90, weight: .ultraLight)).foregroundStyle(tint.gradient).frame(width: geometry.size.width, height: geometry.size.height).offset(y: 30)
                }
            }.accessibilityHidden(true)
            if dark {
                // Only a light shade behind the title; the artwork stays vivid as in the reference.
                LinearGradient(colors: [Color.black.opacity(0.42), Color.black.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom).frame(height: 120)
            } else {
                LinearGradient(colors: [.white.opacity(0.58), .white.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom).frame(height: 126)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: narrow ? 8 : 13) {
                    Image(systemName: area.icon).font(.system(size: narrow ? 19 : 25, weight: .medium)).foregroundStyle(accent).frame(width: narrow ? 37 : 48, height: narrow ? 40 : 48)
                        .background(pixel ? Theme.paper.opacity(0.85) : tint.opacity(dark ? 0.30 : 0.18), in: StudioShape(dark ? 13 : 15, pixel: pixel))
                        .overlay(StudioShape(dark ? 13 : 15, pixel: pixel).stroke(dark ? tint.opacity(pixel ? 0.95 : 0.45) : .clear, lineWidth: pixel ? 2 : 1))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(area.name).font(.system(size: narrow ? 20 : 25, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(dark ? Color(hex: "F4F7FB") : Color(hex: "101C21"))
                            .shadow(color: dark ? .black.opacity(pixel ? 0.85 : 0.45) : .clear, radius: pixel ? 0 : 3, x: pixel ? 2 : 0, y: pixel ? 2 : 0)
                        Text(area.description).font(.system(size: narrow ? 10 : 12)).foregroundStyle(dark ? Color(hex: "C3CCD6") : Color(hex: "586B72")).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(StudioArtwork.note(for: area)).font(pixel ? .system(size: narrow ? 12 : 14, weight: .bold, design: .monospaced) : .custom("STKaiti", size: narrow ? 15 : 18)).tracking(pixel ? 1 : 2).lineSpacing(pixel ? 4 : 6).multilineTextAlignment(.center).foregroundStyle(dark ? Color(hex: "F4F7FB") : Color(hex: "304752"))
                        .shadow(color: dark ? .black.opacity(pixel ? 0.9 : 0.7) : .clear, radius: pixel ? 0 : 4, x: pixel ? 2 : 0, y: pixel ? 2 : 0)
                        .pixelPlate(pixel, border: tint)
                }.padding(.trailing, 3)
            }.padding(narrow ? 17 : 23)
            Button(action: onOpen) { Image(systemName: "arrow.right").font(.system(size: 16, weight: .medium)).foregroundStyle(dark ? Color.white : Color(hex: "243C43")).frame(width: 35, height: 35).background(dark ? Color.black.opacity(pixel ? 0.55 : 0.34) : .white.opacity(0.6), in: StudioShape(17.5, pixel: pixel)).overlay(StudioShape(17.5, pixel: pixel).stroke(pixel ? tint : dark ? Color.white.opacity(0.16) : .white.opacity(0.9), lineWidth: pixel ? 2 : 1)) }
                .buttonStyle(.plainPointer).help("打开" + area.name).accessibilityLabel("打开" + area.name).accessibilityIdentifier("studio.workspace." + area.id.uuidString).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: narrow ? .bottomLeading : .topTrailing).padding(narrow ? 15 : 23)
        }
    }
}

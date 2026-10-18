import AppKit
import AVFoundation
import SwiftUI
import SwiftTerm

// M8 media studio verification. Two local ComfyUI-compatible fixture servers (scripts/fixtures/comfy_media.py) return
// real PNG/MP4/WAV files made here; a Claude-like fixture CLI directs and reviews; an ffmpeg-like fixture joins files.
@main struct M8Verification {
    @MainActor static func wait(_ what: String, timeout: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        precondition(condition(), "Timed out waiting for: \(what)")
    }
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) { precondition(condition, message()) }

    static func startServer(media: URL, extra: [String] = []) throws -> (Process, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", FileManager.default.currentDirectoryPath + "/scripts/fixtures/comfy_media.py", media.path] + extra
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        var line = Data()
        while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte == Data("\n".utf8) { break }; line.append(byte) }
        return (process, String(decoding: line, as: UTF8.self))
    }
    static func report(_ url: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url + "/fixture/report")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func makePNG(_ url: URL, red: CGFloat) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<96 { for y in 0..<64 { rep.setColor(NSColor(deviceRed: red, green: CGFloat(x) / 96, blue: CGFloat(y) / 64, alpha: 1), atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
    static func makeMP4(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 96])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for frame in 0..<48 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(CVPixelBufferGetBytesPerRow(buffer!) * 96) { base[i] = UInt8((i + frame * 5) % 255) }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24))
        }
        input.markAsFinished(); await writer.finishWriting()
        check(writer.status == .completed, "MP4 written")
    }
    static func makeWAV(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!; buffer.frameLength = 44100
        for i in 0..<44100 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.5 * (Double(i) / 44100)) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        try file.write(from: buffer)
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = project.appendingPathComponent("work/m8-qa")
        let root = output.appendingPathComponent(UUID().uuidString)
        let media = root.appendingPathComponent("server media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var checks: [String] = []
        let limitations = [
            "The ComfyUI servers are local fixtures that return prepared files; no real model ran. A55 (a real cloud GPU run of an image, a video and an audio workflow) needs the user's server, workflows and budget.",
            "Snapshots are offscreen renders; playback controls, clicks and VoiceOver still need hands-on testing."
        ]
        try makePNG(media.appendingPathComponent("image.png"), red: 0.9)
        try await makeMP4(media.appendingPathComponent("clip.mp4"))
        try makeWAV(media.appendingPathComponent("tone.wav"))
        let reference = root.appendingPathComponent("ref photo.png"); try makePNG(reference, red: 0.2)

        let (server1, url1) = try startServer(media: media)
        let (server2, url2) = try startServer(media: media, extra: ["--no-jobs"])
        defer { server1.terminate(); server2.terminate() }

        // Fixture CLIs.
        func install(_ name: String, folder: String) throws -> URL {
            let dir = root.appendingPathComponent(folder); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(name.replacingOccurrences(of: ".py", with: ""))
            try FileManager.default.copyItem(at: project.appendingPathComponent("scripts/fixtures/" + name), to: target); check(chmod(target.path, 0o755) == 0, "chmod")
            return target
        }
        let claudeURL = try install("claude_like.py", folder: "claude cli"), ffmpegURL = try install("ffmpeg_like.py", folder: "ffmpeg cli")
        var director = ToolConfig(name: "Claude Code", executable: claudeURL.path, arguments: ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--session-id", "{session_id}"])
        director.resumeArguments = ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--resume", "{session_id}"]
        director.outputFormat = .streamJSON; director.includeInstructions = true; director.useLoginShellPath = true; director.timeoutSeconds = 60
        director.readOnlyArguments = ["--permission-mode", "plan"]; director.editArguments = ["--permission-mode", "acceptEdits"]
        director.structuredOutputArguments = ["--json-schema", "{schema}"]
        var ffmpeg = ToolConfig(name: "ffmpeg", executable: ffmpegURL.path, arguments: []); ffmpeg.commandStep = true; ffmpeg.timeoutSeconds = 60

        let database = root.appendingPathComponent("workspace.sqlite")
        let store = WorkbenchStore(fileURL: database)
        check(store.addTool(director) && store.addTool(ffmpeg), "Add CLIs")
        var directorAgent = Employee(name: "Director", role: "导演", department: "影像工作区", instructions: "Direct the production.", toolID: director.id)
        directorAgent.workspaceID = WorkArea.defaults[0].id; directorAgent.maxAccess = .readOnly
        check(store.addEmployee(directorAgent), "Add director")
        var teaser = WorkProject(name: "Launch teaser", directory: try store.defaultProjectDirectory(for: UUID()), goal: "20-second teaser")
        teaser.moduleIDs = [WorkArea.defaults[0].id, WorkArea.defaults[1].id]
        check(store.addProject(teaser), "Add media project")

        // ---- A48 servers and health ----
        let gpu = ComfyServer(name: "Fixture GPU", baseURL: url1, hourlyPrice: 3.6, currency: "CNY", jobLimit: 2, timeoutSeconds: 120)
        let old = ComfyServer(name: "Old server", baseURL: url2, timeoutSeconds: 60)
        check(store.saveServer(gpu, token: nil) && store.saveServer(old, token: nil), "Register two servers: \(store.errorMessage ?? "")")
        store.checkServer(gpu.id); store.checkServer(old.id)
        try await wait("health checks") { store.serverHealth[gpu.id] != nil && store.serverHealth[old.id] != nil }
        let health = store.serverHealth[gpu.id]!, oldHealth = store.serverHealth[old.id]!
        check(health.usable && health.gpu == "cuda:0 Fixture GPU" && health.vramTotal == 25769803776 && health.queueLength == 0 && health.version == "fixture-0.3", "Health shows version, GPU, VRAM and queue")
        check(!oldHealth.supportsJobCancel && !oldHealth.usable, "Server without single-job cancel is not usable")

        // ---- A49 templates, mapping, legacy {input} workflow ----
        func template(_ name: String, _ json: String, modules: [UUID], seconds: Double) throws -> WorkflowTemplate {
            let data = Data(json.utf8); let suggestion = WorkflowTemplate.suggest(for: data)
            let made = WorkflowTemplate(name: name, description: name + " fixture workflow", moduleIDs: modules, workflow: data, parameters: suggestion.parameters, outputs: suggestion.outputs, estimatedSeconds: seconds)
            check(store.saveTemplate(made), "Save template \(name): \(store.errorMessage ?? "")")
            return made
        }
        let t2i = try template("Keyframe t2i", #"{"3":{"class_type":"KSampler","inputs":{"seed":5,"steps":20}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"a cat"}},"10":{"class_type":"LoadImage","inputs":{"image":"ref.png"}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"wb"}}}"#, modules: [WorkArea.defaults[0].id, WorkArea.defaults[3].id], seconds: 60)
        var i2v = try template("Animate i2v", #"{"1":{"class_type":"LoadImage","inputs":{"image":"in.png"}},"2":{"class_type":"WanImageToVideo","inputs":{"length":33,"width":832}},"3":{"class_type":"KSampler","inputs":{"seed":1}},"4":{"class_type":"VHS_VideoCombine","inputs":{"frame_rate":24}}}"#, modules: [WorkArea.defaults[0].id], seconds: 120)
        check(Set(i2v.parameters.map(\.name)) == ["image", "frames", "seed"] && i2v.outputs.map(\.kind) == [.video], "i2v mapping suggested: \(i2v.parameters.map(\.name))")
        i2v.parameters[i2v.parameters.firstIndex { $0.name == "frames" }!].maximum = 81
        check(store.saveTemplate(i2v), "Edit i2v limits")
        var tts = WorkflowTemplate(name: "Voice tts", description: "text to speech", moduleIDs: [WorkArea.defaults[1].id], workflow: Data(#"{"1":{"class_type":"TTSNode","inputs":{"text":"hello","voice":"female"}},"2":{"class_type":"SaveAudio","inputs":{"filename_prefix":"wb"}}}"#.utf8), estimatedSeconds: 30)
        tts.parameters = [TemplateParameter(name: "text", nodeID: "1", inputName: "text", type: .text, description: "台词"), TemplateParameter(name: "voice", nodeID: "1", inputName: "voice", type: .choice, defaultValue: .string("female"), choices: ["female", "male"])]
        tts.outputs = WorkflowTemplate.suggest(for: tts.workflow).outputs
        check(store.saveTemplate(tts), "Save tts template")
        var legacy = ToolConfig(name: "Legacy Comfy", executable: "/usr/bin/true", arguments: []); legacy.adapter = .comfyUI
        legacy.remote = ComfyConnection(baseURL: url1, workflow: Data(#"{"1":{"class_type":"CLIPTextEncode","inputs":{"text":"photo of {input}, cinematic"}},"2":{"class_type":"SaveImage","inputs":{}}}"#.utf8), workflowName: "legacy.json")
        check(store.addTool(legacy), "Add legacy ComfyUI tool")
        let reloaded = WorkbenchStore(fileURL: database)
        let legacyTemplate = reloaded.snapshot.templates.first { $0.legacyToolID == legacy.id }
        check(legacyTemplate?.parameters.map(\.name) == ["input"] && reloaded.snapshot.servers.contains { $0.id == legacy.id }, "Legacy tool became a server and an {input} template")
        checks.append("A48 two servers registered; health showed version, GPU, VRAM and queue; the server without single-job cancel was reported unusable")

        // ---- A50 manual run with an uploaded image; seed recorded; same parameters reuse it ----
        let manual = store.submitGeneration(templateID: t2i.id, serverID: gpu.id, projectID: teaser.id, title: "Manual keyframe", values: ["prompt": "a fox in the snow", "seed": "random"], files: ["image": reference.path])!
        try await wait("manual run") { store.snapshot.tasks.first { $0.id == manual }?.status == .review }
        let manualTask = store.snapshot.tasks.first { $0.id == manual }!
        guard case .number(let seed) = manualTask.generation!.submittedValues!["seed"] else { preconditionFailure("seed recorded") }
        var serverReport = try await report(url1)
        let submitted = (serverReport["prompts"] as! [[String: Any]]).last!["workflow"] as! [String: [String: Any]]
        check(((submitted["6"]!["inputs"] as! [String: Any])["text"] as! String) == "a fox in the snow" && ((submitted["10"]!["inputs"] as! [String: Any])["image"] as! String) == "workbench/ref photo.png" && ((submitted["3"]!["inputs"] as! [String: Any])["seed"] as! Double) == seed, "Submitted workflow has the values, uploaded file and the concrete seed")
        check((serverReport["uploads"] as! [[String: Any]]).contains { $0["name"] as? String == "ref photo.png" }, "Reference uploaded")
        let manualRun = store.runs(for: manual).first!
        check(manualRun.remoteArtifacts?.allSatisfy { $0.localArtifactID != nil } == true && store.artifacts(for: manualRun.id).contains { $0.relativePath.hasSuffix("image.png") }, "Output downloaded into the run archive")
        store.accept(manual)
        let rerun = store.rerunGeneration(manual)!
        try await wait("rerun") { store.snapshot.tasks.first { $0.id == rerun }?.status == .review }
        check(store.snapshot.tasks.first { $0.id == rerun }!.generation!.submittedValues!["seed"] == .number(seed), "Rerun reused the recorded seed")
        serverReport = try await report(url1)
        check((serverReport["uploads"] as! [[String: Any]]).filter { $0["name"] as? String == "ref photo.png" }.count == 2, "Rerun uploaded the reference again")
        checks.append("A49 templates imported with suggested parameters and outputs, limits edited; a legacy {input} tool became a server and template")
        checks.append("A50 a manual run uploaded the reference image, submitted the mapped values with a concrete seed (\(Int64(seed))), downloaded the output, and a rerun reused the seed")

        // Old server: the job is refused before anything is submitted.
        let refused = store.submitGeneration(templateID: tts.id, serverID: old.id, projectID: teaser.id, title: "Refused", values: ["text": "hi"], files: [:])!
        try await wait("refused job") { store.snapshot.tasks.first { $0.id == refused }?.status == .failed }
        let oldReport = try await report(url2)
        check(!(oldReport["requests"] as! [[String]]).contains { $0[0] == "POST" && $0[1] == "/prompt" }, "Nothing posted to the server without single-job cancel")
        // Cancel by ID.
        let slow = store.submitGeneration(templateID: tts.id, serverID: gpu.id, projectID: teaser.id, title: "Slow", values: ["text": "SLOW take"], files: [:])!
        try await wait("slow job submitted") { store.runs(for: slow).first?.remotePromptID != nil }
        store.cancel(slow)
        try await wait("slow job cancelled") { store.snapshot.tasks.first { $0.id == slow }?.status == .cancelled }
        checks.append("A48 a job on the server without single-job cancel failed before submission; a running job was cancelled by its ID")

        // ---- A51 director plan; nothing submitted before approval ----
        let before = (try await report(url1)["prompts"] as! [[String: Any]]).count
        guard let conversation = store.sendMessage("DIRECTOR make a 20-second teaser from my photo", attachments: [reference.path], projectID: teaser.id, conversationID: nil, agentIDs: [directorAgent.id], mode: .director, access: .readOnly) else { preconditionFailure("director send: \(store.errorMessage ?? "")") }
        try await wait("production plan") { store.snapshot.messages(in: conversation).contains { $0.planDraft != nil } || store.snapshot.messages(in: conversation).contains { $0.state == .failed } }
        let planning = store.snapshot.messages(in: conversation).first { $0.planDraft != nil }
        check(planning != nil, "Director returned a valid production plan: \(store.snapshot.messages(in: conversation).compactMap(\.detail))")
        let draft = planning!.planDraft!
        check(draft.steps.map(\.stepKind) == [.agent, .generate, .generate, .generate, .command], "Plan has agent, generate and command steps")
        let estimate = store.productionEstimate(draft)
        let expected = draft.steps.filter { $0.stepKind == .generate }.compactMap { store.estimate(templateID: $0.templateID, serverID: $0.serverID).seconds }.reduce(0, +)
        check(estimate.unknown == 0 && estimate.seconds == expected && abs((estimate.cost ?? 0) - expected / 3600 * 3.6) < 0.0001, "Estimates: \(String(describing: estimate))")
        check((store.estimate(templateID: t2i.id, serverID: gpu.id).seconds ?? 60) < 60, "The keyframe estimate learned from earlier runs (MD-14)")
        check((try await report(url1)["prompts"] as! [[String: Any]]).count == before, "Nothing submitted before approval")
        checks.append(String(format: "A51 a director turned a video brief into a plan with agent, generate and command steps; estimates showed %.1f GPU minutes and about %.3f CNY, using learned runtimes where available; nothing was submitted before approval", (estimate.seconds ?? 0) / 60, estimate.cost ?? 0))

        // ---- A52 budget cap pauses submission; running job continues ----
        guard let planID = store.approveProductionPlan(messageID: planning!.id, draft: draft, budgetMinutes: 0.5, budgetCost: nil, directorReview: true, maximumReworks: 1) else { preconditionFailure("approve: \(store.errorMessage ?? "")") }
        func task(_ title: String) -> WorkTask { store.snapshot.tasks.first { $0.planID == planID && $0.title == title }! }
        try await wait("budget pause") { store.snapshot.plans.first { $0.id == planID }?.paused == true }
        let paused = store.snapshot.plans.first { $0.id == planID }!
        check(paused.pauseReason?.contains("GPU 时间预算") == true && task("Narration line").status == .queued, "Plan paused before the next job would exceed the cap: \(paused.pauseReason ?? "")")
        try await wait("running keyframe continues") { [.review, .completed].contains(task("Keyframe for shot 1").status) || store.snapshot.tasks.contains { $0.reviewSourceTaskID == task("Keyframe for shot 1").id } }
        checks.append("A52 the plan paused before the next job would exceed the 0.5-minute cap; the job already running continued")
        store.updateBudget(planID, minutes: 10, cost: nil)
        store.pausePlan(planID, paused: false)

        // ---- A53 director review: image rework with a new seed; video keyframes; audio metadata only ----
        try await wait("script step ready", timeout: 40) { task("Write the shot list").status == .review }
        store.accept(task("Write the shot list").id)
        try await wait("keyframe accepted after one rework", timeout: 60) { task("Keyframe for shot 1").status == .completed }
        let keyRuns = store.runs(for: task("Keyframe for shot 1").id)
        check(keyRuns.count == 2 && keyRuns[0].generation?.submittedValues?["seed"] == .number(1234), "Rework re-ran the keyframe with the director's seed 1234")
        try await wait("animation accepted", timeout: 60) { task("Animate shot 1").status == .completed }
        try await wait("narration accepted", timeout: 60) { task("Narration line").status == .completed }
        let reviews = store.snapshot.reviews.filter { review in store.snapshot.tasks.first { $0.id == review.sourceTaskID }?.planID == planID }
        let animRun = store.runs(for: task("Animate shot 1").id).first!
        let evidence = archiveFolder(store, animRun.id)
        let keyframes = (try? FileManager.default.contentsOfDirectory(atPath: evidence.path).filter { $0.contains("keyframe") }) ?? []
        check(keyframes.count == 4, "Four keyframes extracted for the video: \(keyframes)")
        let audioReviewTask = store.snapshot.tasks.first { $0.reviewSourceTaskID == task("Narration line").id }!
        check(audioReviewTask.input.contains("你无法听到声音") && audioReviewTask.workingDirectory.contains("/evidence/"), "Audio review got metadata only, in an evidence folder")
        check(reviews.map(\.decision.decision).filter { $0 == .rework }.count == 1 && reviews.contains { $0.decision.notes.contains("did not listen") }, "Review notes state the evidence: \(reviews.map(\.decision.notes))")
        checks.append("A53 the director reviewed the image file and asked for one rework with seed 1234 (new run, old kept); the video was judged from 4 extracted keyframes plus metadata; the audio review was marked as metadata only")

        // ---- Command step joins accepted files; wrap-up ----
        try await wait("join step", timeout: 40) { task("Join clip and narration").status == .review }
        let joinRun = store.runs(for: task("Join clip and narration").id).first!
        check(joinRun.arguments.contains { $0.hasSuffix("clip.mp4") } && joinRun.arguments.contains { $0.hasSuffix("tone.wav") } && joinRun.arguments.last!.hasSuffix("/output/final.mp4"), "Command step expanded {input:…} and {output}: \(joinRun.arguments)")
        check(store.artifacts(for: joinRun.id).contains { $0.relativePath.hasSuffix("final.mp4") }, "Joined file archived")
        store.accept(task("Join clip and narration").id)
        try await wait("wrap-up", timeout: 30) { store.snapshot.messages(in: conversation).contains { $0.turnKind == .wrapUp && $0.state == .replied } }
        let finalPlan = store.snapshot.plans.first { $0.id == planID }!
        check((finalPlan.spentSeconds ?? 0) > 0 && (finalPlan.spentCost ?? 0) > 0, "Spend recorded")
        checks.append("Command step: ffmpeg-like tool received the accepted clip and narration files and wrote final.mp4; the director posted a wrap-up")

        // ---- MD-12 lineage and A54 previews ----
        let keyArtifact = store.artifacts(for: keyRuns[0].id).first { $0.relativePath.hasSuffix(".png") }!
        check(keyRuns[0].remotePromptID != nil && keyRuns[0].generation?.versionHash == t2i.versionHash, "Asset history: template version, seed, server and prompt ID")
        let audioURL = try store.archive.url(for: store.artifacts(for: store.runs(for: task("Narration line").id).first!.id).first { $0.fileType == "wav" }!)
        let (levels, duration) = await MediaAnalysis.waveform(audioURL)
        check(levels.count > 50 && levels.contains { $0 > 0.2 } && abs(duration - 1) < 0.05, "Waveform computed: \(levels.count) bars, \(duration) s")
        _ = keyArtifact
        checks.append("A54 MD-12 previews: waveform read from the downloaded WAV (1.0 s); video keyframes and metadata read from the MP4; each output records template version, seed, server and prompt ID")

        // ---- Snapshots ----
        let suite = "MyWorkbench.M8.QA.\(UUID())"; let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("paper", forKey: "studioThemeV06")
        for name in ["StudioHero", "StudioVideo", "StudioAudio", "StudioCode", "StudioDesign"] {
            if let image = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/\(name).imageset/image.png")) { _ = image.setName(name) }
        }
        if let appIcon = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon-512-2x.png")) { _ = appIcon.setName("AppIcon") }
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminals.json"))
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        defer { window.orderOut(nil) }
        let shots = output.appendingPathComponent("snapshots"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        var screenshots: [String] = []
        func render(_ name: String, _ view: some View, width: CGFloat = 1440, height: CGFloat = 900) async throws {
            hosting.rootView = AnyView(view.defaultAppStorage(preferences).id(name))
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 1_200_000_000); hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png")); screenshots.append(name); print("Rendered \(name)")
        }
        let accent = SwiftUI.Color(red: 88/255, green: 115/255, blue: 94/255), paper = SwiftUI.Color(hex: "F5F8FA")
        try await render("m8-tools", WorkbenchView(terminals: terminals, initialPage: .tools, store: store), height: 1500)
        try await render("m8-template-sheet", TemplateSheet(store: store, templateToEdit: store.snapshot.template(t2i.id)).background(SwiftUI.Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light), width: 760, height: 780)
        try await render("m8-manual-run", ManualRunSheet(store: store, templateID: t2i.id).background(SwiftUI.Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light), width: 620, height: 720)
        try await render("m8-server-sheet", ServerSheet(store: store, serverToEdit: store.snapshot.server(gpu.id)).background(SwiftUI.Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light), width: 600, height: 720)
        try await render("m8-production-conversation", ConversationView(store: store, conversationID: conversation, accent: accent, onContinueInTerminal: { _ in }, onOpenTask: { _ in }, onReviewPlan: { _ in }).padding(20).background(paper), width: 980, height: 1500)
        try await render("m8-production-approval", ProductionApprovalSheet(store: store, turnID: planning!.id, draft: draft).background(SwiftUI.Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light), width: 760, height: 780)
        try await render("m8-assets", WorkbenchView(terminals: terminals, initialPage: .assets, store: store), height: 1400)
        try await render("m8-project", WorkbenchView(terminals: terminals, initialPage: .projects, initialProjectID: teaser.id, store: store))

        let report: [String: Any] = ["passed": true, "workspace": root.path, "checks": checks, "screenshots": screenshots.map { shots.appendingPathComponent($0 + ".png").path }, "limitations": limitations]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("m8-verification.json"))
        for line in checks { print("✓ " + line) }
        for line in limitations { print("! " + line) }
        print("M8 verification passed: \(checks.count) checks, \(screenshots.count) snapshots")
        terminals.endAll(); server1.terminate(); server2.terminate()
        exit(0)
    }

    @MainActor static func archiveFolder(_ store: WorkbenchStore, _ runID: UUID) -> URL { store.archive.root.appendingPathComponent("evidence/\(runID.uuidString)") }
}

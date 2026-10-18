import XCTest
@testable import WorkbenchCore

final class MediaTests: XCTestCase {
    static let workflow = Data(#"""
    {"3":{"class_type":"KSampler","inputs":{"seed":42,"steps":20,"model":["4",0]}},
     "5":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":512,"batch_size":1}},
     "6":{"class_type":"CLIPTextEncode","_meta":{"title":"Positive"},"inputs":{"text":"a cat","clip":["4",1]}},
     "7":{"class_type":"CLIPTextEncode","_meta":{"title":"Negative prompt"},"inputs":{"text":"blurry","clip":["4",1]}},
     "10":{"class_type":"LoadImage","inputs":{"image":"ref.png"}},
     "9":{"class_type":"SaveImage","inputs":{"images":["8",0],"filename_prefix":"wb"}}}
    """#.utf8)

    func testSuggestionMapsCommonNodesAndOutputs() throws {
        let suggestion = WorkflowTemplate.suggest(for: Self.workflow)
        let names = Dictionary(uniqueKeysWithValues: suggestion.parameters.map { ($0.name, $0) })
        XCTAssertEqual(names["prompt"]?.nodeID, "6"); XCTAssertEqual(names["negative_prompt"]?.nodeID, "7")
        XCTAssertEqual(names["seed"]?.type, .seed); XCTAssertEqual(names["image"]?.type, .image)
        XCTAssertEqual(names["width"]?.type, .integer); XCTAssertEqual(names["steps"]?.nodeID, "3")
        XCTAssertNil(names["model"], "Links to other nodes are never exposed")
        XCTAssertEqual(suggestion.outputs, [TemplateOutput(nodeID: "9", kind: .image)])
        XCTAssertFalse(WorkflowTemplate.candidateInputs(of: Self.workflow).contains { $0.inputName == "clip" })
    }

    func testNormalizeResolvesSeedsChecksLimitsAndRefusesUnknownNames() throws {
        var template = WorkflowTemplate(name: "t2i", workflow: Self.workflow, parameters: WorkflowTemplate.suggest(for: Self.workflow).parameters)
        template.parameters[template.parameters.firstIndex { $0.name == "width" }!].maximum = 2048
        try template.validateMapping()
        var values = try template.normalize(["prompt": .string("a fox"), "image": .string("workbench/ref.png"), "width": .number(1024)]) { 777 }
        XCTAssertEqual(values["seed"], .number(777), "A random seed becomes a concrete number before submission")
        XCTAssertEqual(values["height"], .number(512), "Unset values fall back to the workflow's own value")
        let resolved = try JSONDecoder().decode(JSONValue.self, from: template.resolve(values))
        XCTAssertEqual(resolved["6"]["inputs"]["text"], .string("a fox")); XCTAssertEqual(resolved["3"]["inputs"]["seed"], .number(777))
        XCTAssertEqual(resolved["10"]["inputs"]["image"], .string("workbench/ref.png")); XCTAssertEqual(resolved["3"]["inputs"]["model"], .array([.string("4"), .number(0)]))
        values["width"] = .number(4096)
        XCTAssertThrowsError(try template.normalize(values)) { XCTAssertEqual($0 as? MediaError, .outOfRange("width")) }
        XCTAssertThrowsError(try template.normalize(["unknown": .string("x")])) { XCTAssertEqual($0 as? MediaError, .unknownParameter("unknown")) }
        XCTAssertThrowsError(try template.normalize(["prompt": .number(3)]))
    }

    func testParsingByType() throws {
        let seed = TemplateParameter(name: "seed", nodeID: "3", inputName: "seed", type: .seed)
        XCTAssertEqual(try seed.parse("random"), .string("random")); XCTAssertEqual(try seed.parse("12"), .number(12))
        XCTAssertThrowsError(try seed.parse("-3"))
        let frames = TemplateParameter(name: "frames", nodeID: "5", inputName: "length", type: .integer)
        XCTAssertEqual(try frames.parse("49"), .number(49)); XCTAssertThrowsError(try frames.parse("4.5"))
        let style = TemplateParameter(name: "style", nodeID: "1", inputName: "s", type: .choice, choices: ["film", "anime"])
        XCTAssertEqual(try style.parse("anime"), .string("anime")); XCTAssertThrowsError(try style.parse("oil"))
        XCTAssertEqual(try TemplateParameter(name: "b", nodeID: "1", inputName: "b", type: .boolean).parse("是"), .bool(true))
    }

    func testMappingValidationCatchesBrokenTemplates() {
        var template = WorkflowTemplate(name: "t", workflow: Self.workflow, parameters: [TemplateParameter(name: "bad name", nodeID: "6", inputName: "text", type: .text)])
        XCTAssertThrowsError(try template.validateMapping())
        template.parameters = [TemplateParameter(name: "p", nodeID: "99", inputName: "text", type: .text)]
        XCTAssertThrowsError(try template.validateMapping())
        template.parameters = [TemplateParameter(name: "s", nodeID: "6", inputName: "text", type: .choice)]
        XCTAssertThrowsError(try template.validateMapping())
        XCTAssertThrowsError(try WorkflowTemplate.nodes(of: Data(#"{"nodes":[],"links":[]}"#.utf8)), "UI-format workflows are refused")
    }

    func testEstimateUsesMedianOfPastRunsThenUserEstimate() {
        var template = WorkflowTemplate(name: "t", workflow: Self.workflow, estimatedSeconds: 90)
        let server = UUID()
        XCTAssertEqual(template.estimate(on: server, history: []), 90)
        let task = WorkTask(title: "t", employeeID: UUID(), input: "", workingDirectory: "/tmp", acceptance: "a")
        let runs: [TaskRun] = [30.0, 50, 400].map { seconds in
            var run = TaskRun(task: task, employee: Employee(name: "e", role: "r", department: "d", instructions: "", toolID: UUID()), tool: ToolConfig(name: "t", executable: "/usr/bin/true", arguments: []), directory: URL(fileURLWithPath: "/tmp/x"))
            run.generation = GenerationSpec(templateID: template.id, serverID: server, versionHash: template.versionHash); run.status = .completed
            run.endedAt = run.startedAt.addingTimeInterval(seconds); return run
        }
        XCTAssertEqual(template.estimate(on: server, history: runs), 50)
        template.estimatedSeconds = nil
        XCTAssertNil(template.estimate(on: UUID(), history: runs))
    }

    func testProductionPlanConvertsAndValidates() throws {
        var snapshot = WorkspaceSnapshot()
        let cli = ToolConfig(name: "director", executable: "/usr/bin/true", arguments: ["{prompt}"])
        var ffmpeg = ToolConfig(name: "ffmpeg", executable: "/usr/bin/true", arguments: []); ffmpeg.commandStep = true
        let director = Employee(name: "Director", role: "导演", department: "", instructions: "", toolID: cli.id)
        let server = ComfyServer(name: "gpu-1", baseURL: "http://127.0.0.1:8188", hourlyPrice: 2.4, currency: "CNY")
        let template = WorkflowTemplate(name: "t2i", workflow: Self.workflow, parameters: WorkflowTemplate.suggest(for: Self.workflow).parameters, outputs: [TemplateOutput(nodeID: "9", kind: .image)])
        snapshot.tools = [cli, ffmpeg]; snapshot.employees = [director]; snapshot.servers = [server]; snapshot.templates = [template]
        func step(_ id: String, _ kind: String, deps: [String] = [], parameters: [NamedValue] = [], inputs: [NamedValue] = [], tool: String = "", arguments: [String] = []) -> ProductionPlanDTO.Step {
            .init(id: id, title: id, kind: kind, employeeID: director.id.uuidString, input: "do " + id, acceptance: "ok", dependencies: deps, access: "edit", templateID: kind == "generate" ? template.id.uuidString : "", serverID: kind == "generate" ? server.id.uuidString : "", parameters: parameters, inputs: inputs, toolID: tool, arguments: arguments)
        }
        let dto = ProductionPlanDTO(title: "Teaser", goal: "20s", steps: [
            step("script", "agent"),
            step("key1", "generate", deps: ["script"], parameters: [NamedValue(name: "prompt", value: "a city at dawn"), NamedValue(name: "seed", value: "random")], inputs: [NamedValue(name: "image", value: "attachment:0")]),
            step("join", "command", deps: ["key1"], tool: ffmpeg.id.uuidString, arguments: ["-i", "{input:key1}", "{output}/final.mp4"])
        ])
        let draft = try dto.toDraft(directorID: director.id)
        XCTAssertEqual(draft.steps.map(\.stepKind), [.agent, .generate, .command])
        XCTAssertEqual(draft.steps[1].access, .readOnly, "Generate steps never edit the project")
        try draft.validate(workspace: snapshot)
        try snapshot.validateProduction(draft, attachments: ["/tmp/ref.png"])
        XCTAssertThrowsError(try snapshot.validateProduction(draft, attachments: []), "attachment:0 must exist")
        var badParameter = draft; badParameter.steps[1].parameters = [NamedValue(name: "nope", value: "1")]
        XCTAssertThrowsError(try snapshot.validateProduction(badParameter, attachments: ["/tmp/ref.png"]))
        var badSource = draft; badSource.steps[1].inputs = [NamedValue(name: "image", value: "step:join")]
        XCTAssertThrowsError(try snapshot.validateProduction(badSource, attachments: ["/tmp/ref.png"]), "A source must be a dependency")
        var badCommand = draft; badCommand.steps[2].arguments = ["{input:script2}"]
        XCTAssertThrowsError(try snapshot.validateProduction(badCommand, attachments: ["/tmp/ref.png"]))
        snapshot.tools[1].commandStep = false
        XCTAssertThrowsError(try snapshot.validateProduction(draft, attachments: ["/tmp/ref.png"]), "Only CLIs marked for command steps may run them")
        XCTAssertEqual(server.estimatedCost(seconds: 1800), 1.2)
        let schema = try JSONDecoder().decode(JSONValue.self, from: CollaborationSchema.production(employeeIDs: [director.id], templateIDs: [template.id], serverIDs: [server.id], toolIDs: [ffmpeg.id]))
        XCTAssertEqual(schema["properties"]["steps"]["items"]["properties"]["templateID"]["enum"].array?.compactMap(\.string), [template.id.uuidString, ""])
        XCTAssertEqual(schema["properties"]["steps"]["items"]["additionalProperties"], .bool(false))
    }

    func testLegacyComfyToolBecomesServerAndTemplateOnce() throws {
        var snapshot = WorkspaceSnapshot()
        var tool = ToolConfig(name: "Old Comfy", executable: "/usr/bin/true", arguments: []); tool.adapter = .comfyUI
        tool.remote = ComfyConnection(baseURL: "http://127.0.0.1:8189", workflow: Data(#"{"1":{"class_type":"CLIPTextEncode","inputs":{"text":"photo of {input}, cinematic"}},"2":{"class_type":"SaveImage","inputs":{"images":["1",0]}}}"#.utf8), workflowName: "legacy.json", requiresAPIKey: true, ssh: SSHConnection(hostAlias: "gpu", localPort: 8189, remotePort: 8188))
        snapshot.tools = [tool]
        snapshot.migrateLegacyComfyTools(); snapshot.migrateLegacyComfyTools()
        XCTAssertEqual(snapshot.servers.count, 1); XCTAssertEqual(snapshot.templates.count, 1)
        XCTAssertEqual(snapshot.servers[0].id, tool.id, "Same ID so the Keychain token still matches")
        XCTAssertEqual(snapshot.servers[0].endpoint, "http://127.0.0.1:8189"); XCTAssertTrue(snapshot.servers[0].requiresToken)
        XCTAssertEqual(snapshot.templates[0].parameters.map(\.name), ["input"]); XCTAssertEqual(snapshot.templates[0].outputs.map(\.kind), [.image])
        let values = try snapshot.templates[0].normalize(["input": .string("hello")])
        let resolved = try JSONDecoder().decode(JSONValue.self, from: snapshot.templates[0].resolve(values))
        XCTAssertEqual(resolved["1"]["inputs"]["text"], .string("photo of hello, cinematic"), "An {input} workflow keeps the text around the placeholder")
    }
}

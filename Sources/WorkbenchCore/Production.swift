import Foundation

/// The director's production plan as the CLI returns it: a strict, string-only shape. `toDraft` turns it into plan steps.
public struct ProductionPlanDTO: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var kind: String
        public var employeeID: String
        public var input: String
        public var acceptance: String
        public var dependencies: [String]
        public var access: String
        public var templateID: String
        public var serverID: String
        public var parameters: [NamedValue]
        public var inputs: [NamedValue]
        public var toolID: String
        public var arguments: [String]
    }
    public var title: String
    public var goal: String
    public var steps: [Step]

    /// Generate and command steps are owned by the director; agent steps keep their agent.
    public func toDraft(directorID: UUID) throws -> PlanDraft {
        let steps = try self.steps.map { step -> PlanStep in
            guard let kind = StepKind(rawValue: step.kind) else { throw MediaError.invalidStep("步骤「\(step.title)」的类型未知") }
            let agent = kind == .agent ? UUID(uuidString: step.employeeID) : directorID
            guard let agent else { throw MediaError.invalidStep("步骤「\(step.title)」没有可用的员工") }
            var result = PlanStep(id: step.id, title: step.title, employeeID: agent, input: step.input.isEmpty ? step.title : step.input, acceptance: step.acceptance, dependencies: step.dependencies, access: AccessLevel(rawValue: step.access) ?? .readOnly)
            result.kind = kind
            if kind == .generate {
                result.templateID = UUID(uuidString: step.templateID); result.serverID = UUID(uuidString: step.serverID)
                result.parameters = step.parameters; result.inputs = step.inputs; result.access = .readOnly
            }
            if kind == .command { result.toolID = UUID(uuidString: step.toolID); result.arguments = step.arguments; result.access = .readOnly }
            return result
        }
        return PlanDraft(title: title, goal: goal, steps: steps)
    }
}

extension WorkspaceSnapshot {
    /// Checks the media-specific parts of a production plan; `PlanDraft.validate` covers ids, agents and cycles.
    /// `attachments` are the files the user attached to the request.
    public func validateProduction(_ draft: PlanDraft, attachments: [String]) throws {
        let ids = Dictionary(uniqueKeysWithValues: draft.steps.map { ($0.id, $0) })
        for step in draft.steps {
            switch step.stepKind {
            case .agent: continue
            case .generate:
                guard let template = template(step.templateID), !template.isDeleted else { throw MediaError.invalidStep("「\(step.title)」使用的模板不存在或已删除") }
                guard let server = server(step.serverID), server.enabled else { throw MediaError.invalidStep("「\(step.title)」使用的服务器不可用") }
                _ = server
                var provided: Set<String> = []
                for value in step.parameters ?? [] {
                    guard let parameter = template.parameter(value.name), !parameter.type.isFile else { throw MediaError.invalidStep("「\(step.title)」：模板「\(template.name)」没有参数 \(value.name)，或它是文件参数") }
                    _ = try parameter.normalize(parameter.parse(value.value)) { 0 }
                    provided.insert(value.name)
                }
                for input in step.inputs ?? [] {
                    guard let parameter = template.parameter(input.name), parameter.type.isFile else { throw MediaError.invalidStep("「\(step.title)」：\(input.name) 不是文件参数") }
                    try checkSource(input.value, step: step, ids: ids, attachments: attachments)
                    provided.insert(input.name)
                }
                if let missing = template.parameters.first(where: { $0.type.isFile && $0.defaultValue == nil && !provided.contains($0.name) }) {
                    throw MediaError.invalidStep("「\(step.title)」缺少文件参数 \(missing.name)")
                }
            case .command:
                guard let tool = tools.first(where: { $0.id == step.toolID }), tool.isCLI, tool.commandStep == true, tool.isEnabled else { throw MediaError.invalidStep("「\(step.title)」使用的命令工具不可用") }
                for argument in step.arguments ?? [] {
                    var rest = argument[...]
                    while let range = rest.range(of: "{input:") {
                        guard let close = rest[range.upperBound...].firstIndex(of: "}") else { break }
                        let source = String(rest[range.upperBound..<close])
                        guard step.dependencies.contains(source) else { throw MediaError.invalidStep("「\(step.title)」引用的 \(source) 不是它的前序步骤") }
                        rest = rest[rest.index(after: close)...]
                    }
                }
            }
        }
    }

    private func checkSource(_ source: String, step: PlanStep, ids: [String: PlanStep], attachments: [String]) throws {
        if source.hasPrefix("attachment:") {
            guard let index = Int(source.dropFirst("attachment:".count)), attachments.indices.contains(index) else { throw MediaError.invalidStep("「\(step.title)」引用的附件不存在") }
        } else if source.hasPrefix("step:") {
            let id = String(source.dropFirst("step:".count))
            guard ids[id] != nil, step.dependencies.contains(id) else { throw MediaError.invalidStep("「\(step.title)」引用的 \(id) 不是它的前序步骤") }
        } else { throw MediaError.invalidStep("「\(step.title)」的文件来源只能是 attachment:序号 或 step:步骤编号") }
    }
}

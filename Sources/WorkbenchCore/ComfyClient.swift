import Foundation

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public final class ComfyClient: @unchecked Sendable {
    private let connection: ComfyConnection
    private let baseURL: URL
    private let session: URLSession
    private let token: String?
    public init(connection: ComfyConnection, token: String? = nil, session: URLSession? = nil) throws {
        guard let components = URLComponents(string: connection.baseURL), let url = components.url,
              ["http", "https"].contains(components.scheme ?? ""), components.host != nil,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              connection.maximumDownloadBytes > 0 else { throw RemoteError.invalidConfiguration }
        baseURL = url; self.connection = connection; self.token = token
        if let session { self.session = session }
        else { let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; self.session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil) }
    }
    private func request(_ path: String, method: String = "GET", json: JSONValue? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.httpMethod = method
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("MyWorkbench", forHTTPHeaderField: "Comfy-Usage-Source")
        if let json { request.httpBody = try JSONEncoder().encode(json); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func json(_ request: URLRequest) async throws -> JSONValue {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RemoteError.malformedResponse }
        guard (200..<300).contains(response.statusCode) else { throw RemoteError.http(response.statusCode) }
        guard data.count <= 20 * 1024 * 1024 else { throw RemoteError.malformedResponse }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    public func checkConnection() async throws {
        _ = try await json(request("system_stats"))
    }
    /// Version, GPU and VRAM from system_stats, queue length, and whether single-job cancel exists (required to run jobs).
    public func health() async throws -> ServerHealth {
        let stats = try await json(request("system_stats"))
        var health = ServerHealth()
        health.version = stats["system"]["comfyui_version"].string
        if let device = stats["devices"].array?.first {
            health.gpu = device["name"].string
            if case .number(let total) = device["vram_total"] { health.vramTotal = Int64(total) }
            if case .number(let free) = device["vram_free"] { health.vramFree = Int64(free) }
        }
        if let queue = try? await json(request("queue")) { health.queueLength = (queue["queue_running"].array?.count ?? 0) + (queue["queue_pending"].array?.count ?? 0) }
        if let jobs = try? await json(request("api/jobs", query: [URLQueryItem(name: "limit", value: "1")])) { health.supportsJobCancel = jobs["jobs"].array != nil }
        if let info = try? await json(request("object_info")), let classes = info.object?.keys { health.nodeClasses = Set(classes) }
        return health
    }
    /// Uploads a local file to the server's input folder and returns the name a Load node expects ("subfolder/name").
    public func upload(_ file: URL, subfolder: String = "workbench", maximumBytes: Int64) async throws -> String {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WorkbenchError.unsafeArtifact }
        guard Int64(values.fileSize ?? 0) <= maximumBytes else { throw MediaError.uploadTooLarge }
        let boundary = "WorkbenchBoundary\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)) }
        field("subfolder", subfolder); field("type", "input"); field("overwrite", "false")
        let safeName = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file)); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var upload = try request("upload/image", method: "POST")
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); upload.httpBody = body
        let result = try await json(upload)
        guard let name = result["name"].string, !name.isEmpty else { throw RemoteError.malformedResponse }
        let folder = result["subfolder"].string ?? ""
        return folder.isEmpty ? name : folder + "/" + name
    }
    public func submit(input: String, promptID: UUID, willSubmit: (() async throws -> Void)? = nil) async throws -> String {
        let workflow = try connection.workflow(input: input)
        // Require the job API before submission; its cancellation is atomic and scoped to one id.
        let features = try await json(request("api/jobs", query: [URLQueryItem(name: "limit", value: "1")]))
        guard features["jobs"].array != nil else { throw RemoteError.unsafeCancellation }
        let body: JSONValue = .object(["prompt": workflow, "prompt_id": .string(promptID.uuidString.lowercased()), "client_id": .string(promptID.uuidString.lowercased())])
        try await willSubmit?()
        do {
            let result = try await json(request("prompt", method: "POST", json: body))
            guard let id = result["prompt_id"].string, UUID(uuidString: id) != nil else { throw RemoteError.malformedResponse }
            return id
        } catch let error as RemoteError { throw error }
        catch { throw RemoteError.ambiguousSubmission }
    }
    public func state(promptID: String) async throws -> RemoteJobState {
        guard UUID(uuidString: promptID) != nil else { throw RemoteError.invalidConfiguration }
        let history = try await json(request("history/\(promptID)"))
        if let record = history.object?[promptID] {
            let status = record["status"]
            if status["status_str"].string == "error" {
                let messages = try JSONEncoder().encode(status["messages"])
                return .failed(String(decoding: messages.prefix(6000), as: UTF8.self))
            }
            if status["completed"].boolean == true {
                var files: [RemoteArtifact] = []
                for node in record["outputs"].object?.values ?? Dictionary<String, JSONValue>().values {
                    for output in node.object?.values ?? Dictionary<String, JSONValue>().values {
                        for item in output.array ?? [] {
                            if let filename = item["filename"].string {
                                let type = item["type"].string ?? "output", folder = item["subfolder"].string ?? ""
                                if type == "output" || type == "temp" { files.append(RemoteArtifact(filename: filename, subfolder: folder, type: type)) }
                            }
                        }
                    }
                }
                return .success(files)
            }
        }
        let queue = try await json(request("queue"))
        func contains(_ key: String) -> Bool { (queue[key].array ?? []).contains { ($0.array?.dropFirst().first)?.string == promptID } }
        if contains("queue_running") { return .running }
        if contains("queue_pending") { return .pending }
        return .unknown
    }
    public func cancel(promptID: String) async throws -> Bool {
        guard UUID(uuidString: promptID) != nil else { throw RemoteError.invalidConfiguration }
        let result = try await json(request("api/jobs/\(promptID)/cancel", method: "POST", json: .object([:])))
        guard let dispatched = result["cancelled"].boolean else { throw RemoteError.malformedResponse }
        if !dispatched { return false }
        for _ in 0..<10 {
            let state = try await state(promptID: promptID)
            switch state {
            case .running, .pending: try await Task.sleep(nanoseconds: 500_000_000)
            case .success: return false
            case .failed, .unknown: return true
            }
        }
        throw RemoteError.unsafeCancellation
    }
    private func fileRequest(_ file: RemoteArtifact, method: String) throws -> URLRequest {
        guard !file.filename.isEmpty, file.filename != ".", file.filename != "..", !file.subfolder.contains("\\"), !file.filename.contains("/"), !file.filename.contains("\\"), !file.subfolder.split(separator: "/").contains(".."), !file.subfolder.hasPrefix("/"), ["output", "temp"].contains(file.type) else { throw WorkbenchError.unsafeArtifact }
        return try request("view", method: method, query: [URLQueryItem(name: "filename", value: file.filename), URLQueryItem(name: "subfolder", value: file.subfolder), URLQueryItem(name: "type", value: file.type)])
    }
    public func size(of file: RemoteArtifact) async throws -> Int64 {
        let (_, response) = try await session.data(for: fileRequest(file, method: "HEAD"))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw RemoteError.malformedResponse }
        guard response.expectedContentLength >= 0 else { throw RemoteError.downloadLimit }
        return response.expectedContentLength
    }
    public func download(_ file: RemoteArtifact) async throws -> URL {
        let size = try await size(of: file)
        guard size <= connection.maximumDownloadBytes else { throw RemoteError.downloadLimit }
        let (url, response) = try await session.download(for: fileRequest(file, method: "GET"))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { try? FileManager.default.removeItem(at: url); throw RemoteError.malformedResponse }
        let downloaded = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard Int64(downloaded) == size, Int64(downloaded) <= connection.maximumDownloadBytes else { try? FileManager.default.removeItem(at: url); throw RemoteError.sizeMismatch }
        return url
    }
}

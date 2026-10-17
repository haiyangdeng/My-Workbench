import XCTest
@testable import WorkbenchCore

private final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let callback = Self.handler; Self.lock.unlock()
        do {
            let (status, headers, data) = try callback!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class RemoteTests: XCTestCase {
    private func client(handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) throws -> ComfyClient {
        FixtureProtocol.lock.lock(); FixtureProtocol.handler = handler; FixtureProtocol.lock.unlock()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let workflow = Data(#"{"1":{"class_type":"Text","inputs":{"text":"{input}"}}}"#.utf8)
        return try ComfyClient(connection: ComfyConnection(baseURL: "http://localhost:8188", workflow: workflow, workflowName: "fixture", maximumDownloadBytes: 100), token: "fixture-token", session: URLSession(configuration: config))
    }
    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
        return result
    }
    private func response(_ json: String) -> (Int, [String: String], Data) { (200, ["Content-Type": "application/json"], Data(json.utf8)) }
    func testWorkflowReplacementKeepsJSONLiteralAndRejectsFrontendFormat() throws {
        let data = Data(#"{"1":{"class_type":"Text","inputs":{"text":"{input}","seed":42}}}"#.utf8)
        let configuration = ComfyConnection(baseURL: "http://localhost", workflow: data, workflowName: "fixture")
        let input = "引号\"; $(touch fixture)"
        let result = try configuration.workflow(input: input)
        XCTAssertEqual(result["1"]["inputs"]["text"].string, input)
        XCTAssertThrowsError(try ComfyConnection(baseURL: "http://localhost", workflow: Data(#"{"nodes":[]}"#.utf8), workflowName: "bad").workflow(input: ""))
    }
    func testSubmitUsesStableUUIDAndScopedCapabilities() async throws {
        let id = UUID(), expected = "中文\"; symbol"
        var prepared = false
        let api = try client { request in
            if request.url!.path == "/api/jobs" { return self.response(#"{"jobs":[]}"#) }
            XCTAssertEqual(request.url!.path, "/prompt"); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(prepared, "Execution id must be persisted before POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            let json = try JSONDecoder().decode(JSONValue.self, from: self.body(request))
            XCTAssertEqual(json["prompt_id"].string, id.uuidString.lowercased())
            XCTAssertEqual(json["prompt"]["1"]["inputs"]["text"].string, expected)
            return self.response("{\"prompt_id\":\"\(id.uuidString.lowercased())\"}")
        }
        let submitted = try await api.submit(input: expected, promptID: id) { prepared = true }
        XCTAssertEqual(submitted, id.uuidString.lowercased())
    }
    func testUnsupportedServerDoesNotCrossSubmissionBoundary() async throws {
        var prepared = false
        let api = try client { request in
            XCTAssertEqual(request.url!.path, "/api/jobs"); XCTAssertEqual(request.httpMethod, "GET")
            return self.response("{}")
        }
        do { _ = try await api.submit(input: "", promptID: UUID()) { prepared = true }; XCTFail("Expected unsupported API") }
        catch { XCTAssertEqual(error.localizedDescription, RemoteError.unsafeCancellation.localizedDescription) }
        XCTAssertFalse(prepared)
    }
    func testCancellationAtSubmissionBoundaryNeverPosts() async throws {
        let api = try client { request in
            XCTAssertEqual(request.url!.path, "/api/jobs"); XCTAssertEqual(request.httpMethod, "GET")
            return self.response(#"{"jobs":[]}"#)
        }
        do { _ = try await api.submit(input: "", promptID: UUID()) { throw CancellationError() }; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLostSubmissionResponseIsAmbiguous() async throws {
        let api = try client { request in if request.url!.path == "/api/jobs" { return self.response(#"{"jobs":[]}"#) }; throw URLError(.timedOut) }
        do { _ = try await api.submit(input: "", promptID: UUID()); XCTFail("Expected ambiguity") }
        catch { XCTAssertEqual(error.localizedDescription, RemoteError.ambiguousSubmission.localizedDescription) }
    }
    func testQueueAndHistoryRecoveryFindExactID() async throws {
        let id = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        let api = try client { request in
            if request.url!.path.hasPrefix("/history/") { return self.response("{}") }
            return self.response("{\"queue_running\":[[0,\"\(other)\",{}]],\"queue_pending\":[[1,\"\(id)\",{}]]}")
        }
        let pending = try await api.state(promptID: id); XCTAssertEqual(pending, .pending)
        let finished = try client { _ in self.response("{\"\(id)\":{\"status\":{\"completed\":true,\"status_str\":\"success\"},\"outputs\":{\"1\":{\"images\":[{\"filename\":\"中文.png\",\"subfolder\":\"project\",\"type\":\"output\"}]}}}}") }
        if case .success(let files) = try await finished.state(promptID: id) { XCTAssertEqual(files.count, 1); XCTAssertEqual(files[0].filename, "中文.png") } else { XCTFail("Expected files") }
    }
    func testScopedCancelConfirmsQueueRemovalWithoutGlobalInterrupt() async throws {
        let id = UUID().uuidString.lowercased()
        let api = try client { request in
            XCTAssertFalse(request.url!.path.contains("interrupt"))
            if request.httpMethod == "POST" { XCTAssertEqual(request.url!.path, "/api/jobs/\(id)/cancel"); return self.response(#"{"cancelled":true}"#) }
            if request.url!.path.hasPrefix("/history/") { return self.response("{}") }
            return self.response(#"{"queue_running":[],"queue_pending":[]}"#)
        }
        let cancelled = try await api.cancel(promptID: id); XCTAssertTrue(cancelled)
    }
    func testOldServerNeverFallsBackToGlobalInterrupt() async throws {
        let api = try client { request in XCTAssertFalse(request.url!.path.contains("interrupt")); return (404, [:], Data()) }
        do { _ = try await api.cancel(promptID: UUID().uuidString); XCTFail("Expected unsupported API") }
        catch { XCTAssertTrue(error is RemoteError) }
    }
    func testDownloadLimitCheckedBeforeGETAndRejectsUnsafePaths() async throws {
        let api = try client { request in XCTAssertEqual(request.httpMethod, "HEAD"); return (200, ["Content-Length": "101"], Data()) }
        do { _ = try await api.download(RemoteArtifact(filename: "large.mp4", subfolder: "", type: "output")); XCTFail("Expected limit") }
        catch { XCTAssertEqual(error.localizedDescription, RemoteError.downloadLimit.localizedDescription) }
        do { _ = try await api.size(of: RemoteArtifact(filename: "../escape", subfolder: "", type: "output")); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error is WorkbenchError) }
    }
    func testSSHUsesLoopbackAndRejectsOptionInjection() throws {
        let args = try SSHConnection(hostAlias: "gpu-production", localPort: 8189).arguments()
        XCTAssertTrue(args.contains("127.0.0.1:8189:127.0.0.1:8188")); XCTAssertTrue(args.contains("StrictHostKeyChecking=yes")); XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertThrowsError(try SSHConnection(hostAlias: "-oProxyCommand=bad").arguments())
        XCTAssertThrowsError(try SSHConnection(hostAlias: "server; command").arguments())
    }
}

import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let cancelled: Bool
    public let timedOut: Bool
    public init(exitCode: Int32, cancelled: Bool, timedOut: Bool = false) {
        self.exitCode = exitCode; self.cancelled = cancelled; self.timedOut = timedOut
    }
    public var status: WorkStatus { timedOut ? .timedOut : (cancelled ? .cancelled : (exitCode == 0 ? .review : .failed)) }
}

public struct LogChunk: Sendable {
    public enum Stream: String, Sendable { case stdout, stderr }
    public let stream: Stream
    public let text: String
    public init(stream: Stream, text: String) { self.stream = stream; self.text = text }
}

struct UTF8StreamDecoder {
    private var pending = Data()

    mutating func append(_ data: Data, final: Bool = false) -> String {
        pending.append(data)
        var end = pending.count
        if !final, end > 0 {
            let bytes = [UInt8](pending)
            var start = end - 1
            while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
            let lead = bytes[start]
            let length = lead < 0x80 ? 1 : (lead & 0xE0 == 0xC0 ? 2 : (lead & 0xF0 == 0xE0 ? 3 : (lead & 0xF8 == 0xF0 ? 4 : 1)))
            if end - start < length { end = start }
        }
        let result = String(decoding: pending.prefix(end), as: UTF8.self)
        pending.removeFirst(end)
        return result
    }
}

// Each launch owns a fresh POSIX process group. Signals never target the app's group.
public final class ProcessRunner: @unchecked Sendable {
    private struct Active { var pid: pid_t; var cancelled = false; var timedOut = false }
    private let lock = NSLock()
    private var processes: [UUID: Active] = [:]
    private var preCancelled: Set<UUID> = []
    public init() {}

    public func cancel(id: UUID) {
        lock.lock()
        guard var active = processes[id] else { preCancelled.insert(id); lock.unlock(); return }
        active.cancelled = true; processes[id] = active
        kill(-active.pid, SIGTERM)
        lock.unlock()
        escalate(id: id, pid: active.pid)
    }
    private func timeout(id: UUID) {
        lock.lock()
        guard var active = processes[id], !active.cancelled else { lock.unlock(); return }
        active.timedOut = true; processes[id] = active
        kill(-active.pid, SIGTERM)
        lock.unlock()
        escalate(id: id, pid: active.pid)
    }
    private func escalate(id: UUID, pid: pid_t) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            self.lock.lock(); defer { self.lock.unlock() }
            if self.processes[id]?.pid == pid { kill(-pid, SIGKILL) }
        }
    }

    public func run(id: UUID, tool: ToolConfig, input: String, directory: String,
                    arguments: [String]? = nil, environment: [String: String] = [:],
                    onOutput: @escaping @Sendable (LogChunk) -> Void) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.execute(id: id, tool: tool, input: input, directory: directory, arguments: arguments, environment: environment, onOutput: onOutput)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func changeDirectory(_ actions: inout posix_spawn_file_actions_t?, _ directory: String) -> Int32 {
        if #available(macOS 26.0, *) { return posix_spawn_file_actions_addchdir(&actions, directory) }
        return posix_spawn_file_actions_addchdir_np(&actions, directory)
    }

    private func execute(id: UUID, tool: ToolConfig, input: String, directory: String, arguments: [String]?, environment: [String: String], onOutput: @escaping @Sendable (LogChunk) -> Void) throws -> ProcessResult {
        guard tool.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: tool.executable) else { throw WorkbenchError.invalidExecutable }
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { throw WorkbenchError.invalidDirectory }
        guard (arguments ?? tool.resolvedArguments(input: input)).allSatisfy({ !$0.contains("\0") }), environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw WorkbenchError.invalidArguments }
        var stdout: [Int32] = [0, 0], stderr: [Int32] = [0, 0]
        guard pipe(&stdout) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard pipe(&stderr) == 0 else { close(stdout[0]); close(stdout[1]); throw POSIXError(.EIO) }
        for fd in stdout + stderr { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var parentWriteOpen = true
        defer { if parentWriteOpen { close(stdout[1]); close(stderr[1]) } }
        // Readers own the read ends even if launch fails.
        let outHandle = FileHandle(fileDescriptor: stdout[0], closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: stderr[0], closeOnDealloc: true)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        let setup = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO),
            Self.changeDirectory(&actions, directory),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        ]
        if let failure = setup.first(where: { $0 != 0 }) { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        let argv = ([tool.executable] + (arguments ?? tool.resolvedArguments(input: input))).map { strdup($0) } + [nil]
        var inherited = ProcessInfo.processInfo.environment
        for (key, value) in environment { inherited[key] = value }
        let envp = inherited.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + envp { if let p { free(p) } } }
        var pid: pid_t = 0
        lock.lock()
        if preCancelled.remove(id) != nil { lock.unlock(); return ProcessResult(exitCode: 0, cancelled: true) }
        let code = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, tool.executable, &actions, &attributes, UnsafeMutablePointer(mutating: argvBuffer.baseAddress!), UnsafeMutablePointer(mutating: envBuffer.baseAddress!))
            }
        }
        if code == 0 { processes[id] = Active(pid: pid) }
        lock.unlock()
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        close(stdout[1]); close(stderr[1]); parentWriteOpen = false
        let timer = DispatchWorkItem { self.timeout(id: id) }
        DispatchQueue.global().asyncAfter(deadline: .now() + tool.timeout, execute: timer)
        let readers = DispatchGroup()
        for (handle, stream) in [(outHandle, LogChunk.Stream.stdout), (errHandle, .stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readers.leave(); try? handle.close() }
                var decoder = UTF8StreamDecoder()
                while true {
                    let bytes = handle.availableData
                    if bytes.isEmpty { break }
                    let text = decoder.append(bytes)
                    if !text.isEmpty { onOutput(LogChunk(stream: stream, text: text)) }
                }
                let tail = decoder.append(Data(), final: true)
                if !tail.isEmpty { onOutput(LogChunk(stream: stream, text: tail)) }
            }
        }
        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) == -1 && errno == EINTR {}
        // A CLI may exit while a child still holds a pipe. Finish owned descendants too.
        kill(-pid, SIGTERM); escalate(id: id, pid: pid)
        readers.wait(); timer.cancel()
        kill(-pid, SIGKILL)
        lock.lock(); let active = processes.removeValue(forKey: id); lock.unlock()
        let exitCode = (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
        return ProcessResult(exitCode: exitCode, cancelled: active?.cancelled ?? false, timedOut: active?.timedOut ?? false)
    }
}

import XCTest
import Darwin
import SwiftTerm

private final class PTYCapture: LocalProcessDelegate, TerminalDelegate {
    var output = Data()
    var completed = false
    var exit: Int32?
    var size = winsize(ws_row: 24, ws_col: 90, ws_xpixel: 0, ws_ypixel: 0)
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { completed = true; exit = exitCode }
    func dataReceived(slice: ArraySlice<UInt8>) { output.append(contentsOf: slice) }
    func getWindowSize() -> winsize { size }
    var text: String { String(decoding: output, as: UTF8.self) }
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class TerminalPTYTests: XCTestCase {
    @MainActor private func waitFor(_ condition: () -> Bool, seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "PTY did not reach expected state")
    }

    @MainActor func testRealPTYInputUnicodeANSIAndWorkingDirectory() async throws {
        let capture = PTYCapture(); let process = LocalProcess(delegate: capture, dispatchQueue: .main)
        defer { if process.running { process.terminate() } }
        process.startProcess(executable: "/bin/sh", args: ["-c", "test -t 0 && test -t 1 || exit 9; pwd; stty size; printf '\\033[32mREADY\\033[0m\\n'; IFS= read -r text; printf '%s\\n' \"$text\""], currentDirectory: "/tmp")
        try await waitFor { capture.text.contains("READY") }
        process.send(data: Array("中文输入 🙂\n".utf8)[...])
        try await waitFor { capture.completed }
        XCTAssertEqual(capture.exit, 0)
        XCTAssertTrue(capture.text.contains("24 90")); XCTAssertTrue(capture.text.contains("/tmp"))
        XCTAssertTrue(capture.text.contains("中文输入 🙂")); XCTAssertTrue(capture.text.contains("\u{1b}[32m"))
        let emulator = Terminal(delegate: capture)
        emulator.feed(byteArray: [UInt8](capture.output))
        let plain = (0..<24).compactMap { emulator.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { emulator.getCharacter(for: $0) }) }.joined(separator: "\n")
        XCTAssertTrue(plain.contains("READY")); XCTAssertTrue(plain.contains("中文输入 🙂")); XCTAssertFalse(plain.contains("\u{1b}[32m"))
    }

    @MainActor func testResizeAndControlCOnlyInterruptOwnedForegroundProcess() async throws {
        let capture = PTYCapture(); let process = LocalProcess(delegate: capture, dispatchQueue: .main)
        defer { if process.running { process.terminate() } }
        process.startProcess(executable: "/bin/sh", args: ["-c", "trap 'printf INTERRUPTED; exit 0' INT; printf READY; IFS= read -r text; stty size; printf WAITING; while :; do sleep 1; done"], currentDirectory: "/tmp")
        try await waitFor { capture.text.contains("READY") }
        var size = winsize(ws_row: 32, ws_col: 112, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(ioctl(process.childfd, TIOCSWINSZ, &size), 0)
        process.send(data: Array("resize\n".utf8)[...])
        try await waitFor { capture.text.contains("WAITING") }
        XCTAssertTrue(capture.text.contains("32 112"))
        process.send(data: [3][...])
        try await waitFor { capture.completed }
        XCTAssertTrue(capture.text.contains("INTERRUPTED")); XCTAssertEqual(capture.exit, 0)
        XCTAssertNotEqual(process.shellPid, getpgrp())
    }
}

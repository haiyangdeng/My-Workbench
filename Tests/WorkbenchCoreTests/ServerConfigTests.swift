import XCTest
@testable import WorkbenchCore

/// SSH settings for on-demand GPU servers (MD-01): every value is its own argv element and is checked before ssh runs.
final class ServerConfigTests: XCTestCase {
    func testKeyLoginArguments() throws {
        let ssh = SSHConnection(hostAlias: "connect.gpu.example", localPort: 8189, remotePort: 8188, user: "root", port: 23456, identityFile: "/Users/me/.ssh/id_gpu", hostKeyPolicy: .acceptNew)
        let tunnel = try ssh.arguments()
        XCTAssertEqual(Array(tunnel.prefix(6)), ["-N", "-T", "-L", "127.0.0.1:8189:127.0.0.1:8188", "-o", "ExitOnForwardFailure=yes"])
        XCTAssertEqual(tunnel.last, "connect.gpu.example")
        for pair in [["-o", "StrictHostKeyChecking=accept-new"], ["-o", "BatchMode=yes"], ["-p", "23456"], ["-i", "/Users/me/.ssh/id_gpu"], ["-o", "IdentitiesOnly=yes"], ["-l", "root"]] {
            XCTAssertTrue(tunnel.indices.contains { tunnel[$0] == pair[0] && $0 + 1 < tunnel.count && tunnel[$0 + 1] == pair[1] }, "\(pair) in \(tunnel)")
        }
        XCTAssertEqual(try ssh.probeArguments().suffix(2), ["connect.gpu.example", "true"])
        XCTAssertFalse(try ssh.probeArguments().contains("-L"))
    }

    func testPasswordLoginAndDefaults() throws {
        let password = try SSHConnection(hostAlias: "203.0.113.7", user: "root", usesPassword: true).arguments()
        XCTAssertTrue(password.contains("BatchMode=no")); XCTAssertFalse(password.contains("BatchMode=yes")); XCTAssertTrue(password.contains("NumberOfPasswordPrompts=1"))
        let alias = try SSHConnection(hostAlias: "my-gpu").arguments()
        XCTAssertTrue(alias.contains("StrictHostKeyChecking=yes"), "Existing servers keep strict host keys")
        XCTAssertFalse(alias.contains("-p") || alias.contains("-l") || alias.contains("-i"), "Unset values come from ~/.ssh/config")
        XCTAssertTrue(try SSHConnection(hostAlias: "jump", remoteHost: "10.0.0.5").arguments().contains("127.0.0.1:8189:10.0.0.5:8188"))
    }

    func testInvalidValuesAreRefused() {
        for ssh in [SSHConnection(hostAlias: "-oProxyCommand=evil"), SSHConnection(hostAlias: "host name"), SSHConnection(hostAlias: "ok", localPort: 80),
                    SSHConnection(hostAlias: "ok", user: "-l"), SSHConnection(hostAlias: "ok", user: "ro ot"), SSHConnection(hostAlias: "ok", port: 70000),
                    SSHConnection(hostAlias: "ok", identityFile: "relative/key"), SSHConnection(hostAlias: "ok", remoteHost: "-x")] {
            XCTAssertThrowsError(try ssh.arguments(), "\(ssh)")
        }
    }

    func testOldServerRecordsStillDecode() throws {
        let old = Data(#"{"hostAlias":"gpu","localPort":8189,"remotePort":8188}"#.utf8)
        let decoded = try JSONDecoder().decode(SSHConnection.self, from: old)
        XCTAssertEqual(decoded, SSHConnection(hostAlias: "gpu")); XCTAssertNil(decoded.hostKeyPolicy)
        let server = try JSONDecoder().decode(ComfyServer.self, from: try JSONEncoder().encode(ComfyServer(name: "A", baseURL: "http://127.0.0.1:8188")))
        XCTAssertNil(server.startCommand); XCTAssertNil(server.startupWaitSeconds)
    }

    func testSSHErrorsAreExplained() {
        XCTAssertTrue(SSHConnection.diagnose("root@h: Permission denied (publickey,password).").contains("认证失败"))
        XCTAssertTrue(SSHConnection.diagnose("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nHost key verification failed.").contains("主机密钥变了"))
        XCTAssertTrue(SSHConnection.diagnose("Host key verification failed.").contains("known_hosts"))
        XCTAssertTrue(SSHConnection.diagnose("ssh: connect to host h port 22: Connection refused").contains("还没有启动"))
        XCTAssertTrue(SSHConnection.diagnose("ssh: connect to host h port 22: Operation timed out").contains("超时"))
        XCTAssertTrue(SSHConnection.diagnose("bind [127.0.0.1]:8189: Address already in use").contains("占用"))
        XCTAssertTrue(SSHConnection.diagnose("channel 2: open failed: connect failed: Connection refused").contains("ComfyUI"))
        XCTAssertEqual(SSHConnection.diagnose("weird\nlast line\n"), "SSH 连接失败：last line")
    }
}

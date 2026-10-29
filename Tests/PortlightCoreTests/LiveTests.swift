import Foundation
import Darwin
import PortlightCore

final class LiveTests {
    final class Fixture {
        let directory: URL
        let process = Process()
        let ready: URL
        init(script: String, executable: String = "/usr/bin/python3", suffix: String = "py") throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("portlight-test-\(UUID().uuidString)")
            ready = directory.appendingPathComponent("ready")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: directory.appendingPathComponent("package.json"))
            let source = directory.appendingPathComponent("server.\(suffix)")
            try Data(script.utf8).write(to: source)
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [source.path]
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        func awaitReady() async throws -> Int {
            for _ in 0..<100 {
                if let text = try? String(contentsOf: ready, encoding: .utf8), let port = Int(text) { return port }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw PortlightError.unavailable("Test fixture did not start")
        }
        func cleanup() async {
            if process.isRunning { process.terminate() }
            // All fixtures self-expire, including the one which ignores SIGTERM.
            for _ in 0..<240 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    func requireLive() throws {
        guard ProcessInfo.processInfo.environment["PORTLIGHT_INTEGRATION"] == "1" else {
            throw SkipCheck("Set PORTLIGHT_INTEGRATION=1 to test only disposable local fixtures")
        }
        expectNotEqual(getuid(), 0)
    }
    func testLiveDiscoveryAndSIGTERMOnlyTouchesChosenListener() async throws {
        try requireLive()
        let script = """
        import socket, time
        s = socket.socket()
        s.bind(('127.0.0.1', 0))
        s.listen()
        open('ready','w').write(str(s.getsockname()[1]))
        time.sleep(12)
        """
        let target = try Fixture(script: script), survivor = try Fixture(script: script)
        do {
            let port = try await target.awaitReady()
            _ = try await survivor.awaitReady()
            let service = ServerService()
            let scan = try await service.scan()
            let server = try requireValue(scan.servers.first { $0.identity.pid == target.process.processIdentifier })
            expectEqual(server.ports, [port]); expectEqual(server.runtime, .python)
            expectEqual(URL(fileURLWithPath: server.cwd).resolvingSymlinksInPath().path, target.directory.resolvingSymlinksInPath().path)
            let result = try await service.stop([server])
            expectEqual(result.sent, [server.identity]); expectTrue(result.failures.isEmpty)
            try await Task.sleep(nanoseconds: 400_000_000)
            expectFalse(target.process.isRunning)
            expectTrue(survivor.process.isRunning)
            let after = try await service.scan()
            expectFalse(after.servers.contains { $0.id == server.id })
        } catch { await target.cleanup(); await survivor.cleanup(); throw error }
        await target.cleanup(); await survivor.cleanup()
    }
    func testBatchStopsExactlyTwoSelectedServers() async throws {
        try requireLive()
        let script = """
        import socket, time
        s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen()
        open('ready','w').write(str(s.getsockname()[1])); time.sleep(12)
        """
        let a = try Fixture(script: script), b = try Fixture(script: script), other = try Fixture(script: script)
        do {
            _ = try await a.awaitReady(); _ = try await b.awaitReady(); _ = try await other.awaitReady()
            let service = ServerService()
            let selectedPIDs = [a.process.processIdentifier, b.process.processIdentifier]
            let selection = try await service.scan().servers.filter { selectedPIDs.contains($0.identity.pid) }
            expectEqual(selection.count, 2)
            let result = try await service.stop(selection)
            expectEqual(result.sent.count, 2); expectTrue(result.failures.isEmpty)
            try await Task.sleep(nanoseconds: 300_000_000)
            expectFalse(a.process.isRunning); expectFalse(b.process.isRunning); expectTrue(other.process.isRunning)
        } catch { await a.cleanup(); await b.cleanup(); await other.cleanup(); throw error }
        await a.cleanup(); await b.cleanup(); await other.cleanup()
    }
    func testNodeChildMultiPortAndBatchSnapshot() async throws {
        try requireLive()
        guard let node = ProcessInfo.processInfo.environment["PORTLIGHT_TEST_NODE"] else {
            throw SkipCheck("Set PORTLIGHT_TEST_NODE to an installed node executable")
        }
        let parent = try Fixture(script: """
        const fs = require('node:fs'), cp = require('node:child_process');
        fs.writeFileSync('listener.js', `
          const net = require('node:net'), fs = require('node:fs');
          const a = net.createServer(), b = net.createServer();
          a.listen(0, '127.0.0.1', () => b.listen(0, '::1', () => {
            fs.writeFileSync('child-pid', String(process.pid));
            fs.writeFileSync('ready', String(a.address().port));
          }));
          setTimeout(() => process.exit(0), 12000);
        `);
        const child = cp.spawn(process.execPath, ['listener.js'], {stdio: 'ignore'});
        const finish = () => { child.kill('SIGTERM'); process.exit(0); };
        process.on('SIGTERM', finish); setTimeout(finish, 12000);
        """, executable: node, suffix: "js")
        do {
            let port = try await parent.awaitReady()
            let childPID = try requireValue(Int32(String(contentsOf: parent.directory.appendingPathComponent("child-pid"), encoding: .utf8)))
            let service = ServerService()
            let scan = try await service.scan()
            let server = try requireValue(scan.servers.first { $0.identity.pid == childPID })
            expectEqual(server.parentPID, parent.process.processIdentifier)
            expectEqual(server.runtime, .node); expectEqual(server.ports.count, 2)
            expectTrue(server.ports.contains(port))
            expectFalse(scan.servers.contains { $0.identity.pid == parent.process.processIdentifier })
            // Confirmation freezes this selection; the process started afterwards must survive.
            let later = try Fixture(script: """
            import socket, time
            s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen()
            open('ready','w').write(str(s.getsockname()[1])); time.sleep(12)
            """)
            do {
                _ = try await later.awaitReady()
                let result = try await service.stop([server])
                expectEqual(result.sent, [server.identity])
                try await Task.sleep(nanoseconds: 300_000_000)
                let after = try await service.scan()
                expectFalse(after.servers.contains { $0.id == server.id })
                expectTrue(parent.process.isRunning); expectTrue(later.process.isRunning)
                let stale = try await service.stop([server])
                expectEqual(stale.sent.count, 0); expectEqual(stale.skipped, 1)
            } catch { await later.cleanup(); throw error }
            await later.cleanup()
        } catch { await parent.cleanup(); throw error }
        await parent.cleanup()
    }
    func testIgnoringSIGTERMRemainsVisibleWithoutEscalation() async throws {
        try requireLive()
        let target = try Fixture(script: """
        import socket, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        s = socket.socket()
        s.bind(('127.0.0.1', 0))
        s.listen()
        open('ready','w').write(str(s.getsockname()[1]))
        time.sleep(7)
        """)
        do {
            _ = try await target.awaitReady()
            let service = ServerService()
            let scan = try await service.scan()
            let server = try requireValue(scan.servers.first { $0.identity.pid == target.process.processIdentifier })
            let result = try await service.stop([server])
            expectEqual(result.sent, [server.identity])
            try await Task.sleep(nanoseconds: 200_000_000)
            expectTrue(target.process.isRunning)
            let after = try await service.scan()
            expectTrue(after.servers.contains { $0.id == server.id })
        } catch { await target.cleanup(); throw error }
        await target.cleanup()
    }
    func testAttributionAndCategoryScope() async throws {
        try requireLive()
        let script = """
        import socket, time
        s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen()
        open('ready','w').write(str(s.getsockname()[1])); time.sleep(12)
        """
        let a = try Fixture(script: script), b = try Fixture(script: script)
        do {
            _ = try await a.awaitReady(); _ = try await b.awaitReady()
            let service = ServerService()
            let scan = try await service.scan()
            let first = try requireValue(scan.servers.first { $0.identity.pid == a.process.processIdentifier })
            let second = try requireValue(scan.servers.first { $0.identity.pid == b.process.processIdentifier })
            if ProcessInfo.processInfo.environment["PORTLIGHT_EXPECT_CODEX"] == "1" {
                expectEqual(first.category, .codex); expectTrue(first.sourceVerified)
            }
            let wrongCategory: ServerCategory = first.category == .codex ? .other : .codex
            let rejected = try await service.stop([first], category: wrongCategory)
            expectTrue(rejected.sent.isEmpty); expectEqual(rejected.skipped, 1)
            expectTrue(a.process.isRunning); expectNotNil(rejected.outcomes[first.id])
            a.process.terminate()
            try await Task.sleep(nanoseconds: 200_000_000)
            let partial = try await service.stop([first, second], category: second.category)
            expectEqual(partial.sent, [second.id]); expectEqual(partial.skipped, 1)
            expectEqual(partial.outcomes.count, 2)
            try await Task.sleep(nanoseconds: 200_000_000)
            expectFalse(b.process.isRunning)
        } catch { await a.cleanup(); await b.cleanup(); throw error }
        await a.cleanup(); await b.cleanup()
    }

}

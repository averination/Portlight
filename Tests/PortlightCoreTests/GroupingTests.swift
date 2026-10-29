import Foundation
import PortlightCore

final class GroupingTests {
    func testPersistentGroupingDoesNotVerifyProcessSource() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("portlight-groups-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"scripts\":{\"dev\":\"vite\"}}".utf8).write(to: folder.appendingPathComponent("package.json"))
        let fixture = DiscoveryTests()
        var server = try requireValue(fixture.classify(fixture.record(cwd: folder.path), root: folder.path))
        let archive = ProjectArchive(directory: directory.appendingPathComponent("store"))
        var projects = try await archive.remember([server])
        expectNil(projects.first?.savedCategory)
        expectEqual(server.grouped(using: projects).category, .other)
        // Only actually verified provenance creates automatic persistent history.
        server.attribution = .init(category: .codex, detail: "Verified test chain", verified: true)
        projects = try await archive.remember([server])
        expectEqual(projects.first?.observedCodex, true)
        server.attribution = nil
        let reopened = ProjectArchive(directory: directory.appendingPathComponent("store"))
        projects = try await reopened.all()
        var grouped = server.grouped(using: projects)
        expectEqual(grouped.category, .codex)
        expectFalse(grouped.sourceVerified)
        expectEqual(grouped.identity, server.identity)
        projects = try await reopened.setGroup(.other, path: folder.path)
        grouped = server.grouped(using: projects)
        expectEqual(grouped.category, .other)
        expectFalse(grouped.sourceVerified)
        server.attribution = .init(category: .codex, detail: "Verified again", verified: true)
        projects = try await reopened.remember([server])
        expectEqual(server.grouped(using: projects).category, .other, file: #file, line: #line)
        projects = try await reopened.setGroup(.automatic, path: folder.path)
        expectEqual(server.grouped(using: projects).category, .codex)
        expectEqual(projects.first?.groupChoice, .automatic)
        // Old archives decode without a new schema version or destructive migration.
        let old = ArchivedProject(name: "Old", path: folder.path)
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(ArchivedProject.self, from: data)
        expectNil(decoded.observedCodex); expectNil(decoded.savedCategory)
        expectEqual(decoded.groupChoice, .automatic)
        // A manual Codex choice is organization, never cryptographic provenance/history.
        _ = try await reopened.remove(try requireValue(projects.first?.id))
        _ = try await reopened.add(path: folder.path)
        projects = try await reopened.setGroup(.codex, path: folder.path)
        server.attribution = .init(category: .other, detail: "Unverified", verified: false)
        let manual = server.grouped(using: projects)
        expectEqual(manual.category, .codex); expectFalse(manual.sourceVerified)
        projects = try await reopened.remember([manual])
        expectNil(projects.first?.observedCodex)
        projects = try await reopened.setGroup(.automatic, path: folder.path)
        expectEqual(server.grouped(using: projects).category, .other)
        // Exact canonical folder only: a sibling with the same name is not classified.
        var different = server
        different.projectCategory = nil
        let sibling = ArchivedProject(name: "project", path: directory.appendingPathComponent("other/project").path)
        expectEqual(different.grouped(using: [sibling]).category, .other)
    }

    func testLiveManualGroupRevalidatedBeforeStop() async throws {
        let live = LiveTests(); try live.requireLive()
        let fixture = try LiveTests.Fixture(script: """
        import socket,time
        s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen()
        open('ready','w').write(str(s.getsockname()[1])); time.sleep(12)
        """)
        do {
            _ = try await fixture.awaitReady()
            let service = ServerService()
            var project = ArchivedProject(name: "Manual group", path: fixture.directory.path)
            project.groupOverride = .other
            await service.setProjectGroups([project])
            var server = try requireValue(try await service.scan().servers.first { $0.identity.pid == fixture.process.processIdentifier })
            expectEqual(server.category, .other)
            project.groupOverride = .codex
            await service.setProjectGroups([project])
            let stale = try await service.stop([server], category: .other)
            expectTrue(stale.sent.isEmpty); expectEqual(stale.skipped, 1)
            expectTrue(fixture.process.isRunning)
            server = try requireValue(try await service.scan().servers.first { $0.identity.pid == fixture.process.processIdentifier })
            expectEqual(server.category, .codex)
            let result = try await service.stop([server], category: .codex)
            expectEqual(result.sent, [server.id]); expectTrue(result.failures.isEmpty)
        } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }
}

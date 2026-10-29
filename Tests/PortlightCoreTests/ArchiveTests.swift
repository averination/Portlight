import Foundation
import Darwin
import PortlightCore

final class ArchiveTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portlight-archive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func manifest(_ directory: URL, scripts: [String: String], manager: String? = nil) throws {
        var object: [String: Any] = ["name": "portlight-fixture", "scripts": scripts]
        if let manager { object["packageManager"] = manager }
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("package.json"))
    }
    func testLaunchOutcomeDistinguishesStopsFromFailures() {
        func state(_ code: Int32?, signal: Int32? = nil, observed: Bool = false, stopped: Bool = false, running: Bool = false) -> LaunchState {
            LaunchState(projectID: UUID(), isRunning: running, startedAt: Date(), exitCode: code,
                        logURL: URL(fileURLWithPath: "/tmp/unused-portlight-test.log"),
                        terminationSignal: signal, observedServer: observed, stopRequested: stopped)
        }
        for observed in [false, true] {
            let direct = state(15, signal: SIGTERM, observed: observed)
            expectEqual(direct.phase, .stopped); expectFalse(direct.isFailure); expectEqual(direct.message, "Остановлен")
            for code: Int32 in [0, 143] {
                let stopped = state(code, observed: observed, stopped: true)
                expectEqual(stopped.phase, .stopped); expectFalse(stopped.isFailure)
            }
            for code: Int32 in [7, 15, 143] {
                let failure = state(code, observed: observed)
                expectEqual(failure.phase, observed ? .runtimeFailed : .launchFailed)
                expectTrue(failure.isFailure)
            }
            // A confirmed stop must not conceal an unrelated failure or a different fatal signal.
            expectTrue(state(7, observed: observed, stopped: true).isFailure)
            expectTrue(state(11, signal: SIGSEGV, observed: observed, stopped: true).isFailure)
        }
        expectEqual(state(nil, stopped: true, running: true).phase, .waitingForPort)
        expectFalse(state(nil, stopped: true, running: true).isFailure)
        expectEqual(state(0).phase, .completed)
    }
    func testRecipesChooseManagerAndOnlyServerTasks() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try manifest(root, scripts: ["dev": "vite", "build": "build", "test": "tests", "preview": "vite preview"], manager: "pnpm@10.0.0")
        expectEqual(ProjectCatalog.recipes(at: root.path).map(\.display), ["pnpm run dev", "pnpm run preview"])
        try manifest(root, scripts: ["start": "node server.js"])
        try Data().write(to: root.appendingPathComponent("bun.lock"))
        expectEqual(ProjectCatalog.recipes(at: root.path).first?.tool, .bun)
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        try Data("{\"tasks\":{\"dev\":\"deno run main.ts\",\"test\":\"deno test\"}}".utf8).write(to: root.appendingPathComponent("deno.json"))
        expectEqual(ProjectCatalog.recipes(at: root.path).map(\.display), ["deno task dev"])
    }
    func testArchiveSurvivesRestartDeduplicatesAndPreservesSelection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project's folder ; literal")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try manifest(project, scripts: ["dev": "node dev.js", "preview": "node preview.js"])
        let storage = root.appendingPathComponent("store")
        let archive = ProjectArchive(directory: storage)
        var entries = try await archive.add(path: project.path, name: "Портфолио")
        let id = try requireValue(entries.first?.id)
        entries = try await archive.select(.init(tool: .npm, task: "preview"), for: id)
        expectEqual(entries.first?.recipe?.task, "preview")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        _ = try await archive.add(path: link.path)
        let bookmarked = try await archive.add(folder: project)
        expectNotNil(bookmarked.first?.folderBookmark)
        let reopened = ProjectArchive(directory: storage)
        entries = try await reopened.all()
        expectEqual(entries.count, 1); expectEqual(entries.first?.name, "Портфолио")
        expectEqual(entries.first?.recipe?.display, "npm run preview")
        expectEqual(entries.first?.id, id)
        let permissions = try FileManager.default.attributesOfItem(atPath: storage.appendingPathComponent("projects.json").path)[.posixPermissions] as? Int
        expectEqual(permissions, 0o600)
        _ = try await reopened.remove(id)
        expectTrue(try await ProjectArchive(directory: storage).all().isEmpty)
        expectTrue(FileManager.default.fileExists(atPath: project.path))
    }
    func testCorruptArchiveAndMissingProjectFailWithoutOverwriting() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("not valid json".utf8)
        try original.write(to: root.appendingPathComponent("projects.json"))
        do { _ = try await ProjectArchive(directory: root).add(path: root.path); expectTrue(false, "Corrupt archive must fail") }
        catch { expectEqual(try Data(contentsOf: root.appendingPathComponent("projects.json")), original) }
        do { try ProjectCatalog.validate(.init(tool: .npm, task: "dev"), at: root.appendingPathComponent("missing").path); expectTrue(false) }
        catch { expectTrue(true) }
        try manifest(root, scripts: ["build": "echo build"])
        do { try ProjectCatalog.validate(.init(tool: .npm, task: "dev"), at: root.path); expectTrue(false, "Removed task must fail closed") }
        catch { expectTrue(true) }
    }
    func testLiveLaunchDiscoversPortAndRejectsDuplicate() async throws {
        guard ProcessInfo.processInfo.environment["PORTLIGHT_INTEGRATION"] == "1" else { throw SkipCheck("Live tests disabled") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Project's folder ; literal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest(folder, scripts: ["dev": "node server.cjs"])
        try Data("const net=require('node:net');let s=net.createServer();s.listen(0,'127.0.0.1',()=>console.log('fixture-ready'));setTimeout(()=>process.exit(0),12000);".utf8)
            .write(to: folder.appendingPathComponent("server.cjs"))
        let project = ArchivedProject(name: "Fixture", path: folder.path, recipe: .init(tool: .npm, task: "dev"),
                                      runtimeExecutable: ProcessInfo.processInfo.environment["PORTLIGHT_TEST_NODE"])
        let launcher = ProjectLauncher(logDirectory: root.appendingPathComponent("logs"))
        let service = ServerService()
        _ = try await launcher.start(project, activeServers: [])
        var found: Server?
        for _ in 0..<50 {
            let servers = try await service.scan().servers
            found = servers.first { ProjectCatalog.canonical($0.projectPath) == project.path }
            if found != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let server = try requireValue(found)
        expectEqual(server.runtime, .node); expectEqual(server.ports.count, 1)
        expectEqual(ProjectCatalog.canonical(server.cwd), project.path)
        do { _ = try await launcher.start(project, activeServers: []); expectTrue(false, "Running command must block duplicates") }
        catch { expectTrue(true) }
        let restoredLauncher = ProjectLauncher(logDirectory: root.appendingPathComponent("logs"))
        expectEqual(await restoredLauncher.states()[project.id]?.isRunning, true)
        do { _ = try await restoredLauncher.start(project, activeServers: []); expectTrue(false, "Receipt must block duplicates after an app restart") }
        catch { expectTrue(true) }
        let alias = ArchivedProject(name: "Same folder, new archive ID", path: project.path, recipe: project.recipe)
        do { _ = try await launcher.start(alias, activeServers: []); expectTrue(false, "Same path with a new ID must also block duplicates") }
        catch { expectTrue(true) }
        do { _ = try await ProjectLauncher(logDirectory: root.appendingPathComponent("logs2")).start(project, activeServers: [server]); expectTrue(false, "Existing server must block duplicates") }
        catch { expectTrue(true) }
        let archive = ProjectArchive(directory: root.appendingPathComponent("store"))
        var entries = try await archive.remember([server]); expectEqual(entries.count, 1)
        let entry = try requireValue(entries.first)
        expectNotNil(entry.lastSeen); expectEqual(entry.lastURL, server.url(for: server.ports[0]))
        _ = try await archive.remove(entry.id)
        entries = try await archive.remember([server]); expectTrue(entries.isEmpty, "Removed active project must not immediately reappear")
        let context = await launcher.prepareToStop([server])
        let result = try await service.stop([server]); expectEqual(result.sent, [server.id])
        await launcher.recordStop(context, sent: result.sent)
        for _ in 0..<30 {
            if await launcher.states()[project.id]?.isRunning == false { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        expectEqual(await launcher.states()[project.id]?.isRunning, false)
        expectEqual(await launcher.states()[project.id]?.phase, .stopped)
        expectEqual(await launcher.states()[project.id]?.isFailure, false)
    }
    func testLiveWrappedSIGTERMAndRestartFailure() async throws {
        guard ProcessInfo.processInfo.environment["PORTLIGHT_INTEGRATION"] == "1" else { throw SkipCheck("Live tests disabled") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try manifest(root, scripts: ["dev": "node server.cjs"])
        let script = """
        const fs=require('node:fs'), net=require('node:net');
        const server=net.createServer();
        server.listen(0,'127.0.0.1');
        process.on('SIGTERM',()=>process.exit(143));
        setInterval(()=>{if(fs.existsSync('fail-now'))process.exit(143)},50);
        setTimeout(()=>process.exit(0),12000);
        """
        try Data(script.utf8).write(to: root.appendingPathComponent("server.cjs"))
        let launcher = ProjectLauncher(logDirectory: root.appendingPathComponent("logs")), service = ServerService()
        let project = ArchivedProject(name: "Wrapped SIGTERM", path: root.path, recipe: .init(tool: .npm, task: "dev"),
                                      runtimeExecutable: ProcessInfo.processInfo.environment["PORTLIGHT_TEST_NODE"])
        func awaitServer() async throws -> Server {
            for _ in 0..<50 {
                if let server = try await service.scan().servers.first(where: { ProjectCatalog.canonical($0.projectPath) == project.path }) { return server }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw CheckError(message: "Wrapped fixture did not listen")
        }
        func awaitExit() async throws -> LaunchState {
            for _ in 0..<50 {
                if let state = await launcher.states()[project.id], !state.isRunning { return state }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw CheckError(message: "Wrapped fixture did not exit")
        }
        _ = try await launcher.start(project, activeServers: [])
        let server = try await awaitServer()
        let context = await launcher.prepareToStop([server])
        let result = try await service.stop([server])
        expectEqual(result.sent, [server.id])
        await launcher.recordStop(context, sent: result.sent)
        let stopped = try await awaitExit()
        expectEqual(stopped.exitCode, 143); expectEqual(stopped.phase, .stopped); expectFalse(stopped.isFailure)
        // A new run must not inherit the previous run's stop, even if an old callback arrives late.
        let restarted = try await launcher.start(project, activeServers: [])
        expectTrue(restarted.isRunning); expectEqual(restarted.phase, .waitingForPort)
        let nextServer = try await awaitServer()
        _ = await launcher.states(activeServers: [nextServer])
        await launcher.recordStop(context, sent: result.sent)
        try Data().write(to: root.appendingPathComponent("fail-now"))
        let failed = try await awaitExit()
        expectEqual(failed.exitCode, 143); expectEqual(failed.phase, .runtimeFailed); expectTrue(failed.isFailure)
        expectTrue(failed.message.contains("Сервер завершился с ошибкой"))
    }
    func testFailedLaunchReportsExitAndLog() async throws {
        guard ProcessInfo.processInfo.environment["PORTLIGHT_INTEGRATION"] == "1" else { throw SkipCheck("Live tests disabled") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try manifest(root, scripts: ["dev": "node -e \"console.error('fixture-error');process.exit(7)\""])
        let launcher = ProjectLauncher(logDirectory: root.appendingPathComponent("logs"))
        let project = ArchivedProject(name: "Failure", path: root.path, recipe: .init(tool: .npm, task: "dev"),
                                      runtimeExecutable: ProcessInfo.processInfo.environment["PORTLIGHT_TEST_NODE"])
        _ = try await launcher.start(project, activeServers: [])
        for _ in 0..<50 {
            if await launcher.states()[project.id]?.isRunning == false { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let state = try requireValue(await launcher.states()[project.id])
        expectFalse(state.isRunning); expectEqual(state.exitCode, 7)
        expectEqual(state.phase, .launchFailed); expectTrue(state.isFailure)
        expectTrue(try String(contentsOf: state.logURL, encoding: .utf8).contains("fixture-error"))
    }
}

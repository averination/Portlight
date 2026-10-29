import Foundation
import PortlightCore

final class PublicationTests {
    private final class Repository {
        let folder: URL
        let root: URL
        let remote: URL
        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("portlight-publication-test-\(UUID().uuidString)")
            root = folder.appendingPathComponent("Project's folder ; literal"); remote = folder.appendingPathComponent("production.git")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try git(["init", "--bare", remote.path])
            _ = try git(["init", "-b", "main"])
            _ = try git(["config", "user.name", "Portlight Fixture"])
            _ = try git(["config", "user.email", "fixture@example.invalid"])
            _ = try git(["config", "commit.gpgsign", "false"])
            _ = try git(["config", "core.hooksPath", "/dev/null"])
            try write("a.txt", "before\n"); try write("b.txt", "before\n")
            _ = try git(["add", "."]); _ = try git(["commit", "-m", "Initial fixture"])
            _ = try git(["remote", "add", "origin", remote.path]); _ = try git(["push", "-u", "origin", "main"])
        }
        deinit { try? FileManager.default.removeItem(at: folder) }
        func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        @discardableResult func git(_ args: [String], at path: String? = nil) throws -> Data {
            let process = Process(), stdout = Pipe(), stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git"); process.arguments = ["-C", path ?? root.path] + args
            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
            env["GIT_TERMINAL_PROMPT"] = "0"; process.environment = env
            process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile(), error = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CheckError(message: "Git fixture: " + String(decoding: error, as: UTF8.self)) }
            return data
        }
        func text(_ args: [String], at path: String? = nil) throws -> String { String(decoding: try git(args, at: path), as: UTF8.self).trimmingCharacters(in: .newlines) }
    }
    func testSelectedWholeFilesPreserveOtherStaging() async throws {
        let repo = try Repository(), service = GitPublisher(allowLocalRemotes: true)
        try repo.write("a.txt", "reviewed change\n"); try repo.write("b.txt", "staged elsewhere\n")
        try repo.git(["add", "b.txt"])
        let literal = "-new file ; $(literal)\nname.txt"
        try repo.write(literal, "new literal file\n"); try repo.write(".env.local", "DO_NOT_PUBLISH=fixture\n")
        let before = try await service.snapshot(path: repo.root.path)
        expectEqual(before.branch, "main"); expectEqual(before.remote, "origin"); expectEqual(before.changes.count, 4)
        expectTrue(try requireValue(before.changes.first { $0.path == ".env.local" }).isSensitive)
        let sha = try await service.commit(before, paths: ["a.txt", literal], message: "Reviewed ; $(literal) commit")
        expectNotEqual(sha, before.head)
        let committed = try repo.git(["diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "HEAD"]).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        expectEqual(Set(committed), Set(["a.txt", literal]))
        expectEqual(try repo.text(["diff", "--cached", "--name-only"]), "b.txt")
        expectEqual(try repo.text(["log", "-1", "--format=%s"]), "Reviewed ; $(literal) commit")
        expectEqual(try repo.text(["rev-parse", "refs/heads/main"], at: repo.remote.path), before.head, file: #file, line: #line)
        let fresh = try await service.snapshot(path: repo.root.path)
        do { _ = try await service.commit(fresh, paths: [".env.local"], message: "No secrets"); expectTrue(false) } catch { expectTrue(true) }
        expectEqual(try repo.text(["rev-parse", "HEAD"]), sha)
    }
    func testReviewRejectsStaleFilesConflictsAndNestedRoots() async throws {
        let repo = try Repository(), service = GitPublisher(allowLocalRemotes: true)
        try repo.write("new.txt", "reviewed\n")
        let before = try await service.snapshot(path: repo.root.path)
        try repo.write("new.txt", "changed after review\n")
        do { _ = try await service.commit(before, paths: ["new.txt"], message: "Stale"); expectTrue(false) } catch { expectTrue(true) }
        expectEqual(try repo.text(["rev-parse", "HEAD"]), before.head)
        expectEqual(try repo.text(["diff", "--cached", "--name-only"]), "")
        let child = repo.root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        do { _ = try await service.snapshot(path: child.path); expectTrue(false) } catch { expectTrue(true) }
        try Data("fixture".utf8).write(to: repo.root.appendingPathComponent(".git/MERGE_HEAD"))
        do { _ = try await service.snapshot(path: repo.root.path); expectTrue(false) } catch { expectTrue(true) }
        do { _ = try GitPublisher.parseStatus(Data("UU conflict.txt\0".utf8)); expectTrue(false) } catch { expectTrue(true) }
        expectNil(GitPublisher.githubRepository("https://token:secret@github.com/owner/repo.git"))
        expectEqual(GitPublisher.githubRepository("git@github.com:owner/repo.git"), "owner/repo")
        expectEqual(GitPublisher.githubRepository("https://github.com/owner/repo.git"), "owner/repo")
        expectFalse(GitPublisher.sanitized("fatal https://user:secret@example.com/repo").contains("secret"))
        let fields = try GitPublisher.parseStatus(Data(" M a file\0?? line\nbreak\0".utf8))
        expectEqual(fields.map(\.path), ["a file", "line\nbreak"])
    }
    func testPushUsesReviewedCommitAndRefusesRemoteDivergence() async throws {
        let repo = try Repository(), service = GitPublisher(allowLocalRemotes: true)
        try repo.write("a.txt", "first\n"); try repo.git(["commit", "-am", "Existing local commit"])
        try repo.write("a.txt", "second\n")
        let snapshot = try await service.snapshot(path: repo.root.path)
        let sha = try await service.commit(snapshot, paths: ["a.txt"], message: "Created in Portlight")
        let ready = try await service.snapshot(path: repo.root.path)
        let configuration = PublicationConfiguration(remote: "origin", branch: "main")
        let plan = try await service.preparePush(ready, configuration: configuration)
        expectEqual(plan.commits.count, 2); expectEqual(Set(plan.files), ["a.txt"])
        expectNotEqual(try repo.text(["rev-parse", "refs/heads/main"], at: repo.remote.path), sha)
        expectEqual(try await service.push(plan), sha)
        expectEqual(try repo.text(["rev-parse", "refs/heads/main"], at: repo.remote.path), sha)
        let upToDate = try await service.preparePush(ready, configuration: configuration)
        expectTrue(upToDate.commits.isEmpty)
        try repo.write("a.txt", "third\n"); try repo.git(["commit", "-am", "Pending local"])
        let local = try await service.snapshot(path: repo.root.path)
        let changedHeadPlan = try await service.preparePush(local, configuration: configuration)
        try repo.write("a.txt", "changed after push review\n"); try repo.git(["commit", "-am", "New local HEAD"])
        do { _ = try await service.push(changedHeadPlan); expectTrue(false, "Do not push after HEAD changes") } catch { expectTrue(true) }
        let newest = try await service.snapshot(path: repo.root.path)
        let stalePlan = try await service.preparePush(newest, configuration: configuration)
        let other = repo.folder.appendingPathComponent("other")
        try repo.git(["clone", "--branch", "main", repo.remote.path, other.path])
        try repo.git(["config", "user.name", "Other Fixture"], at: other.path)
        try repo.git(["config", "user.email", "other@example.invalid"], at: other.path)
        try repo.git(["config", "commit.gpgsign", "false"], at: other.path)
        try repo.git(["config", "core.hooksPath", "/dev/null"], at: other.path)
        try Data("remote change\n".utf8).write(to: other.appendingPathComponent("b.txt"))
        try repo.git(["commit", "-am", "New remote commit"], at: other.path); try repo.git(["push"], at: other.path)
        let remoteSHA = try repo.text(["rev-parse", "refs/heads/main"], at: repo.remote.path)
        do { _ = try await service.push(stalePlan); expectTrue(false, "Must never overwrite a newer remote branch") } catch { expectTrue(true) }
        expectEqual(try repo.text(["rev-parse", "refs/heads/main"], at: repo.remote.path), remoteSHA)
        do { _ = try await service.preparePush(local, configuration: configuration); expectTrue(false) } catch { expectTrue(true) }
        do { _ = try await service.preparePush(local, configuration: .init(remote: "origin", branch: "release")); expectTrue(false) } catch { expectTrue(true) }
    }
    func testRenamesDeletionsAndPushScope() async throws {
        let repo = try Repository(), service = GitPublisher(allowLocalRemotes: true)
        try repo.git(["mv", "a.txt", "renamed file.txt"])
        try repo.git(["rm", "b.txt"])
        let snapshot = try await service.snapshot(path: repo.root.path)
        expectEqual(Set(snapshot.changes.map(\.path)), ["a.txt", "b.txt", "renamed file.txt"])
        _ = try await service.commit(snapshot, paths: Set(snapshot.changes.map(\.path)), message: "Rename and delete")
        expectEqual(try repo.text(["status", "--porcelain"]), "")
        try repo.git(["tag", "-a", "do-not-push-this-tag", "-m", "Local only"])
        try repo.git(["config", "push.followTags", "true"])
        try repo.git(["config", "remote.origin.mirror", "true"])
        let ready = try await service.snapshot(path: repo.root.path)
        let plan = try await service.preparePush(ready, configuration: .init(remote: "origin", branch: "main"))
        _ = try await service.push(plan)
        expectEqual(try repo.text(["tag"], at: repo.remote.path), "")
        expectEqual(try repo.text(["rev-parse", "refs/heads/main"], at: repo.remote.path), ready.head)
        try repo.git(["config", "--add", "remote.origin.pushurl", repo.remote.path])
        try repo.git(["config", "--add", "remote.origin.pushurl", repo.folder.appendingPathComponent("other.git").path])
        do { _ = try await service.snapshot(path: repo.root.path); expectTrue(false, "Multiple push destinations must be rejected") } catch { expectTrue(true) }
    }
    func testConfigurationAndProductionStatusAreSpecific() async throws {
        let repo = try Repository(), directory = repo.folder.appendingPathComponent("archive")
        let archive = ProjectArchive(directory: directory)
        let project = try requireValue(try await archive.add(path: repo.root.path).first)
        let configuration = PublicationConfiguration(remote: "origin", branch: "main", siteURL: "https://example.invalid")
        _ = try await archive.configurePublication(configuration, for: project.id)
        expectEqual(try await ProjectArchive(directory: directory).all().first?.publication, configuration)
        let sha = String(repeating: "a", count: 40)
        let records = """
        [
          {"id":1,"sha":"\(sha)","environment":"Production","production_environment":true,"creator":{"login":"vercel[bot]"}},
          {"id":2,"sha":"\(sha)","environment":"Preview","production_environment":false,"creator":{"login":"vercel[bot]"}},
          {"id":3,"sha":"\(sha)","environment":"Production","production_environment":true,"creator":{"login":"other-bot"}},
          {"id":4,"sha":"different","environment":"Production","production_environment":true,"creator":{"login":"vercel[bot]"}}
        ]
        """
        expectEqual(try VercelDeploymentMonitor.productionDeployment(Data(records.utf8), sha: sha)?.id, 1)
        expectNil(try VercelDeploymentMonitor.productionDeployment(Data(records.utf8), sha: "missing"))
        for (status, expected) in [("pending", VercelDeploymentState.Phase.building), ("success", .ready), ("failure", .failed), ("inactive", .unavailable)] {
            let json = Data("[{\"state\":\"\(status)\",\"log_url\":\"https://vercel.com/project/run\",\"environment_url\":\"https://example.invalid\"}]".utf8)
            let state = try VercelDeploymentMonitor.status(json)
            expectEqual(state.phase, expected); expectEqual(state.detailsURL?.host, "vercel.com")
        }
        expectEqual(try VercelDeploymentMonitor.status(Data("[]".utf8)).phase, .waiting)
        expectNil(VercelDeploymentMonitor.safeURL("javascript:alert(1)"))
        expectNil(VercelDeploymentMonitor.safeURL("https://user:password@example.com"))
    }
}

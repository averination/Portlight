import Foundation
import CryptoKit

public struct PublicationConfiguration: Codable, Equatable, Sendable {
    public var remote: String
    public var branch: String
    public var siteURL: String
    public var repositoryURL: String?
    public init(remote: String, branch: String, siteURL: String = "", repositoryURL: String? = nil) {
        self.remote = remote; self.branch = branch; self.siteURL = siteURL
        self.repositoryURL = repositoryURL
    }
}

public struct GitChange: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
    public var isUntracked: Bool { status == "??" }
    public var isSensitive: Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let examples = [".env.example", ".env.sample", ".env.template"]
        return (name.hasPrefix(".env") && !examples.contains(name)) || name.hasSuffix(".pem") || name.hasSuffix(".key") || ["id_rsa", "id_ed25519", "credentials.json"].contains(name)
    }
}
public struct GitSnapshot: Sendable {
    public let root: String
    public let branch: String
    public let head: String
    public let remote: String
    public let remoteURL: String
    public let changes: [GitChange]
    public let fingerprint: String
}
public struct GitCommitSummary: Identifiable, Sendable {
    public var id: String { sha }
    public let sha: String
    public let subject: String
}
public struct GitPushPlan: Sendable {
    public let snapshot: GitSnapshot
    public let configuration: PublicationConfiguration
    public let remoteTip: String
    public let commits: [GitCommitSummary]
    public let files: [String]
}

/// Bounded, non-interactive processes. Output is kept in private temporary files to avoid pipe deadlocks.
struct PublicationCommand {
    enum Failure: Error { case timedOut }
    struct Result { let code: Int32; let data: Data; let error: String
        var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines) }
    }
    func run(_ executable: String, _ args: [String], directory: String, timeout: TimeInterval = 15) throws -> Result {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("portlight-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        func output(_ name: String) throws -> FileHandle {
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            return try FileHandle(forWritingTo: url)
        }
        let stdout = try output("out"), stderr = try output("err")
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment
        // A GUI must not inherit an agent's alternate repository/index or command injection settings.
        for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        env["PATH"] = RuntimeResolver().path
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "Never"
        env["GIT_ASKPASS"] = "/usr/bin/false"; env["SSH_ASKPASS"] = "/usr/bin/false"
        env["GIT_EDITOR"] = "/usr/bin/false"; env["GIT_SEQUENCE_EDITOR"] = "/usr/bin/false"
        env["GIT_PAGER"] = "cat"; env["LC_ALL"] = "C"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env; process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let sizes = ["out", "err"].compactMap { try? folder.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize }
            if Date() > deadline || sizes.contains(where: { $0 > 8 * 1024 * 1024 }) {
                process.terminate() // Only our own Git helper, never a server or process group.
                throw Failure.timedOut
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return Result(code: process.terminationStatus, data: try Data(contentsOf: folder.appendingPathComponent("out")),
                      error: String(decoding: try Data(contentsOf: folder.appendingPathComponent("err")), as: UTF8.self))
    }
}

/// Git operations are serialized per publication window. Nothing is pushed by commit().
public actor GitPublisher {
    private let command = PublicationCommand()
    private let allowLocalRemotes: Bool
    private var unresolvedOperation = false
    public init(allowLocalRemotes: Bool = false) { self.allowLocalRemotes = allowLocalRemotes }
    private func git(_ root: String, _ args: [String], timeout: TimeInterval = 15, checked: Bool = true) throws -> PublicationCommand.Result {
        guard !unresolvedOperation else {
            throw PortlightError.unavailable("Предыдущая операция Git превысила время ожидания. Проверьте её завершение в Git, затем перезапустите Portlight.")
        }
        let result: PublicationCommand.Result
        do { result = try command.run("/usr/bin/git", ["--no-pager", "--literal-pathspecs", "-C", root] + args, directory: root, timeout: timeout) }
        catch PublicationCommand.Failure.timedOut {
            unresolvedOperation = true
            throw PortlightError.unavailable("Git не завершил операцию вовремя. Проверьте её результат в Git, затем перезапустите Portlight. Автоматического повтора нет.")
        }
        if checked && result.code != 0 {
            throw PortlightError.unavailable("Git: " + Self.sanitized(result.error.isEmpty ? result.text : result.error))
        }
        return result
    }
    public static func sanitized(_ text: String) -> String {
        String(text.replacingOccurrences(of: "https?://[^\\s/@]+:[^\\s/@]+@", with: "https://***@", options: .regularExpression).prefix(2400))
    }
    public static func githubRepository(_ remote: String) -> String? {
        let prefix: String
        if remote.hasPrefix("https://github.com/") { prefix = "https://github.com/" }
        else if remote.hasPrefix("git@github.com:") { prefix = "git@github.com:" }
        else if remote.hasPrefix("ssh://git@github.com/") { prefix = "ssh://git@github.com/" }
        else { return nil }
        var path = String(remote.dropFirst(prefix.count))
        if path.hasSuffix(".git") { path.removeLast(4) }
        return path.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil ? path : nil
    }
    public static func parseStatus(_ data: Data) throws -> [GitChange] {
        try data.split(separator: 0).map { entry in
            guard let raw = String(data: Data(entry), encoding: .utf8), raw.utf8.count >= 4 else {
                throw PortlightError.unavailable("Имя файла не поддерживается. Используйте Git для этого проекта.")
            }
            let status = String(raw.prefix(2)), path = String(raw.dropFirst(3))
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !status.contains("U"), status != "AA", status != "DD" else {
                throw PortlightError.unavailable("Сначала разрешите конфликты Git в проекте.")
            }
            return GitChange(path: path, status: status)
        }
    }
    private func requireReady(_ root: String) throws {
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "index.lock"] {
            let path = try git(root, ["rev-parse", "--git-path", marker]).text
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: root).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { throw PortlightError.unavailable("В Git идёт другая операция. Завершите её и обновите проект.") }
        }
    }
    public func snapshot(path: String, remote selected: String? = nil) throws -> GitSnapshot {
        let root = try git(path, ["rev-parse", "--show-toplevel"]).text
        guard ProjectCatalog.canonical(root) == ProjectCatalog.canonical(path) else {
            throw PortlightError.unavailable("Папка находится внутри другого репозитория. Добавьте корневую папку Git как отдельный проект.")
        }
        try requireReady(root)
        let branchResult = try git(root, ["symbolic-ref", "--quiet", "--short", "HEAD"], checked: false)
        guard branchResult.code == 0 else { throw PortlightError.unavailable("Выберите обычную ветку Git перед публикацией.") }
        let branch = branchResult.text
        let head = try git(root, ["rev-parse", "--verify", "HEAD"]).text
        let remote: String
        if let selected { remote = selected }
        else {
            let upstream = try git(root, ["config", "--get", "branch.\(branch).remote"], checked: false).text
            let remotes = try git(root, ["remote"]).text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            remote = !upstream.isEmpty && upstream != "." ? upstream : remotes.contains("origin") ? "origin" : remotes.first ?? ""
        }
        guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.contains("\n") else { throw PortlightError.unavailable("Сначала подключите Git-репозиторий проекта к GitHub.") }
        let pushURLs = try git(root, ["remote", "get-url", "--all", "--push", remote]).text.components(separatedBy: .newlines)
        let fetchURLs = try git(root, ["remote", "get-url", "--all", remote]).text.components(separatedBy: .newlines)
        guard pushURLs.count == 1, fetchURLs.count == 1, pushURLs == fetchURLs else {
            throw PortlightError.unavailable("Для публикации нужен один одинаковый адрес чтения и отправки Git.")
        }
        let remoteURL = pushURLs[0]
        guard Self.githubRepository(remoteURL) != nil || (allowLocalRemotes && remoteURL.hasPrefix("/")) else {
            throw PortlightError.unavailable("В этой версии публикация поддерживает GitHub → Vercel. Используйте адрес GitHub без встроенного пароля.")
        }
        // Renames are represented as deletion + addition so both paths are explicit.
        let raw = try git(root, ["-c", "status.renames=false", "status", "--porcelain=v1", "-z", "--untracked-files=all"]).data
        let changes = try Self.parseStatus(raw)
        guard changes.count <= 1000 else { throw PortlightError.unavailable("Слишком много изменений для компактного просмотра. Используйте Git для этого коммита.") }
        let trackedDiff = try git(root, ["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"]).data
        var hash = SHA256(); hash.update(data: Data((root + branch + head + remoteURL).utf8)); hash.update(data: raw); hash.update(data: trackedDiff)
        for change in changes where change.isUntracked {
            let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8)) }
            else if values.isRegularFile == true {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
            } else { throw PortlightError.unavailable("Необычный тип файла: \(change.path). Используйте Git вручную.") }
        }
        return GitSnapshot(root: root, branch: branch, head: head, remote: remote, remoteURL: remoteURL,
                           changes: changes, fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    public func diff(_ snapshot: GitSnapshot, file: GitChange) throws -> String {
        guard snapshot.changes.contains(file), !file.isSensitive else { return "Этот файл не включается в публикацию из Portlight." }
        if file.isUntracked {
            let url = URL(fileURLWithPath: snapshot.root).appendingPathComponent(file.path)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { return "Символическая ссылка: " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)) }
            guard (values.fileSize ?? 0) <= 200_000 else { return "Большой новый файл. Содержимое не показано; при выборе он попадёт в коммит целиком." }
            let data = try Data(contentsOf: url)
            return String(data: data, encoding: .utf8).flatMap { $0.contains("\0") ? nil : $0 } ?? "Двоичный файл — содержимое не показано."
        }
        let text = try git(snapshot.root, ["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", file.path]).text
        return text.count > 200_000 ? String(text.prefix(200_000)) + "\n\n…Превью сокращено. Выбранный файл попадёт в коммит целиком." : text
    }
    public func commit(_ expected: GitSnapshot, paths: Set<String>, message: String) throws -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.utf8.count <= 10_000, !message.contains("\0"), !paths.isEmpty else { throw PortlightError.unavailable("Выберите файлы и напишите сообщение коммита.") }
        let fresh = try snapshot(path: expected.root, remote: expected.remote)
        guard fresh.fingerprint == expected.fingerprint else { throw PortlightError.unavailable("Проект изменился после просмотра. Обновите список и проверьте изменения ещё раз.") }
        let selected = fresh.changes.filter { paths.contains($0.path) }
        guard selected.count == paths.count, !selected.contains(where: \.isSensitive) else { throw PortlightError.unavailable("Выбор файлов изменился или содержит локальные секреты.") }
        let files = selected.map(\.path).sorted()
        let newFiles = selected.filter(\.isUntracked).map(\.path)
        if !newFiles.isEmpty { _ = try git(fresh.root, ["add", "--"] + newFiles) }
        // --only commits the reviewed whole files while preserving unrelated staged changes.
        _ = try git(fresh.root, ["commit", "--only", "-m", message, "--"] + files, timeout: 120)
        return try git(fresh.root, ["rev-parse", "HEAD"]).text
    }
    public func preparePush(_ expected: GitSnapshot, configuration: PublicationConfiguration) throws -> GitPushPlan {
        let fresh = try snapshot(path: expected.root, remote: configuration.remote)
        guard fresh.branch == configuration.branch, fresh.head == expected.head, fresh.remoteURL == expected.remoteURL,
              configuration.repositoryURL == nil || configuration.repositoryURL == fresh.remoteURL,
              try git(fresh.root, ["check-ref-format", "refs/heads/" + configuration.branch], checked: false).code == 0 else {
            throw PortlightError.unavailable("Ветка или адрес изменились. Публикация доступна из выбранной продакшен-ветки; обновите проект.")
        }
        _ = try git(fresh.root, ["fetch", "--no-tags", configuration.remote, "refs/heads/" + configuration.branch], timeout: 90)
        let tip = try git(fresh.root, ["rev-parse", "FETCH_HEAD"]).text
        guard try git(fresh.root, ["merge-base", "--is-ancestor", tip, fresh.head], checked: false).code == 0 else {
            throw PortlightError.unavailable("На GitHub есть изменения, которых нет локально. Сначала синхронизируйте проект в Git; Portlight не перезаписывает историю.")
        }
        let log = try git(fresh.root, ["log", "--format=%H%x00%s", tip + ".." + fresh.head]).text
        let commits = log.split(separator: "\n").compactMap { line -> GitCommitSummary? in
            let parts = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? GitCommitSummary(sha: String(parts[0]), subject: String(parts[1])) : nil
        }
        let files = try git(fresh.root, ["diff", "--name-only", "-z", tip, fresh.head, "--"]).data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        return GitPushPlan(snapshot: fresh, configuration: configuration, remoteTip: tip, commits: commits, files: files)
    }
    public func push(_ plan: GitPushPlan) throws -> String {
        guard !plan.commits.isEmpty else { throw PortlightError.unavailable("Нет новых коммитов для публикации.") }
        let fresh = try snapshot(path: plan.snapshot.root, remote: plan.configuration.remote)
        guard fresh.head == plan.snapshot.head, fresh.branch == plan.configuration.branch, fresh.remoteURL == plan.snapshot.remoteURL else {
            throw PortlightError.unavailable("Параметры отправки изменились. Подготовьте публикацию заново.")
        }
        // Exact reviewed commit, explicit destination branch, ordinary fast-forward push only.
        _ = try git(fresh.root, ["-c", "remote.\(plan.configuration.remote).mirror=false", "push", "--porcelain", "--no-follow-tags", plan.configuration.remote, plan.snapshot.head + ":refs/heads/" + plan.configuration.branch], timeout: 120)
        return plan.snapshot.head
    }
}

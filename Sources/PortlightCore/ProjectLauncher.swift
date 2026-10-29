import Foundation
import Darwin
import ProcessBridge

public struct LaunchState: Sendable {
    public enum Phase: Equatable, Sendable { case waitingForPort, stopped, completed, launchFailed, runtimeFailed }
    public let projectID: UUID
    public let isRunning: Bool
    public let startedAt: Date
    public let exitCode: Int32?
    public let logURL: URL
    public let phase: Phase
    public var isFailure: Bool { phase == .launchFailed || phase == .runtimeFailed }
    public var message: String {
        switch phase {
        case .waitingForPort: return "Команда работает · ожидаем локальный порт"
        case .stopped: return "Остановлен"
        case .completed: return "Команда завершена"
        case .launchFailed: return "Ошибка запуска · код \(exitCode ?? -1)"
        case .runtimeFailed: return "Сервер завершился с ошибкой · код \(exitCode ?? -1)"
        }
    }
    public init(projectID: UUID, isRunning: Bool, startedAt: Date, exitCode: Int32?, logURL: URL,
                terminationSignal: Int32? = nil, observedServer: Bool = false, stopRequested: Bool = false) {
        self.projectID = projectID; self.isRunning = isRunning; self.startedAt = startedAt
        self.exitCode = exitCode; self.logURL = logURL
        if isRunning { phase = .waitingForPort }
        else if terminationSignal == SIGTERM || (stopRequested && terminationSignal == nil && (exitCode == 0 || exitCode == 128 + SIGTERM)) {
            phase = .stopped
        } else if terminationSignal == nil && exitCode == 0 { phase = .completed }
        else { phase = observedServer ? .runtimeFailed : .launchFailed }
    }
}

public struct RuntimeResolver {
    public let directories: [String]
    public init(preferredExecutable: String? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        var paths: [String] = []
        if let preferredExecutable, Runtime.identify(executable: preferredExecutable) != nil {
            paths.append(URL(fileURLWithPath: preferredExecutable).deletingLastPathComponent().path)
        }
        paths += ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".bun/bin").path,
                  home.appendingPathComponent(".deno/bin").path, home.appendingPathComponent(".volta/bin").path,
                  home.appendingPathComponent(".local/share/pnpm").path]
        for root in [".nvm/versions/node", ".local/share/mise/installs/node", ".asdf/installs/node"] {
            let url = home.appendingPathComponent(root)
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { url.appendingPathComponent($0).appendingPathComponent("bin").path }
        }
        paths += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>(); directories = paths.filter { seen.insert($0).inserted }
    }
    public var path: String { directories.joined(separator: ":") }
    public func executable(_ tool: LaunchRecipe.Tool) throws -> URL {
        for directory in directories {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw PortlightError.unavailable("Не найден \(tool.rawValue). Установите его или выберите другой способ запуска. Зависимости автоматически не устанавливаются.")
    }
}

/// Starts only an explicitly selected saved recipe. No shell interpolation or implicit package installation.
public actor ProjectLauncher {
    private struct Running {
        let generation = UUID()
        let process: Process
        let path: String
        let startedAt: Date
        let logURL: URL
        var identity: ProcessIdentity?
        var observedServers: Set<ProcessIdentity> = []
        var stopRequested = false
    }
    /// Presentation metadata only: this context never authorizes or sends a signal.
    public struct StopContext: Sendable {
        fileprivate let runs: [UUID: (generation: UUID, servers: Set<ProcessIdentity>)]
    }
    private struct Receipt: Codable {
        let id: UUID
        let path: String
        let identity: ProcessIdentity
        let startedAt: Date
    }
    private var launches: [UUID: Running] = [:]
    private var receipts: [Receipt] = []
    private var restored = false
    private let inspector = NativeInspector()
    private let logDirectory: URL
    public init(logDirectory: URL = ProjectArchive.defaultDirectory.appendingPathComponent("Logs", isDirectory: true)) {
        self.logDirectory = logDirectory
    }
    private func restore() throws {
        guard !restored else { return }
        let url = logDirectory.appendingPathComponent("running.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { receipts = try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: url)) }
            catch { throw PortlightError.unavailable("Не удалось прочитать состояние прошлых запусков. Серверы можно проверить в активных вкладках.") }
        }
        restored = true
    }
    private func alive(_ receipt: Receipt) -> Bool {
        if let own = launches[receipt.id], !own.process.isRunning { return false }
        guard let info = inspector.info(receipt.identity.pid), info.uid == getuid(),
              info.start_seconds == receipt.identity.startSeconds, info.start_microseconds == receipt.identity.startMicroseconds else { return false }
        // npm/pnpm may briefly run /usr/bin/env, then exec Node with the same identity.
        // This record only prevents duplicate starts; it never authorizes a signal.
        guard let cwd = inspector.readString({ pl_cwd(receipt.identity.pid, $0, $1) }) else { return false }
        let canonical = ProjectCatalog.canonical(cwd)
        return canonical == receipt.path || canonical.hasPrefix(receipt.path + "/")
    }
    private func persistReceipts() throws {
        receipts.removeAll { !alive($0) }
        let url = logDirectory.appendingPathComponent("running.json")
        try JSONEncoder().encode(receipts).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func start(_ project: ArchivedProject, activeServers: [Server]) throws -> LaunchState {
        try restore()
        guard !receipts.contains(where: { $0.path == project.path && alive($0) }) else { throw PortlightError.unavailable("Команда этого проекта уже работает после предыдущего запуска Portlight.") }
        guard !launches.values.contains(where: { $0.path == project.path && $0.process.isRunning }) else { throw PortlightError.unavailable("Команда этого проекта уже запущена.") }
        guard !activeServers.contains(where: { ProjectCatalog.canonical($0.projectPath) == project.path || ProjectCatalog.canonical($0.cwd) == project.path }) else {
            throw PortlightError.unavailable("Сервер этого проекта уже работает. Откройте его адрес.")
        }
        guard let recipe = project.recipe else { throw PortlightError.unavailable("Сначала выберите команду запуска в карточке проекта.") }
        try ProjectCatalog.validate(recipe, at: project.path)
        let resolver = RuntimeResolver(preferredExecutable: project.runtimeExecutable)
        let executable = try resolver.executable(recipe.tool)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logURL = logDirectory.appendingPathComponent(project.id.uuidString + ".log")
        // O_APPEND keeps output valid across app restarts. Each explicit start replaces the previous run's log.
        let fd = logURL.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw PortlightError.unavailable("Не удалось создать журнал запуска.") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = recipe.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: project.path)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        let environment = ProcessInfo.processInfo.environment
        process.environment = ["PATH": resolver.path, "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
                               "LANG": environment["LANG"] ?? "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1"]
        try process.run()
        launches[project.id] = Running(process: process, path: project.path, startedAt: Date(), logURL: logURL)
        if let info = inspector.info(process.processIdentifier), info.uid == getuid(), info.start_seconds > 0 {
            let identity = ProcessIdentity(pid: info.pid, uid: info.uid, startSeconds: info.start_seconds, startMicroseconds: info.start_microseconds)
            launches[project.id]?.identity = identity
            receipts.removeAll { $0.id == project.id }
            receipts.append(Receipt(id: project.id, path: project.path,
                                    identity: identity,
                                    startedAt: launches[project.id]!.startedAt))
            do { try persistReceipts() }
            catch { throw PortlightError.unavailable("Команда запущена, но не удалось сохранить состояние запуска. Проверьте активные серверы.") }
        }
        return state(project.id, launches[project.id]!)
    }
    private func state(_ id: UUID, _ running: Running) -> LaunchState {
        let isRunning = running.process.isRunning
        return LaunchState(projectID: id, isRunning: isRunning, startedAt: running.startedAt,
                           exitCode: isRunning ? nil : running.process.terminationStatus, logURL: running.logURL,
                           terminationSignal: !isRunning && running.process.terminationReason == .uncaughtSignal ? running.process.terminationStatus : nil,
                           observedServer: !running.observedServers.isEmpty, stopRequested: running.stopRequested)
    }
    private func belongsToRun(_ server: Server, _ running: Running) -> Bool {
        guard running.process.isRunning, let root = running.identity,
              ProjectCatalog.canonical(server.projectPath) == running.path || ProjectCatalog.canonical(server.cwd) == running.path else { return false }
        var pid = server.id.pid, visited: Set<Int32> = []
        for _ in 0..<128 {
            guard pid > 1, visited.insert(pid).inserted, let info = inspector.info(pid), info.uid == root.uid else { return false }
            let identity = ProcessIdentity(pid: info.pid, uid: info.uid, startSeconds: info.start_seconds, startMicroseconds: info.start_microseconds)
            if pid == server.id.pid && identity != server.id { return false }
            if pid == root.pid { return identity == root }
            pid = info.parent_pid
        }
        return false
    }
    private func observe(_ servers: [Server]) {
        for (id, running) in launches {
            for server in servers where belongsToRun(server, running) {
                launches[id]?.observedServers.insert(server.id)
            }
        }
    }
    /// Capture the live parent/child relationship before SIGTERM can remove it.
    public func prepareToStop(_ targets: [Server]) -> StopContext {
        observe(targets)
        let ids = Set(targets.map(\.id))
        return StopContext(runs: launches.mapValues { ($0.generation, $0.observedServers.intersection(ids)) })
    }
    public func recordStop(_ context: StopContext, sent: [ProcessIdentity]) {
        let confirmed = Set(sent)
        for (id, run) in context.runs where launches[id]?.generation == run.generation && !run.servers.isDisjoint(with: confirmed) {
            launches[id]?.stopRequested = true
        }
    }
    public func states(activeServers: [Server] = []) -> [UUID: LaunchState] {
        try? restore()
        observe(activeServers)
        var values = Dictionary(uniqueKeysWithValues: launches.map { ($0.key, state($0.key, $0.value)) })
        for receipt in receipts where values[receipt.id] == nil && alive(receipt) {
            values[receipt.id] = LaunchState(projectID: receipt.id, isRunning: true, startedAt: receipt.startedAt, exitCode: nil,
                                            logURL: logDirectory.appendingPathComponent(receipt.id.uuidString + ".log"))
        }
        return values
    }
}

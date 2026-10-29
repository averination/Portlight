import Foundation
import Darwin
import ProcessBridge

struct CommandRunner {
    /// Files avoid pipe-buffer deadlocks; each helper has a bounded runtime and no shell interpolation.
    func run(_ executable: String, arguments: [String], timeout: TimeInterval = 4) throws -> (Int32, String, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("portlight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL), stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout; process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime > deadline {
                process.terminate() // helper only; never force-kill
                throw PortlightError.command("Проверка портов заняла слишком долго. Попробуйте обновить список.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, output, error)
    }
}

struct NativeInspector {
    func info(_ pid: Int32) -> PLProcessInfo? {
        var info = PLProcessInfo()
        return pl_process_info(pid, &info) == 1 ? info : nil
    }
    func readString(_ body: (UnsafeMutablePointer<CChar>, Int32) -> Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBufferPointer { body($0.baseAddress!, Int32($0.count)) }
        return count > 0 ? String(cString: bytes) : nil
    }
    func record(_ pid: Int32, uid: UInt32) -> ProcessRecord? {
        guard let first = info(pid), first.uid == uid,
              let executable = readString({ pl_executable(pid, $0, $1) }),
              Runtime.identify(executable: executable) != nil else { return nil }
        var cwd = readString { pl_cwd(pid, $0, $1) }
        if cwd == nil, let result = try? CommandRunner().run("/usr/sbin/lsof", arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) {
            cwd = result.1.split(separator: "\n").first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
        }
        var bytes = [CChar](repeating: 0, count: 1024 * 1024)
        let count = bytes.withUnsafeMutableBufferPointer { pl_arguments(pid, $0.baseAddress!, Int32($0.count)) }
        let args = count > 0 ? bytes.prefix(Int(count)).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) } : []
        guard let last = info(pid), first.start_seconds == last.start_seconds,
              first.start_microseconds == last.start_microseconds,
              last.uid == uid, executable == readString({ pl_executable(pid, $0, $1) }) else { return nil }
        return ProcessRecord(identity: ProcessIdentity(pid: pid, uid: last.uid, startSeconds: last.start_seconds, startMicroseconds: last.start_microseconds),
                             parentPID: last.parent_pid, realUID: last.real_uid, savedUID: last.saved_uid,
                             systemOrPrivileged: (last.flags & 0x2001) != 0, executable: executable,
                             cwd: cwd, arguments: args, residentBytes: last.has_metrics == 1 ? last.resident_bytes : nil,
                             cpuNanoseconds: last.has_metrics == 1 ? last.cpu_nanoseconds : nil)
    }
    func protectedPIDs() -> Set<Int32> {
        var result: Set<Int32> = [getpid(), 0, 1]
        var pid = getppid()
        for _ in 0..<128 {
            guard pid > 1, !result.contains(pid) else { break }
            result.insert(pid)
            guard let parent = info(pid) else { break }
            pid = parent.parent_pid
        }
        return result
    }
    func terminate(_ server: Server) -> Int32 {
        server.executable.withCString {
            pl_terminate_checked(server.identity.pid, server.identity.uid, server.identity.startSeconds,
                                 server.identity.startMicroseconds, $0)
        }
    }
}

struct ProjectLocator {
    func root(for cwd: String) -> String? {
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for _ in 0..<8 {
            guard url.path != "/", url.path != home, !DiscoveryPolicy.protectedPath(url.path) else { break }
            if ["package.json", "pyproject.toml", "deno.json", "deno.jsonc", "bun.lock", "bun.lockb", "requirements.txt", ".git"].contains(where: {
                FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
            }) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

public actor ServerService {
    private let uid = getuid()
    private let inspector = NativeInspector()
    private var observedOrigins: [ProcessIdentity: ServerAttribution] = [:]
    private let originInspector = OriginInspector()
    private var samples: [ProcessIdentity: (time: TimeInterval, cpu: UInt64)] = [:]
    private var projectGroups: [String: ServerCategory] = [:]
    public init() {}
    public func setProjectGroups(_ projects: [ArchivedProject]) {
        projectGroups = Dictionary(projects.compactMap { project in
            project.savedCategory.map { (ProjectCatalog.canonical(project.path), $0) }
        }, uniquingKeysWith: { _, last in last })
    }

    public func scan() throws -> ScanResult {
        guard uid != 0, uid == geteuid() else {
            throw PortlightError.unavailable("Запустите Portlight от обычного пользователя, без sudo.")
        }
        guard inspector.info(getpid()) != nil else {
            throw PortlightError.unavailable("macOS ограничила доступ к процессам. Запустите Portlight.app напрямую вне песочницы среды разработки.")
        }
        let (status, output, error) = try CommandRunner().run("/usr/sbin/lsof", arguments: ["-nP", "-w", "-a", "-u", String(uid), "-iTCP", "-sTCP:LISTEN", "-F", "pufn"])
        guard status == 0 || (status == 1 && output.isEmpty && error.isEmpty) else {
            throw PortlightError.command("Не удалось прочитать TCP-порты (lsof, код \(status)). Повторите проверку.")
        }
        let listeners = LsofParser.parse(output, uid: uid)
        let now = ProcessInfo.processInfo.systemUptime
        let protected = inspector.protectedPIDs()
        originInspector.beginScan()
        var servers: [Server] = [], inaccessible = 0
        var nextSamples: [ProcessIdentity: (time: TimeInterval, cpu: UInt64)] = [:]
        for pid in listeners.keys.sorted() {
            guard let basic = inspector.info(pid) else { inaccessible += 1; continue }
            guard basic.uid == uid, let record = inspector.record(pid, uid: uid) else { continue }
            guard let cwd = record.cwd else { inaccessible += 1; continue }
            guard var server = DiscoveryPolicy.classify(record, endpoints: listeners[pid]!, uid: uid,
                                                        projectRoot: ProjectLocator().root(for: cwd), protectedPIDs: protected) else { continue }
            if let cpu = record.cpuNanoseconds {
                if let previous = samples[record.identity], now > previous.time, cpu >= previous.cpu {
                    server.cpuPercent = Double(cpu - previous.cpu) / ((now - previous.time) * 1_000_000_000) * 100
                }
                nextSamples[record.identity] = (now, cpu)
            }
            let observed = originInspector.origin(of: record, inspector: inspector)
            if observed.category == .codex {
                server.attribution = observed
                observedOrigins[server.id] = observed
            } else if let remembered = observedOrigins[server.id] {
                // Only a link actually observed during this app run, tied to start time, survives reparenting.
                server.attribution = ServerAttribution(category: .codex, detail: "Связь с подписанным Codex наблюдалась ранее в этом запуске Portlight. " + remembered.detail, verified: true)
            } else { server.attribution = observed }
            server.projectCategory = projectGroups[ProjectCatalog.canonical(server.projectPath)]
            servers.append(server)
        }
        samples = nextSamples
        observedOrigins = observedOrigins.filter { key, _ in servers.contains { $0.id == key } }
        return ScanResult(servers: servers.sorted { ($0.projectName, $0.identity.pid) < ($1.projectName, $1.identity.pid) },
                          scannedAt: Date(), inaccessibleCount: inaccessible)
    }

    public struct StopResult: Sendable {
        public let sent: [ProcessIdentity]
        public let skipped: Int
        public let failures: [String]
        public let outcomes: [ProcessIdentity: String]
    }
    public func stop(_ originals: [Server], category: ServerCategory? = nil) throws -> StopResult {
        // Re-discover scope after confirmation; newly discovered servers are never added to a batch.
        let current = try scan().servers
        var sent: [ProcessIdentity] = [], skipped = 0, failures: [String] = []
        var outcomes: [ProcessIdentity: String] = [:]
        var seen = Set<ProcessIdentity>()
        for original in originals where seen.insert(original.identity).inserted {
            guard let fresh = current.first(where: { $0.id == original.id }),
                  DiscoveryPolicy.canStop(original: original, current: fresh),
                  category == nil || fresh.category == category else {
                skipped += 1; outcomes[original.id] = "Пропущен: процесс исчез или изменились данные/категория."; continue
            }
            let result = inspector.terminate(fresh)
            if result == 0 { sent.append(original.id); outcomes[original.id] = "SIGTERM отправлен" }
            else if result == ESRCH { skipped += 1; outcomes[original.id] = "Процесс уже завершён." }
            else {
                let message = "PID \(original.identity.pid): \(String(cString: strerror(result)))"
                failures.append(message); outcomes[original.id] = message
            }
        }
        return StopResult(sent: sent, skipped: skipped, failures: failures, outcomes: outcomes)
    }
}

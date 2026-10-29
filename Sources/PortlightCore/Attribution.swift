import Foundation
import Security
import ProcessBridge

public enum ServerCategory: String, Codable, CaseIterable, Sendable {
    case codex = "Codex", other = "Другие"
}

public struct ServerAttribution: Codable, Sendable {
    public let category: ServerCategory
    public let detail: String
    public let verified: Bool
    public init(category: ServerCategory, detail: String, verified: Bool) {
        self.category = category; self.detail = detail; self.verified = verified
    }
}

public extension Server {
    var category: ServerCategory { projectCategory ?? attribution?.category ?? .other }
    var groupDetail: String {
        if let projectCategory { return "Группа проекта: " + projectCategory.rawValue + " · сохранена для этой папки" }
        return "Группа проекта: " + category.rawValue + " · по источнику текущего процесса"
    }
    func grouped(using projects: [ArchivedProject]) -> Server {
        var value = self
        value.projectCategory = projects.first { $0.path == ProjectCatalog.canonical(projectPath) }?.savedCategory
        return value
    }
    var sourceDetail: String { attribution?.detail ?? "Источник не определён" }
    var sourceVerified: Bool { attribution?.verified == true }
}

/// No cwd/argv substring guesses. A name is only a prefilter before a dynamic code signature check.
public enum AttributionPolicy {
    public static func candidate(_ executable: String) -> Bool {
        ["codex", "Codex"].contains(URL(fileURLWithPath: executable).lastPathComponent)
    }
    public static func classify(verifiedCodexPID: Int32?, chainValid: Bool) -> ServerAttribution {
        guard chainValid, let pid = verifiedCodexPID else {
            return ServerAttribution(category: .other, detail: "Источник не определён. Доступная цепочка родителей не подтверждает запуск из Codex.", verified: false)
        }
        return ServerAttribution(category: .codex, detail: "Родительская цепочка ведёт к подписанному OpenAI Codex, PID \(pid).", verified: true)
    }
}

final class OriginInspector {
    // Verified against the locally installed official Codex CLI. Unsupported/unsigned builds fail closed.
    private let requirement: SecRequirement? = {
        var value: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\" and (identifier \"codex\" or identifier \"com.openai.codex\")"
        SecRequirementCreateWithString(text as CFString, [], &value)
        return value
    }()
    private var signatures: [ProcessIdentity: Bool] = [:]

    func beginScan() { signatures.removeAll(keepingCapacity: true) }

    func origin(of record: ProcessRecord, inspector: NativeInspector) -> ServerAttribution {
        var pid = record.parentPID
        var childStart = (record.identity.startSeconds, record.identity.startMicroseconds)
        var chain: [PLProcessInfo] = []
        var chainPaths: [Int32: String] = [:]
        var visited = Set<Int32>()
        var match: Int32?
        for _ in 0..<64 {
            guard pid > 1, visited.insert(pid).inserted else { break }
            guard let info = inspector.info(pid), info.uid == record.identity.uid,
                  (info.start_seconds, info.start_microseconds) <= childStart,
                  let path = inspector.readString({ pl_executable(pid, $0, $1) }) else { break }
            chain.append(info); chainPaths[pid] = path
            if AttributionPolicy.candidate(path) {
                let id = ProcessIdentity(pid: pid, uid: info.uid, startSeconds: info.start_seconds, startMicroseconds: info.start_microseconds)
                if signatures[id] == nil {
                    var code: SecCode?
                    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
                    signatures[id] = requirement != nil && SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess
                        && code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
                    if signatures.count > 256 { signatures = [id: signatures[id] ?? false] }
                }
                if signatures[id] == true { match = pid; break }
            }
            childStart = (info.start_seconds, info.start_microseconds)
            pid = info.parent_pid
        }
        // Re-read every link, including the server, to reject PID reuse/reparenting during traversal.
        let valid = inspector.info(record.identity.pid).map {
            $0.start_seconds == record.identity.startSeconds && $0.start_microseconds == record.identity.startMicroseconds
                && $0.parent_pid == record.parentPID && $0.uid == record.identity.uid
        } == true && chain.allSatisfy { old in
            inspector.info(old.pid).map { $0.start_seconds == old.start_seconds && $0.start_microseconds == old.start_microseconds
                && $0.parent_pid == old.parent_pid && $0.uid == old.uid } == true
                && inspector.readString({ pl_executable(old.pid, $0, $1) }) == chainPaths[old.pid]
        }
        return AttributionPolicy.classify(verifiedCodexPID: match, chainValid: valid)
    }
}

/// Organization is independent of process provenance. A manual choice never verifies a PID.
public enum ProjectGroupChoice: String, Codable, CaseIterable, Sendable {
    case automatic = "Автоматически", codex = "Codex", other = "Другие"
    public var category: ServerCategory? {
        switch self { case .automatic: return nil; case .codex: return .codex; case .other: return .other }
    }
}
public extension ScanResult {
    func grouped(using projects: [ArchivedProject]) -> ScanResult {
        ScanResult(servers: servers.map { $0.grouped(using: projects) }, scannedAt: scannedAt, inaccessibleCount: inaccessibleCount)
    }
}

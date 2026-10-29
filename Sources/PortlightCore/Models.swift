import Foundation

public enum Runtime: String, Codable, CaseIterable, Sendable {
    case node = "Node.js", bun = "Bun", python = "Python", deno = "Deno"

    public static func identify(executable: String) -> Runtime? {
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        switch name {
        case "node": return .node
        case "bun": return .bun
        case "deno": return .deno
        default:
            return name.range(of: "^python([23](\\.[0-9]+)?)?$", options: .regularExpression) != nil ? .python : nil
        }
    }
}

public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public init(pid: Int32, uid: UInt32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid; self.uid = uid; self.startSeconds = startSeconds; self.startMicroseconds = startMicroseconds
    }
}

public struct ProcessRecord: Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let realUID: UInt32
    public let savedUID: UInt32
    public let systemOrPrivileged: Bool
    public let executable: String
    public let cwd: String?
    public let arguments: [String]
    public let residentBytes: UInt64?
    public let cpuNanoseconds: UInt64?
    public init(identity: ProcessIdentity, parentPID: Int32, realUID: UInt32, savedUID: UInt32,
                systemOrPrivileged: Bool, executable: String, cwd: String?, arguments: [String],
                residentBytes: UInt64?, cpuNanoseconds: UInt64?) {
        self.identity = identity; self.parentPID = parentPID; self.realUID = realUID; self.savedUID = savedUID
        self.systemOrPrivileged = systemOrPrivileged; self.executable = executable; self.cwd = cwd
        self.arguments = arguments; self.residentBytes = residentBytes; self.cpuNanoseconds = cpuNanoseconds
    }
}

public struct Endpoint: Hashable, Codable, Sendable {
    public let host: String
    public let port: Int
    public var isWildcard: Bool { ["*", "0.0.0.0", "::"].contains(host) }
    public var isLocal: Bool {
        isWildcard || host == "::1" || host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }
    public var url: URL? {
        let browserHost = host.contains(":") && !isWildcard ? "[\(host)]" : (isWildcard ? "localhost" : host)
        return URL(string: "http://\(browserHost):\(port)")
    }
    public init(host: String, port: Int) { self.host = host; self.port = port }

    public static func parse(_ address: String) -> Endpoint? {
        let clean = address.replacingOccurrences(of: " (LISTEN)", with: "")
        guard let colon = clean.lastIndex(of: ":"), let port = Int(clean[clean.index(after: colon)...]),
              (1...65535).contains(port) else { return nil }
        let host = String(clean[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        return Endpoint(host: host, port: port)
    }
}

public struct Server: Identifiable, Codable, Sendable {
    public var id: ProcessIdentity { identity }
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let runtime: Runtime
    public let executable: String
    public let cwd: String
    public let projectPath: String
    public let projectName: String
    public let evidence: String
    public let endpoints: [Endpoint]
    public let allEndpoints: [Endpoint]
    public let residentBytes: UInt64?
    public var cpuPercent: Double?
    public var attribution: ServerAttribution? = nil
    public var projectCategory: ServerCategory? = nil
    public var ports: [Int] { Array(Set(endpoints.map(\.port))).sorted() }
    public var exposedToLAN: Bool { allEndpoints.contains(where: \.isWildcard) }
    public func url(for port: Int) -> URL? {
        // Prefer the exact loopback family, so IPv6-only listeners open correctly.
        let candidates = endpoints.filter { $0.port == port }
        return (candidates.first { !$0.isWildcard } ?? candidates.first)?.url
    }
}

public struct ScanResult: Codable, Sendable {
    public let servers: [Server]
    public let scannedAt: Date
    public let inaccessibleCount: Int
}

public enum PortlightError: LocalizedError {
    case command(String), unavailable(String)
    public var errorDescription: String? {
        switch self { case .command(let s), .unavailable(let s): return s }
    }
}

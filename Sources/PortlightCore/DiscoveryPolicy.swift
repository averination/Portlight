import Foundation

public enum LsofParser {
    /// lsof -F pufn: a process can own multiple FDs and both address families on one port.
    public static func parse(_ text: String, uid: UInt32) -> [Int32: Set<Endpoint>] {
        var result: [Int32: Set<Endpoint>] = [:]
        var pid: Int32?, owner: UInt32?
        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": pid = Int32(value); owner = nil
            case "u": owner = UInt32(value)
            case "n":
                if let pid, owner == uid, let endpoint = Endpoint.parse(value) {
                    result[pid, default: []].insert(endpoint)
                }
            default: break
            }
        }
        return result
    }
}

public enum DiscoveryPolicy {
    public static func protectedPath(_ path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        let roots = ["/system", "/usr", "/bin", "/sbin", "/library", "/applications", "/private/var/db"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") } ||
            path.contains(".app/") || path.hasSuffix(".app") ||
            ["/library/", "/.codex/", "/.vscode/", "/.cursor/", "/.cache/"].contains { path.contains($0) || path.hasSuffix(String($0.dropLast())) }
    }

    public static func isEmbeddedAppRuntime(_ executable: String, runtime: Runtime) -> Bool {
        let path = executable.lowercased()
        guard path.contains(".app/") else { return false }
        // python.org and Homebrew framework builds use this legitimate app wrapper.
        if runtime == .python, path.components(separatedBy: ".app/").count == 2,
           path.range(of: "/python[23]?\\.framework/versions/[^/]+/resources/python\\.app/contents/macos/python$", options: .regularExpression) != nil {
            return false
        }
        return true
    }

    public static func debuggerPorts(_ args: [String], runtime: Runtime) -> Set<Int> {
        guard runtime != .python else { return [] }
        var ports: Set<Int> = [9229] // Node/Deno default inspector. Deliberately conservative.
        for (index, arg) in args.enumerated() where arg.hasPrefix("--inspect") {
            let value: String
            if let equals = arg.firstIndex(of: "=") { value = String(arg[arg.index(after: equals)...]) }
            else if arg == "--inspect-port", args.indices.contains(index + 1) { value = args[index + 1] }
            else { continue }
            if let port = Int(value.split(separator: ":").last ?? ""), port > 0 { ports.insert(port) }
        }
        return ports
    }

    public static func classify(_ record: ProcessRecord, endpoints: Set<Endpoint>, uid: UInt32,
                                projectRoot: String?, protectedPIDs: Set<Int32> = []) -> Server? {
        guard uid != 0, record.identity.uid == uid, record.realUID == uid, record.savedUID == uid,
              record.identity.pid > 1, record.identity.startSeconds > 0,
              !record.systemOrPrivileged, !protectedPIDs.contains(record.identity.pid),
              let runtime = Runtime.identify(executable: record.executable),
              !isEmbeddedAppRuntime(record.executable, runtime: runtime),
              let cwd = record.cwd, cwd.hasPrefix("/"), !protectedPath(cwd),
              !record.arguments.isEmpty else { return nil }
        let command = record.arguments.joined(separator: " ").lowercased()
        // Background developer infrastructure is explicitly out of scope.
        let excluded = ["/mcp", "mcp-", "mcp_", "@modelcontextprotocol", "--mcp", "language-server",
                        "language_server", "tsserver", "pyright", "pylance", "debugpy", "ipykernel",
                        "jupyter", "electron", "/.codex/", "/.vscode/", "/.cursor/", "codex app-server"]
        guard !excluded.contains(where: command.contains) else { return nil }
        let names = record.arguments.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
        let framework = names.contains { ["vite", "vite.js", "astro", "webpack-dev-server", "nuxt", "uvicorn", "hypercorn"].contains($0) } ||
            command.contains("next-server") || (names.contains("next") && (names.contains("dev") || names.contains("start"))) ||
            (names.contains("flask") && names.contains("run")) || (names.contains("manage.py") && names.contains("runserver"))
        let pythonHTTP = record.arguments.contains("http.server") && record.arguments.contains("-m")
        // Generic listeners need a nearby project marker; explicit dev commands can stand alone.
        guard pythonHTTP || framework || projectRoot != nil else { return nil }
        let debugPorts = debuggerPorts(record.arguments, runtime: runtime)
        let eligible = endpoints.filter { $0.isLocal && $0.port >= 1024 && !debugPorts.contains($0.port) }
        guard !eligible.isEmpty else { return nil }
        let root = projectRoot ?? cwd
        let name = URL(fileURLWithPath: root).lastPathComponent
        return Server(identity: record.identity, parentPID: record.parentPID, runtime: runtime,
                      executable: record.executable, cwd: cwd, projectPath: root,
                      projectName: name.isEmpty ? runtime.rawValue : name,
                      evidence: pythonHTTP ? "Python HTTP server" : (framework ? "Команда dev-сервера" : "TCP + папка проекта"),
                      endpoints: eligible.sorted { ($0.port, $0.host) < ($1.port, $1.host) },
                      allEndpoints: endpoints.sorted { ($0.port, $0.host) < ($1.port, $1.host) },
                      residentBytes: record.residentBytes, cpuPercent: nil)
    }

    public static func canStop(original: Server, current: Server) -> Bool {
        original.identity == current.identity && original.executable == current.executable &&
        original.cwd == current.cwd && Set(original.allEndpoints) == Set(current.allEndpoints)
    }
}

import PortlightCore

final class DiscoveryTests {
    let uid: UInt32 = 501
    let endpoint: Set<Endpoint> = [Endpoint(host: "127.0.0.1", port: 5173)]
    func record(pid: Int32 = 4200, uid: UInt32 = 501, realUID: UInt32 = 501, savedUID: UInt32 = 501,
                start: UInt64 = 100, executable: String = "/opt/homebrew/bin/node", cwd: String? = "/Users/test/Projects/web",
                args: [String] = ["node", "node_modules/vite/bin/vite.js"], privileged: Bool = false) -> ProcessRecord {
        ProcessRecord(identity: .init(pid: pid, uid: uid, startSeconds: start, startMicroseconds: 20),
                      parentPID: 4199, realUID: realUID, savedUID: savedUID, systemOrPrivileged: privileged,
                      executable: executable, cwd: cwd, arguments: args, residentBytes: 12345, cpuNanoseconds: 100)
    }
    func classify(_ r: ProcessRecord, endpoints: Set<Endpoint>? = nil, root: String? = "/Users/test/Projects/web", protected: Set<Int32> = []) -> Server? {
        DiscoveryPolicy.classify(r, endpoints: endpoints ?? endpoint, uid: uid, projectRoot: root, protectedPIDs: protected)
    }
    func testParsesActualLsofFieldFormatAndDeduplicatesDescriptors() {
        let text = "p4200\nu501\nf3\nn127.0.0.1:5173\nf4\nn127.0.0.1:5173\nf5\nn[::1]:5173\nf6\nn*:3000\np99\nu0\nf3\nn*:8000\np100\nf4\nn*:9000\n"
        let result = LsofParser.parse(text, uid: uid)
        expectEqual(result.count, 1)
        expectEqual(result[4200]?.count, 3)
    }
    func testIPv6AndWildcardURLs() {
        expectEqual(Endpoint.parse("[::1]:8000")?.url?.absoluteString, "http://[::1]:8000")
        expectEqual(Endpoint.parse("*:5173")?.url?.absoluteString, "http://localhost:5173")
        expectEqual(Endpoint.parse("127.0.0.2:5173")?.url?.absoluteString, "http://127.0.0.2:5173")
        expectNil(Endpoint.parse("*:banana")); expectNil(Endpoint.parse("*:99999"))
        expectFalse(Endpoint(host: "192.168.1.3", port: 3000).isLocal)
    }
    func testExecutableWhitelistIsExactAndSupportsVersionedPython() {
        for name in ["python", "python3", "Python", "python3.13"] {
            expectEqual(Runtime.identify(executable: "/bin/\(name)"), .python)
        }
        for name in ["node-helper", "notnode", "pythonista", "deno-lsp", "npm", "sh", "Electron"] {
            expectNil(Runtime.identify(executable: "/bin/\(name)"))
        }
        expectEqual(Runtime.identify(executable: "/bin/bun"), .bun)
        expectEqual(Runtime.identify(executable: "/bin/deno"), .deno)
    }
    func testOrdinaryRuntimeProcessNeedsAnEligibleListener() {
        expectNil(classify(record(), endpoints: []))
        expectNil(classify(record(), endpoints: [.init(host: "127.0.0.1", port: 80)]))
        expectNil(classify(record(), endpoints: [.init(host: "192.168.1.3", port: 3000)]))
    }
    func testMultiplePortsAndAddressFamiliesStayInOneProcessRow() {
        let server = classify(record(), endpoints: [.init(host: "127.0.0.1", port: 3000), .init(host: "::1", port: 3000), .init(host: "*", port: 3001)])
        expectEqual(server?.ports, [3000, 3001]); expectEqual(server?.identity.pid, 4200)
        expectEqual(server?.exposedToLAN, true)
    }
    func testRenamedNextWorkerUsesRealExecutableAndKeepsParentSeparate() {
        let server = classify(record(args: ["next-server (v16.0.0)"]))
        expectEqual(server?.runtime, .node); expectEqual(server?.parentPID, 4199)
        expectNil(classify(record(executable: "/bin/zsh", args: ["node", "vite"])))
    }
    func testForeignRootPrivilegedAndAncestorProcessesAreExcluded() {
        expectNil(classify(record(uid: 0))); expectNil(classify(record(uid: 502)))
        expectNil(classify(record(realUID: 0))); expectNil(classify(record(savedUID: 0)))
        expectNil(classify(record(privileged: true))); expectNil(classify(record(pid: 1)))
        expectNil(classify(record(), protected: [4200])); expectNil(classify(record(start: 0)))
    }
    func testMissingMetadataFailsClosed() {
        expectNil(classify(record(cwd: nil))); expectNil(classify(record(args: [])))
        expectNil(classify(record(executable: "")))
    }
    func testBackgroundInfrastructureExcludedEvenInsideProject() {
        for command in ["/project/node_modules/@modelcontextprotocol/server/index.js", "/project/mcp-server.js", "--mcp", "typescript-language-server", "pyright", "debugpy", "jupyter"] {
            expectNil(classify(record(args: ["node", command])), command)
        }
        expectNil(classify(record(cwd: "/Users/test/Library/Application Support/app")))
        expectNil(classify(record(cwd: "/Users/test/.codex/bin")))
        expectNil(classify(record(executable: "/Applications/Tool.app/Contents/Resources/node")))
        expectNotNil(classify(record(cwd: "/Users/test/Documents/Codex/project")))
    }
    func testFrameworkPythonIsAllowedButAppEmbeddedPythonIsNot() {
        expectNotNil(classify(record(executable: "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python", args: ["python3", "-m", "http.server"])))
        expectNotNil(classify(record(executable: "/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python", args: ["python3", "-m", "http.server"])))
        expectNil(classify(record(executable: "/Applications/Tool.app/Contents/MacOS/Python", args: ["python3", "-m", "http.server"])))
    }
    func testCustomServerRequiresProjectButPythonHTTPWorksWithoutMarker() {
        expectNil(classify(record(args: ["node", "server.js"]), root: nil))
        expectNotNil(classify(record(args: ["node", "server.js"])))
        expectNotNil(classify(record(executable: "/opt/bin/python3.13", args: ["python3", "-m", "http.server", "8000"]), root: nil))
    }
    func testInspectorsAreNotShownAsServers() {
        expectNil(classify(record(), endpoints: [.init(host: "127.0.0.1", port: 9229)]))
        let server = classify(record(args: ["node", "--inspect=127.0.0.1:9333", "server.js"]), endpoints: [.init(host: "127.0.0.1", port: 9333), .init(host: "127.0.0.1", port: 3000)])
        expectEqual(server?.ports, [3000])
        expectNil(classify(record(args: ["node", "--inspect", "--inspect-port", "9333", "server.js"]), endpoints: [.init(host: "127.0.0.1", port: 9333)]))
    }
    func testStopRequiresSameIdentityExecutableDirectoryAndEndpoints() throws {
        let original = try requireValue(classify(record()))
        expectTrue(DiscoveryPolicy.canStop(original: original, current: original))
        for changed in [record(start: 101), record(executable: "/new/bin/node"), record(cwd: "/Users/test/Projects/new")] {
            let current = try requireValue(classify(changed))
            expectFalse(DiscoveryPolicy.canStop(original: original, current: current))
        }
        let changedPorts = try requireValue(classify(record(), endpoints: [.init(host: "127.0.0.1", port: 5174)]))
        expectFalse(DiscoveryPolicy.canStop(original: original, current: changedPorts))
        let addedDebugger = try requireValue(classify(record(), endpoints: endpoint.union([.init(host: "127.0.0.1", port: 9229)])))
        expectEqual(addedDebugger.ports, original.ports)
        expectFalse(DiscoveryPolicy.canStop(original: original, current: addedDebugger))
    }
}

import Foundation

public struct LaunchRecipe: Codable, Hashable, Identifiable, Sendable {
    public enum Tool: String, Codable, CaseIterable, Sendable { case npm, pnpm, yarn, bun, deno, python3 }
    public let tool: Tool
    public let task: String
    public var id: String { tool.rawValue + ":" + task }
    public var arguments: [String] {
        switch tool {
        case .deno: return ["task", task]
        case .python3: return ["-m", "http.server", "8000", "--bind", "127.0.0.1"]
        default: return ["run", task]
        }
    }
    public var display: String { ([tool.rawValue] + arguments).joined(separator: " ") }
    public init(tool: Tool, task: String) { self.tool = tool; self.task = task }
}

public struct ArchivedProject: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let path: String
    public var recipe: LaunchRecipe?
    public var folderBookmark: Data? = nil
    public var publication: PublicationConfiguration? = nil
    public var groupOverride: ProjectGroupChoice? = nil
    public var observedCodex: Bool? = nil
    public var groupChoice: ProjectGroupChoice { groupOverride ?? .automatic }
    public var savedCategory: ServerCategory? { groupChoice.category ?? (observedCodex == true ? .codex : nil) }
    public var availableRecipes: [LaunchRecipe]? = nil
    public var runtimeExecutable: String?
    public var lastSeen: Date?
    public var lastURL: URL?
    public let addedAt: Date
    public init(id: UUID = UUID(), name: String, path: String, recipe: LaunchRecipe? = nil,
                availableRecipes: [LaunchRecipe]? = nil, runtimeExecutable: String? = nil, lastSeen: Date? = nil, lastURL: URL? = nil, addedAt: Date = Date()) {
        self.id = id; self.name = name; self.path = ProjectCatalog.canonical(path)
        self.recipe = recipe; self.availableRecipes = availableRecipes; self.runtimeExecutable = runtimeExecutable
        self.lastSeen = lastSeen; self.lastURL = lastURL; self.addedAt = addedAt
    }
}

public enum ProjectCatalog {
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public static func recipes(at path: String) -> [LaunchRecipe] {
        let directory = URL(fileURLWithPath: path)
        let fm = FileManager.default
        func json(_ name: String) -> [String: Any]? {
            let url = directory.appendingPathComponent(name)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_048_576,
                  let result = try? CommandRunner().run("/bin/cat", arguments: [url.path]), result.0 == 0,
                  let data = result.1.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let taskNames = ["dev", "start", "serve", "preview"]
        if let package = json("package.json"), let scripts = package["scripts"] as? [String: String] {
            let manager = (package["packageManager"] as? String)?.split(separator: "@").first.map(String.init)
            let tool: LaunchRecipe.Tool
            if let explicit = manager.flatMap(LaunchRecipe.Tool.init(rawValue:)), [.npm, .pnpm, .yarn, .bun].contains(explicit) { tool = explicit }
            else if fm.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) { tool = .pnpm }
            else if ["bun.lock", "bun.lockb"].contains(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) { tool = .bun }
            else if fm.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) { tool = .yarn }
            else { tool = .npm }
            return taskNames.filter { scripts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                .map { LaunchRecipe(tool: tool, task: $0) }
        }
        if let tasks = json("deno.json")?["tasks"] as? [String: Any] {
            return taskNames.filter { tasks[$0] != nil }.map { LaunchRecipe(tool: .deno, task: $0) }
        }
        return []
    }
    public static let staticPython = LaunchRecipe(tool: .python3, task: "static-http")
    public static func validate(_ recipe: LaunchRecipe, at path: String) throws {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), !DiscoveryPolicy.protectedPath(canonical(path)),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PortlightError.unavailable("Папка проекта недоступна. Добавьте её заново, если проект перемещён.")
        }
        if recipe == staticPython { return }
        guard recipes(at: path).contains(recipe) else {
            throw PortlightError.unavailable("Не удалось подтвердить команду проекта. Проверьте доступ к папке и обновите команды в карточке.")
        }
    }
}

public actor ProjectArchive {
    private struct Document: Codable {
        var version = 1
        var projects: [ArchivedProject] = []
        var excludedPaths: Set<String> = []
    }
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Portlight", isDirectory: true)
    }
    private let directory: URL
    private var document: Document?
    private var accessibleFolders: [URL] = []
    public init(directory: URL = ProjectArchive.defaultDirectory) { self.directory = directory }
    private func load() throws -> Document {
        if let document { return document }
        let url = directory.appendingPathComponent("projects.json")
        if !FileManager.default.fileExists(atPath: url.path) { let empty = Document(); document = empty; return empty }
        do {
            let value = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard value.version == 1 else { throw PortlightError.unavailable("Неизвестная версия архива проектов.") }
            document = value
            for project in value.projects {
                guard let data = project.folderBookmark else { continue }
                var stale = false
                let resolved = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))
                    ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))
                if let resolved, ProjectCatalog.canonical(resolved.path) == project.path, resolved.startAccessingSecurityScopedResource() {
                    accessibleFolders.append(resolved)
                }
            }
            return value
        } catch { throw PortlightError.unavailable("Не удалось прочитать архив проектов. Исходный файл сохранён: \(url.path)") }
    }
    private func save(_ value: Document) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("projects.json")
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        document = value
    }
    private func sorted(_ value: Document) -> [ArchivedProject] { value.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    public func all() throws -> [ArchivedProject] { sorted(try load()) }
    @discardableResult public func add(path: String, name: String? = nil, bookmark: Data? = nil) throws -> [ArchivedProject] {
        let path = ProjectCatalog.canonical(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              !DiscoveryPolicy.protectedPath(path) else { throw PortlightError.unavailable("Выберите доступную папку проекта.") }
        var value = try load()
        value.excludedPaths.remove(path)
        if let i = value.projects.firstIndex(where: { $0.path == path }) {
            if let bookmark { value.projects[i].folderBookmark = bookmark }
            value.projects[i].availableRecipes = ProjectCatalog.recipes(at: path)
            if let name, !name.isEmpty { value.projects[i].name = name }
        } else {
            let options = ProjectCatalog.recipes(at: path)
            value.projects.append(ArchivedProject(name: name ?? URL(fileURLWithPath: path).lastPathComponent, path: path,
                                                  recipe: options.first, availableRecipes: options))
            value.projects[value.projects.count - 1].folderBookmark = bookmark
        }
        try save(value); return sorted(value)
    }
    public func add(folder: URL) throws -> [ArchivedProject] {
        if folder.startAccessingSecurityScopedResource() { accessibleFolders.append(folder) }
        let bookmark = (try? folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? folder.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil))
        return try add(path: folder.path, bookmark: bookmark)
    }
    public func remember(_ servers: [Server]) throws -> [ArchivedProject] {
        var value = try load(); var changed = false
        for server in servers {
            let path = ProjectCatalog.canonical(server.projectPath)
            guard !value.excludedPaths.contains(path), !DiscoveryPolicy.protectedPath(path) else { continue }
            if let i = value.projects.firstIndex(where: { $0.path == path }) {
                if server.sourceVerified && server.attribution?.category == .codex && value.projects[i].observedCodex != true {
                    value.projects[i].observedCodex = true; changed = true
                }
                let url = server.ports.first.flatMap { server.url(for: $0) }
                if Date().timeIntervalSince(value.projects[i].lastSeen ?? .distantPast) > 60 || value.projects[i].lastURL != url {
                    value.projects[i].lastSeen = Date(); value.projects[i].lastURL = url
                    value.projects[i].runtimeExecutable = server.executable; changed = true
                }
            } else {
                let options = ProjectCatalog.recipes(at: path)
                value.projects.append(ArchivedProject(name: server.projectName, path: path, recipe: options.first, availableRecipes: options,
                                                      runtimeExecutable: server.executable, lastSeen: Date(),
                                                      lastURL: server.ports.first.flatMap { server.url(for: $0) }))
                value.projects[value.projects.count - 1].observedCodex = server.sourceVerified && server.attribution?.category == .codex ? true : nil
                changed = true
            }
        }
        if changed { try save(value) }
        return sorted(value)
    }
    public func setGroup(_ choice: ProjectGroupChoice, path: String) throws -> [ArchivedProject] {
        var value = try load()
        guard let i = value.projects.firstIndex(where: { $0.path == ProjectCatalog.canonical(path) }) else {
            throw PortlightError.unavailable("Добавьте папку проекта в архив перед выбором группы.")
        }
        value.projects[i].groupOverride = choice == .automatic ? nil : choice
        try save(value); return sorted(value)
    }
    public func refreshRecipes(for id: UUID) throws -> [ArchivedProject] {
        var value = try load()
        if let i = value.projects.firstIndex(where: { $0.id == id }) {
            value.projects[i].availableRecipes = ProjectCatalog.recipes(at: value.projects[i].path)
            try save(value)
        }
        return sorted(value)
    }
    public func select(_ recipe: LaunchRecipe, for id: UUID) throws -> [ArchivedProject] {
        var value = try load()
        guard let i = value.projects.firstIndex(where: { $0.id == id }) else { return sorted(value) }
        try ProjectCatalog.validate(recipe, at: value.projects[i].path)
        value.projects[i].recipe = recipe; try save(value); return sorted(value)
    }
    public func remove(_ id: UUID) throws -> [ArchivedProject] {
        var value = try load()
        if let project = value.projects.first(where: { $0.id == id }) { value.excludedPaths.insert(project.path) }
        value.projects.removeAll { $0.id == id }
        try save(value); return sorted(value)
    }
    public func configurePublication(_ configuration: PublicationConfiguration, for id: UUID) throws -> [ArchivedProject] {
        var value = try load()
        guard let i = value.projects.firstIndex(where: { $0.id == id }) else { throw PortlightError.unavailable("Проект удалён из архива.") }
        value.projects[i].publication = configuration
        try save(value); return sorted(value)
    }
}

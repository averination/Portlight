import AppKit
import SwiftUI
import PortlightCore

struct RowStatus {
    enum Phase { case running, stopping, stopped, failed }
    var phase: Phase
    var message: String
    var date = Date()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var showArchive = false
    @Published var archivedProjects: [ArchivedProject] = []
    @Published var launchStates: [UUID: LaunchState] = [:]
    @Published var launchingProjects: Set<UUID> = []
    @Published var archiveError: String?
    var onRevealArchive: (() -> Void)?
    var onPublishRequested: ((ArchivedProject) -> Void)?
    @Published var notchEnabled = true
    var onHideRequested: (() -> Void)?
    private let archive = ProjectArchive()
    private let launcher = ProjectLauncher()
    private var archiveLoadTask: Task<Void, Never>?
    @Published var selectedCategory: ServerCategory = .codex
    @Published var statuses: [ProcessIdentity: RowStatus] = [:]
    @Published var recent: [Server] = []
    @Published var scanning = false
    @Published var stopping = false
    @Published var lastUpdate: Date?
    @Published var error: String?
    @Published var notice: String?
    @Published var inaccessibleCount = 0
    @Published var showScope = false
    @Published var pendingBatch: [Server]?
    @Published var acknowledgedUnknown = false
    var pendingCategory: ServerCategory = .codex
    var isVisible = false { didSet { if isVisible != oldValue { start() } } }
    var onChange: (() -> Void)?
    private let service = ServerService()
    private var pollTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    init() {
        archiveLoadTask = Task { [weak self] in
            guard let self else { return }
            do { self.archivedProjects = try await self.archive.all() }
            catch { self.archiveError = error.localizedDescription }
        }
    }
    var activeServers: [Server] { servers.filter { $0.category == selectedCategory } }
    func count(_ category: ServerCategory) -> Int { servers.filter { $0.category == category }.count }
    var summary: String { servers.isEmpty ? "Нет активных серверов" : "Codex: \(count(.codex)) · Другие: \(count(.other))" }
    func rows(_ category: ServerCategory) -> [Server] {
        servers.filter { $0.category == category } + recent.filter { old in
            old.category == category && !servers.contains { $0.id == old.id }
        }
    }
    func status(_ server: Server) -> RowStatus {
        if let error { return RowStatus(phase: .failed, message: "Ошибка определения: " + error) }
        return statuses[server.id] ?? RowStatus(phase: .running, message: "Работает")
    }
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                if Task.isCancelled { return }
                let delay: UInt64 = self?.isVisible == true ? 3 : 12
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }
    func suspend() { pollTask?.cancel() }
    private func accept(_ result: ScanResult) {
        for old in servers where !result.servers.contains(where: { $0.id == old.id }) {
            if !recent.contains(where: { $0.id == old.id }) { recent.append(old) }
            statuses[old.id] = RowStatus(phase: .stopped, message: "Завершён · порт больше не прослушивается")
        }
        for current in result.servers where statuses[current.id]?.phase == .stopped { statuses.removeValue(forKey: current.id) }
        recent.removeAll { old in result.servers.contains { $0.id == old.id } }
        servers = result.servers; lastUpdate = result.scannedAt
        inaccessibleCount = result.inaccessibleCount; error = nil
        recent.removeAll { Date().timeIntervalSince(statuses[$0.id]?.date ?? .distantPast) > 20 }
        let retained = Set((servers + recent).map(\.id))
        statuses = statuses.filter { retained.contains($0.key) }
    }
    func refresh() async {
        guard !scanning, !stopping else { return }
        scanning = true
        defer { scanning = false; onChange?() }
        do {
            let result = try await scanProjects(); accept(result)
            launchStates = await launcher.states(activeServers: result.servers)
        }
        catch { self.error = error.localizedDescription }
    }
    /// Resolve project grouping from disk before scanning, including stop revalidation.
    private func scanProjects() async throws -> ScanResult {
        let saved = try await archive.all()
        await service.setProjectGroups(saved)
        let result = try await service.scan()
        do {
            archivedProjects = try await archive.remember(result.servers)
            archiveError = nil
        } catch {
            archivedProjects = saved
            archiveError = error.localizedDescription
        }
        await service.setProjectGroups(archivedProjects)
        return result.grouped(using: archivedProjects)
    }
    func groupChoice(for path: String) -> ProjectGroupChoice {
        archivedProjects.first { $0.path == ProjectCatalog.canonical(path) }?.groupChoice ?? .automatic
    }
    func chooseGroup(_ choice: ProjectGroupChoice, path: String) {
        guard !stopping, !scanning else { return }
        pendingBatch = nil
        Task {
            do {
                if !archivedProjects.contains(where: { $0.path == ProjectCatalog.canonical(path) }) {
                    archivedProjects = try await archive.add(path: path)
                }
                archivedProjects = try await archive.setGroup(choice, path: path)
                await service.setProjectGroups(archivedProjects)
                servers = servers.map { $0.grouped(using: archivedProjects) }
                recent = recent.map { $0.grouped(using: archivedProjects) }
                if let category = servers.first(where: { ProjectCatalog.canonical($0.projectPath) == ProjectCatalog.canonical(path) })?.category {
                    selectedCategory = category
                }
                notice = "Группа проекта сохранена: " + choice.rawValue
                archiveError = nil; onChange?()
            } catch { archiveError = error.localizedDescription }
        }
    }
    func requestStopAll() { requestConfirmation(activeServers) }
    func requestStop(_ server: Server) {
        if server.sourceVerified { stop([server], category: server.category) }
        else { requestConfirmation([server]) }
    }
    private func requestConfirmation(_ targets: [Server]) {
        guard !targets.isEmpty, !stopping, error == nil else { return }
        pendingCategory = targets.first?.category ?? selectedCategory; acknowledgedUnknown = false; pendingBatch = targets
    }
    var needsSourceAcknowledgement: Bool { pendingBatch?.contains { !$0.sourceVerified } == true }
    func confirmStop() {
        guard let targets = pendingBatch, !needsSourceAcknowledgement || acknowledgedUnknown else { return }
        stop(targets, category: pendingCategory)
    }
    func stop(_ targets: [Server], category: ServerCategory? = nil) {
        guard !stopping, !targets.isEmpty, error == nil else { return }
        stopping = true; pendingBatch = nil; notice = nil
        for server in targets { statuses[server.id] = RowStatus(phase: .stopping, message: "Завершается…") }
        operationTask = Task {
            defer { stopping = false; onChange?() }
            do {
                let launchContext = await launcher.prepareToStop(targets)
                let result = try await service.stop(targets, category: category)
                await launcher.recordStop(launchContext, sent: result.sent)
                var latest: ScanResult?
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let scan = try await scanProjects(); latest = scan; accept(scan)
                    onChange?()
                    if !scan.servers.contains(where: { result.sent.contains($0.id) }) { break }
                }
                let active = latest?.servers ?? servers
                var completed = 0
                for old in targets {
                    let remains = active.contains { $0.id == old.id }
                    let restarted = active.contains { $0.cwd == old.cwd && $0.id != old.id && !Set($0.ports).isDisjoint(with: old.ports) }
                    let message: String
                    let phase: RowStatus.Phase
                    if result.sent.contains(old.id) {
                        if remains { phase = .failed; message = "Ещё работает после SIGTERM. Остановите в терминале проекта." }
                        else {
                            completed += 1; phase = .stopped
                            message = restarted ? "Процесс завершён; родитель запустил новый сервер." : "Завершён · порты освобождены"
                        }
                    } else { phase = .failed; message = result.outcomes[old.id] ?? "Не удалось проверить результат." }
                    statuses[old.id] = RowStatus(phase: phase, message: message)
                    if !remains && !recent.contains(where: { $0.id == old.id }) { recent.append(old) }
                }
                notice = "Завершены: \(completed) из \(targets.count). Результат каждого — в его карточке."
                launchStates = await launcher.states(activeServers: servers)
            } catch {
                self.error = error.localizedDescription
                for server in targets { statuses[server.id] = RowStatus(phase: .failed, message: "Результат не подтверждён: " + error.localizedDescription) }
            }
        }
    }
    func activeServers(for project: ArchivedProject) -> [Server] {
        servers.filter { ProjectCatalog.canonical($0.projectPath) == project.path || ProjectCatalog.canonical($0.cwd) == project.path }
    }
    func launch(_ project: ArchivedProject) {
        guard !launchingProjects.contains(project.id), !stopping else { return }
        launchingProjects.insert(project.id); archiveError = nil
        Task {
            defer { launchingProjects.remove(project.id); onChange?() }
            do {
                // A fresh scan prevents duplicate starts from an outdated archive card.
                let current = try await scanProjects(); accept(current)
                launchStates[project.id] = try await launcher.start(project, activeServers: current.servers)
                // Keep the launch button disabled while the command is alive, even before a port appears.
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await refresh()
                    if !activeServers(for: project).isEmpty || launchStates[project.id]?.isRunning == false { break }
                }
            } catch { archiveError = error.localizedDescription }
        }
    }
    func refreshRecipes(_ project: ArchivedProject) {
        Task {
            do { archivedProjects = try await archive.refreshRecipes(for: project.id); archiveError = nil }
            catch { archiveError = error.localizedDescription }
        }
    }
    func chooseRecipe(_ recipe: LaunchRecipe, project: ArchivedProject) {
        Task {
            do { archivedProjects = try await archive.select(recipe, for: project.id); archiveError = nil }
            catch { archiveError = error.localizedDescription }
        }
    }
    func forget(_ project: ArchivedProject) {
        Task {
            do { archivedProjects = try await archive.remove(project.id); archiveError = nil }
            catch { archiveError = error.localizedDescription }
        }
    }
    func addProject(initialPath: String? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Сохранить проект в архив"
        if let initialPath { panel.directoryURL = URL(fileURLWithPath: initialPath) }
        panel.message = "Выберите папку проекта. Команда появится в карточке; запуск — только по вашей кнопке."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Добавить проект"
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                if response == .OK, let url = panel.url {
                    do { self.archivedProjects = try await self.archive.add(folder: url); self.archiveError = nil }
                    catch { self.archiveError = error.localizedDescription }
                }
                self.onRevealArchive?(); self.showArchive = true
            }
        }
    }
    func showActive(_ project: ArchivedProject) {
        if let first = activeServers(for: project).first { selectedCategory = first.category; showArchive = false }
    }
    func publish(_ project: ArchivedProject) {
        onPublishRequested?(project)
    }
    func publish(_ server: Server) {
        guard let project = archivedProjects.first(where: { $0.path == ProjectCatalog.canonical(server.projectPath) }) else {
            notice = "Проект ещё не сохранён. Обновите список или добавьте его папку в архив."; return
        }
        publish(project)
    }
    func savePublication(_ configuration: PublicationConfiguration, for project: ArchivedProject) async throws {
        archivedProjects = try await archive.configurePublication(configuration, for: project.id)
    }
    func openLog(_ project: ArchivedProject) {
        if let url = launchStates[project.id]?.logURL { NSWorkspace.shared.open(url) }
    }
    func open(_ url: URL?) {
        guard let url else { return }
        if !NSWorkspace.shared.open(url) { error = "Не удалось открыть URL в браузере." }
    }
    func copy(_ url: URL?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        notice = "Адрес скопирован: " + url.absoluteString
    }
    func reveal(_ path: String) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    var totalMemory: String {
        let values = activeServers.compactMap(\.residentBytes)
        guard !values.isEmpty else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(values.reduce(0, +)), countStyle: .memory)
    }
    var freshness: String {
        if stopping { return "Останавливаем выбранные серверы…" }
        if scanning { return "Проверяем порты…" }
        if error != nil { return "Данные не обновлены" }
        guard let lastUpdate else { return "Первая проверка…" }
        return "Обновлено в \(lastUpdate.formatted(date: .omitted, time: .standard))"
    }
}

import AppKit
import SwiftUI
import PortlightCore

@MainActor
final class PublicationModel: ObservableObject {
    let project: ArchivedProject
    private let publisher: GitPublisher
    private let save: (PublicationConfiguration) async throws -> Void
    @Published var snapshot: GitSnapshot?
    @Published var selected: Set<String> = []
    @Published var focusedPath: String?
    @Published var diff = "Выберите файл, чтобы посмотреть изменения"
    @Published var message = ""
    @Published var busy: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var productionBranch = "main"
    @Published var siteURL = ""
    @Published var connectionConfirmed = false
    @Published var pushPlan: GitPushPlan?
    @Published var showingConfirmation = false
    @Published var deployment: VercelDeploymentState?
    @Published var pushedSHA: String?
    private var monitorTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var confirmedRepository: String?
    init(project: ArchivedProject, save: @escaping (PublicationConfiguration) async throws -> Void) {
        self.project = project; self.save = save
        publisher = GitPublisher()
        if let configuration = project.publication {
            productionBranch = configuration.branch; siteURL = configuration.siteURL; connectionConfirmed = true
            confirmedRepository = configuration.repositoryURL
        }
    }
    var configuration: PublicationConfiguration? {
        guard let snapshot else { return nil }
        return .init(remote: snapshot.remote, branch: productionBranch.trimmingCharacters(in: .whitespacesAndNewlines), siteURL: siteURL.trimmingCharacters(in: .whitespacesAndNewlines), repositoryURL: snapshot.remoteURL)
    }
    var canCommit: Bool { busy == nil && snapshot != nil && !selected.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canPrepare: Bool { busy == nil && connectionConfirmed && configuration?.branch == snapshot?.branch && snapshot != nil }
    var productionURL: URL? { VercelDeploymentMonitor.safeURL(siteURL) }
    func refresh() {
        guard busy == nil else { return }
        busy = "Читаем изменения"; error = nil; pushPlan = nil
        Task {
            defer { busy = nil }
            do {
                snapshot = try await publisher.snapshot(path: project.path, remote: project.publication?.remote)
                if let confirmedRepository, confirmedRepository != snapshot?.remoteURL { connectionConfirmed = false }
                selected = selected.intersection(Set(snapshot?.changes.filter { !$0.isSensitive }.map(\.path) ?? []))
                if let path = focusedPath, let file = snapshot?.changes.first(where: { $0.path == path }) { preview(file) }
                else { focusedPath = nil; diff = "Выберите файл, чтобы посмотреть изменения" }
            } catch { self.error = error.localizedDescription }
        }
    }
    func preview(_ change: GitChange) {
        guard let snapshot else { return }
        focusedPath = change.path; diff = "Загружаем изменения…"
        previewTask?.cancel()
        previewTask = Task {
            do {
                let value = try await publisher.diff(snapshot, file: change)
                guard !Task.isCancelled, focusedPath == change.path else { return }
                diff = value.isEmpty ? "Нет текстовых изменений. Файл мог изменить права или тип." : value
            } catch { if !Task.isCancelled { diff = error.localizedDescription } }
        }
    }
    func selectAll() { selected = Set(snapshot?.changes.filter { !$0.isSensitive }.map(\.path) ?? []) }
    func commit() {
        guard canCommit, let expected = snapshot else { return }
        let paths = selected, text = message
        busy = "Создаём локальный коммит"; error = nil; notice = nil; pushPlan = nil
        Task {
            defer { busy = nil }
            do {
                let sha = try await publisher.commit(expected, paths: paths, message: text)
                message = ""; selected = []; focusedPath = nil; diff = "Выберите файл, чтобы посмотреть изменения"
                snapshot = try await publisher.snapshot(path: project.path, remote: expected.remote)
                notice = "Коммит \(sha.prefix(7)) создан локально. Теперь можно подготовить публикацию."
            } catch { self.error = error.localizedDescription + "\nСайт не обновлён. Если Git успел подготовить файлы, они сохранятся в проекте; обновите список перед повтором." }
        }
    }
    func prepare() {
        guard canPrepare, let expected = snapshot, let configuration else { return }
        guard siteURL.isEmpty || productionURL != nil else { error = "Адрес сайта должен начинаться с https://"; return }
        busy = "Проверяем ветку на GitHub"; error = nil; notice = nil
        Task {
            defer { busy = nil }
            do {
                let plan = try await publisher.preparePush(expected, configuration: configuration)
                try await save(configuration)
                confirmedRepository = configuration.repositoryURL
                if plan.commits.isEmpty { notice = "Все локальные коммиты этой ветки уже отправлены." }
                else { pushPlan = plan; showingConfirmation = true }
            } catch { self.error = error.localizedDescription }
        }
    }
    func push() {
        guard busy == nil, let plan = pushPlan else { return }
        showingConfirmation = false; busy = "Отправляем коммиты в GitHub"; error = nil; notice = nil
        Task {
            defer { busy = nil }
            do {
                let sha = try await publisher.push(plan)
                pushedSHA = sha; pushPlan = nil
                notice = "Коммиты отправлены. Публикацию выполняет подключённый Vercel."
                startMonitoring(remote: plan.snapshot.remoteURL, sha: sha)
            } catch { self.error = error.localizedDescription + "\nКоммит сохранён локально. Отправку можно подготовить повторно после проверки." }
        }
    }
    func checkDeployment() {
        guard let sha = pushedSHA, let remote = snapshot?.remoteURL else { return }
        startMonitoring(remote: remote, sha: sha)
    }
    private func startMonitoring(remote: String, sha: String) {
        monitorTask?.cancel()
        deployment = .init(phase: .waiting, message: "Ожидаем продакшен-деплой Vercel")
        monitorTask = Task { [weak self] in
            for _ in 0..<60 {
                guard !Task.isCancelled else { return }
                let state = await VercelDeploymentMonitor.check(remote: remote, sha: sha)
                guard !Task.isCancelled, let self else { return }
                self.deployment = state
                if [.ready, .failed, .unavailable].contains(state.phase) { return }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
            self?.deployment = .init(phase: .unavailable, message: "Подтверждение Vercel не получено. Проверьте подключение Git и сборку в панели Vercel")
        }
    }
    func close() { monitorTask?.cancel(); previewTask?.cancel() }
}

struct PublicationView: View {
    @ObservedObject var model: PublicationModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.project.name).font(.system(size: 21, weight: .semibold))
                    if let snapshot = model.snapshot {
                        Label("\(snapshot.branch)  →  \(GitPublisher.githubRepository(snapshot.remoteURL) ?? snapshot.remote)", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    } else { Text("Локальные изменения → коммит → Vercel").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { model.refresh() } label: { Label("Обновить", systemImage: "arrow.clockwise") }.disabled(model.busy != nil)
                    .keyboardShortcut("r", modifiers: .command)
            }.padding(20)
            Divider()
            VSplitView {
                HSplitView {
                    files.frame(minWidth: 235, idealWidth: 260, maxWidth: 330)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.focusedPath ?? "Просмотр изменений").font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).padding(12)
                        Divider()
                        ScrollView([.horizontal, .vertical]) {
                            Text(model.diff).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                        }.background(Color(nsColor: .textBackgroundColor))
                    }.frame(minWidth: 300, maxWidth: .infinity)
                }.frame(minHeight: 210, idealHeight: 330)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Сообщение коммита").font(.system(size: 12, weight: .medium))
                    HStack(alignment: .top, spacing: 12) {
                        TextEditor(text: $model.message).font(.system(size: 13)).frame(minHeight: 50, maxHeight: 80)
                            .padding(3).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                            .accessibilityLabel("Сообщение коммита").disabled(model.busy != nil)
                        Button("Создать коммит") { model.commit() }.disabled(!model.canCommit).controlSize(.large)
                    }
                    Text("В коммит попадут выбранные файлы целиком. Он останется на Mac до отправки.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(16).frame(minHeight: 130, maxHeight: 160)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 16) {
                    Text("Vercel").font(.system(size: 13, weight: .semibold))
                    TextField("Продакшен-ветка", text: $model.productionBranch).frame(width: 115).accessibilityLabel("Продакшен-ветка")
                        .onChange(of: model.productionBranch) { _ in model.connectionConfirmed = false }
                    TextField("https://ваш-сайт.ru · необязательно", text: $model.siteURL).accessibilityLabel("Адрес опубликованного сайта")
                }.disabled(model.busy != nil)
                Toggle("Эта ветка подключена к Production в Vercel", isOn: $model.connectionConfirmed)
                    .font(.system(size: 12)).disabled(model.busy != nil)
                if let snapshot = model.snapshot, model.productionBranch != snapshot.branch {
                    Text("Сейчас открыта \(snapshot.branch). Для публикации переключите проект в \(model.productionBranch) через Git.")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                if let state = model.deployment { deployment(state) }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).lineLimit(5)
                } else if let notice = model.notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    if let busy = model.busy { ProgressView().controlSize(.small); Text(busy).font(.system(size: 12)) }
                    else { Text("\(model.selected.count) файлов выбрано").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Открыть Vercel") { NSWorkspace.shared.open(URL(string: "https://vercel.com/dashboard")!) }
                    Button("Подготовить публикацию…") { model.prepare() }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.canPrepare)
                }
            }.padding(16)
        }
        .frame(minWidth: 740, idealWidth: 860, minHeight: 650, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showingConfirmation) {
            if let plan = model.pushPlan { confirmation(plan) }
        }
    }
    private var files: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Изменения · \(model.snapshot?.changes.count ?? 0)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Menu {
                    Button("Выбрать все доступные") { model.selectAll() }
                    Button("Снять выбор") { model.selected = [] }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Выбор файлов")
            }.padding(12)
            Divider()
            if let snapshot = model.snapshot, snapshot.changes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 24)).accessibilityHidden(true)
                    Text("Нет локальных изменений").font(.system(size: 12, weight: .medium))
                    Text("Готовые коммиты можно отправить кнопкой ниже.").font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
            } else {
                List(model.snapshot?.changes ?? []) { file in
                    HStack(spacing: 6) {
                        Toggle(isOn: Binding(get: { model.selected.contains(file.path) }, set: { checked in
                            if checked { model.selected.insert(file.path) } else { model.selected.remove(file.path) }
                        })) { EmptyView() }.toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Включить \(file.path)")
                            .disabled(file.isSensitive || model.busy != nil)
                        Button { model.preview(file) } label: {
                            HStack(spacing: 7) {
                                Text(file.status.trimmingCharacters(in: .whitespaces)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 21)
                                Text(file.path).font(.system(size: 12)).lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                                if file.isSensitive { Image(systemName: "lock").foregroundStyle(.secondary).help("Локальные секреты не включаются из Portlight") }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.padding(.vertical, 3).listRowBackground(model.focusedPath == file.path ? Color.accentColor.opacity(0.12) : Color.clear)
                }.listStyle(.plain)
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    private func deployment(_ state: VercelDeploymentState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.phase == .ready ? "checkmark.circle.fill" : state.phase == .failed ? "exclamationmark.triangle" : "cloud")
                .foregroundStyle(state.phase == .ready ? Color.green : state.phase == .failed ? Color.orange : Color.secondary)
            Text(state.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let url = state.detailsURL { Link("Сборка", destination: url) }
            if state.phase == .ready {
                if let url = model.productionURL ?? state.siteURL { Link("Открыть сайт", destination: url) }
            }
            if [.failed, .unavailable].contains(state.phase) { Button("Проверить") { model.checkDeployment() } }
        }
    }
    private func confirmation(_ plan: GitPushPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Опубликовать \(model.project.name)?").font(.system(size: 20, weight: .semibold))
            Text("\(GitPublisher.githubRepository(plan.snapshot.remoteURL) ?? plan.snapshot.remote) → \(plan.configuration.branch)")
                .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            Text("В GitHub уйдут все \(plan.commits.count) новых коммитов этой ветки. Подключённый Vercel запустит публикацию в Production.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.commits) { commit in Text("\(commit.sha.prefix(7))  \(commit.subject)").font(.system(size: 12)).textSelection(.enabled) }
                    Divider()
                    Text("Файлы в отправляемых изменениях · \(plan.files.count)").font(.system(size: 12, weight: .medium))
                    ForEach(plan.files, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 230)
            if !plan.snapshot.changes.isEmpty { Text("Незакоммиченные изменения останутся только на Mac.").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Button("Отмена") { model.showingConfirmation = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Отправить в продакшен") { model.push() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 540)
    }
}

@MainActor
final class PublicationWindowController: NSObject, NSWindowDelegate {
    let model: PublicationModel
    private let window: NSWindow
    init(project: ArchivedProject, save: @escaping (PublicationConfiguration) async throws -> Void) {
        model = PublicationModel(project: project, save: save)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Публикация — " + project.name; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PublicationView(model: model)); window.delegate = self
        window.minSize = NSSize(width: 760, height: 700)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }
    func show() { window.center(); NSApplication.shared.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); model.refresh() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.busy == nil }
    func windowWillClose(_ notification: Notification) { model.close() }
}

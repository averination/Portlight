import AppKit
import SwiftUI
import PortlightCore

struct ArchiveView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Проекты останутся здесь после остановки").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.vertical, 8)
            if let error = model.archiveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.bottom, 8)
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.horizontal, 18).padding(.bottom, 6)
            }
            if model.archivedProjects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "archivebox").font(.system(size: 30, weight: .ultraLight)).accessibilityHidden(true)
                    Text("Ваши локалки — под рукой").font(.system(size: 14, weight: .semibold))
                    Text("Найденные серверы сохранятся автоматически.\nИли добавьте папку старого проекта сейчас.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.archivedProjects) { project in
                            ArchiveRow(project: project, servers: model.activeServers(for: project), state: model.launchStates[project.id],
                                       chooseGroup: { model.chooseGroup($0, path: project.path) }, starting: model.launchingProjects.contains(project.id), busy: model.stopping || model.scanning,
                                       launch: { model.launch(project) }, publish: { model.publish(project) }, open: model.open,
                                       select: { model.chooseRecipe($0, project: project) },
                                       reveal: { model.reveal(project.path) }, forget: { model.forget(project) },
                                       showActive: { model.showActive(project) }, grantFolder: { model.addProject(initialPath: project.path) }, refreshRecipes: { model.refreshRecipes(project) }, log: { model.openLog(project) })
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 5)
                }.frame(maxHeight: .infinity)
            }
            HStack {
                Text("Запуск только по нажатию").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { model.addProject() } label: { Label("Добавить проект", systemImage: "plus") }
                    .controlSize(.small)
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }.frame(maxHeight: .infinity)
    }
}

private struct ArchiveRow: View {
    let project: ArchivedProject
    let servers: [Server]
    let state: LaunchState?
    let chooseGroup: (ProjectGroupChoice) -> Void
    let starting: Bool
    let busy: Bool
    let launch: () -> Void
    let publish: () -> Void
    let open: (URL?) -> Void
    let select: (LaunchRecipe) -> Void
    let reveal: () -> Void
    let forget: () -> Void
    let showActive: () -> Void
    let grantFolder: () -> Void
    let refreshRecipes: () -> Void
    let log: () -> Void
    private var waiting: Bool { starting || state?.isRunning == true }
    private var exists: Bool { FileManager.default.fileExists(atPath: project.path) }
    private var recipes: [LaunchRecipe] { project.availableRecipes ?? [project.recipe].compactMap { $0 } }
    private var currentURL: URL? { servers.first.flatMap { server in server.ports.first.flatMap { server.url(for: $0) } } }
    private var path: String { return project.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: servers.isEmpty ? "folder" : "network").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Menu {
                    Button("Опубликовать в Vercel…", action: publish)
                    Menu("Группа проекта") {
                        ForEach(ProjectGroupChoice.allCases, id: \.self) { value in
                            Button { chooseGroup(value) } label: {
                                if value == project.groupChoice { Label(value.rawValue, systemImage: "checkmark") }
                                else { Text(value.rawValue) }
                            }
                        }
                    }.disabled(busy)
                    Divider()
                    Button("Показать папку", action: reveal)
                    Button("Обновить команды", action: refreshRecipes)
                    Button("Выбрать папку / дать доступ…", action: grantFolder)
                    Divider()
                    Button("Убрать из архива", role: .destructive, action: forget)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Действия с проектом \(project.name)")
                    .accessibilityLabel("Действия с проектом \(project.name)")
            }
            Text(path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(path)
            Button { publish() } label: { Label("Опубликовать…", systemImage: "arrow.up.to.line") }
                .buttonStyle(.borderless).font(.system(size: 11)).disabled(!exists || busy)
                .help("Посмотреть изменения, создать коммит и отправить в Vercel")
            if !exists {
                Label("Папка недоступна — добавьте её заново", systemImage: "folder.badge.questionmark")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let currentURL {
                Text(currentURL.absoluteString).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                HStack {
                    Label("Работает", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("К серверам", action: showActive).controlSize(.small)
                    Button("Открыть") { open(currentURL) }.controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(recipes) { recipe in Button(recipe.display) { select(recipe) } }
                        if recipes.isEmpty {
                            Button("Статическая папка · Python HTTP") { select(ProjectCatalog.staticPython) }
                        }
                    } label: {
                        Text(project.recipe?.display ?? "Выбрать способ запуска")
                            .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }.menuStyle(.borderlessButton).disabled(waiting || !exists).help("Команда запуска проекта")
                    Spacer(minLength: 0)
                    if waiting { ProgressView().controlSize(.small).frame(width: 16) }
                    Button(waiting ? "Запускается…" : "Запустить", action: launch)
                        .controlSize(.small).disabled(waiting || !exists || project.recipe == nil || busy)
                        .help("Запустить \(project.name) из сохранённой папки")
                }
                if let state {
                    HStack(alignment: .top, spacing: 8) {
                        Text(state.message)
                            .foregroundStyle(state.isFailure ? Color.orange : Color.secondary)
                        Spacer(minLength: 0)
                        Button("Журнал", action: log).buttonStyle(.borderless)
                    }.font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                } else if let seen = project.lastSeen {
                    Text("Работал \(seen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("Сохранён для быстрого запуска").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

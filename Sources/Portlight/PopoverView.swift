import AppKit
import SwiftUI
import PortlightCore

struct PopoverView: View {
    @ObservedObject var model: AppModel
    var notchStyle = false
    @State private var expanded: Set<ProcessIdentity> = []
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.horizontal, 18)
            if let batch = model.pendingBatch { confirmation(batch) }
            else if model.showScope { scope }
            else { content }
            Divider().padding(.horizontal, 18)
            footer
        }
        .frame(width: 404, height: 540)
        .background { if !notchStyle { Rectangle().fill(.regularMaterial) } }
        .environment(\.colorScheme, notchStyle ? .dark : colorScheme)
    }
    @Environment(\.colorScheme) private var colorScheme
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").font(.system(size: 22, weight: .medium)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Portlight").font(.system(size: 17, weight: .semibold))
                Text("Локальные серверы").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.showScope.toggle(); model.pendingBatch = nil } label: {
                Image(systemName: model.showScope ? "xmark" : "info.circle").frame(width: 28, height: 30)
            }.buttonStyle(.borderless).help("Область поиска и безопасность").accessibilityLabel("Справка")
            Button { Task { await model.refresh() } } label: {
                if model.scanning { ProgressView().controlSize(.small).frame(width: 28, height: 30) }
                else { Image(systemName: "arrow.clockwise").frame(width: 28, height: 30) }
            }.buttonStyle(.borderless).disabled(model.scanning || model.stopping)
                .keyboardShortcut("r", modifiers: .command).help("Обновить · ⌘R").accessibilityLabel("Обновить серверы")
            Menu {
                Button("Скрыть Portlight") { model.onHideRequested?() }
                    .help("Вернуть: откройте Portlight через Spotlight или Finder")
                Divider()
                Button("Выйти из Portlight") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 28, height: 30)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Скрыть Portlight или полностью выйти").accessibilityLabel("Настройки и выход")
        }.padding(.horizontal, 18).padding(.vertical, 16)
    }
    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(ServerCategory.allCases, id: \.self) { category in
                    Button { model.selectedCategory = category; model.showArchive = false } label: {
                        HStack(spacing: 6) {
                            Text(category.rawValue).fontWeight(.medium)
                            Text(String(model.count(category))).monospacedDigit().foregroundStyle(.secondary)
                        }.font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(!model.showArchive && model.selectedCategory == category ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(!model.showArchive && model.selectedCategory == category ? .isSelected : [])
                        .help("Серверы: \(category.rawValue)")
                }
                Button { model.showArchive = true } label: {
                    HStack(spacing: 5) {
                        Text("Архив").fontWeight(.medium)
                        Text(String(model.archivedProjects.count)).foregroundStyle(.secondary).monospacedDigit()
                    }.font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(model.showArchive ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(model.showArchive ? .isSelected : [])
                    .help("Сохранённые проекты для повторного запуска")
            }.padding(4).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            if model.showArchive { ArchiveView(model: model) }
            else { activeContent }
        }
    }
    private var activeContent: some View {
        VStack(spacing: 0) {
            if let error = model.error { message(error, warning: true) }
            if let notice = model.notice {
                HStack(alignment: .top) {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                        .buttonStyle(.borderless).accessibilityLabel("Скрыть сообщение")
                }.padding(.horizontal, 18).padding(.vertical, 7)
            }
            let rows = model.rows(model.selectedCategory)
            if rows.isEmpty { emptyState.frame(maxHeight: .infinity) }
            else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { server in
                            ServerRow(server: server, groupChoice: model.groupChoice(for: server.projectPath), chooseGroup: { model.chooseGroup($0, path: server.projectPath) }, status: model.status(server), expanded: expanded.contains(server.id),
                                      busy: model.stopping || model.scanning || model.error != nil || !model.servers.contains(where: { $0.id == server.id }),
                                      toggle: { if !expanded.insert(server.id).inserted { expanded.remove(server.id) } },
                                      stop: { model.requestStop(server) }, publish: { model.publish(server) }, open: model.open, copy: model.copy, reveal: model.reveal)
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 6)
                }.frame(maxHeight: .infinity)
            }
            HStack(alignment: .center, spacing: 8) {
                Text("\(model.totalMemory) RAM").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 2)
                Button("Остановить \(model.activeServers.count) · \(model.selectedCategory.rawValue)…", role: .destructive) { model.requestStopAll() }
                    .font(.system(size: 11)).controlSize(.small)
                    .disabled(model.activeServers.isEmpty || model.stopping || model.scanning || model.error != nil)
                    .help("Только серверы выбранной вкладки. Сначала будет подтверждение.")
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.error == nil ? "checkmark.circle" : "eye.slash")
                .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(model.error != nil ? "Проверка недоступна" : model.selectedCategory == .codex ? "Нет серверов в группе Codex" : "Здесь пока спокойно")
                .font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center)
            Text(model.selectedCategory == .codex ? "Проверьте «Другие» — группу проекта\nможно изменить в меню его карточки." : "Подходящих активных TCP-серверов\nв этой категории не найдено.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
            Text("Bun · Python · Node.js · Deno").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity)
    }
    private func confirmation(_ batch: [Server]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Остановить \(batch.count) · \(model.pendingCategory.rawValue)?").font(.system(size: 16, weight: .semibold))
            Text("Только перечисленные процессы вашего пользователя. Закроются все их порты. Несохранённое состояние сервера может быть потеряно.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(batch) { server in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.projectName).font(.system(size: 12, weight: .medium))
                            Text("PID \(String(server.identity.pid)) · \(server.ports.map { ":\($0)" }.joined(separator: ", "))")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: .infinity)
            if model.needsSourceAcknowledgement {
                Toggle("Источник не определён. Я проверил проекты и хочу остановить именно эти процессы.", isOn: $model.acknowledgedUnknown)
                    .toggleStyle(.checkbox).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Мягкая остановка SIGTERM. Родители, терминалы и новые серверы не затрагиваются.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Отмена") { model.pendingBatch = nil }
                Spacer()
                Button("Остановить \(batch.count)", role: .destructive) { model.confirmStop() }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.stopping || model.error != nil || (model.needsSourceAcknowledgement && !model.acknowledgedUnknown))
            }
        }.padding(18).frame(maxHeight: .infinity)
    }
    private var scope: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scopeLine("Codex — группа проектов", "Подтверждённый запуск из Codex запоминается для папки проекта и сохраняется между перезапусками. В меню карточки можно выбрать группу вручную или вернуть автоматический выбор.")
                scopeLine("Группа и источник — разные сведения", "Группа помогает организовать проекты. Источник текущего процесса подтверждается отдельно по цепочке родителей и подписи Codex. Если связь потеряна, перед остановкой потребуется проверить проект даже в группе Codex. Путь и имя папки не используются как доказательство.")
                scopeLine("Область управления", "Только ваши Bun/Python/Node.js/Deno с локальным TCP LISTEN, порт ≥1024 и признаками dev-сервера. Системные службы, MCP/LSP и инспекторы исключаются. Один PID — одна карточка, все порты различимы.")
                scopeLine("Мягкая остановка", "Перед SIGTERM повторно проверяются владелец, PID, время запуска, executable, папка и порты. Принудительной остановки нет. Родитель может перезапустить сервер.")
                scopeLine("Архив проектов", "Найденные проекты сохраняются после остановки. Можно добавить старую папку вручную. Команда берётся из проекта и запускается только по кнопке. Повторный запуск работающего сервера блокируется; журнал доступен в карточке.")
                scopeLine("Лёгкое наблюдение", "Обновление: 3 с в открытой панели, 12 с в фоне; пауза на сон. CPU 100% = одно ядро, RAM — память только процесса. Команды и окружение не отображаются, чтобы не раскрыть секреты.")
                scopeLine("Notch", "Клик по вырезу раскрывает панель; Escape или клик снаружи закрывает. Чтобы вернуть скрытый Portlight, откройте приложение через Spotlight или Finder. На экране без выреза появится отдельное окно.")
                if model.inaccessibleCount > 0 { Text("Недоступных процессов: \(model.inaccessibleCount). Они не входят в область остановки.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(18)
        }.frame(maxHeight: .infinity)
    }
    private func scopeLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func message(_ text: String, warning: Bool) -> some View {
        Label(text, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
            .font(.system(size: 11)).foregroundStyle(warning ? Color.orange : Color.secondary)
            .lineLimit(3).padding(.horizontal, 18).padding(.vertical, 6)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.error != nil ? Color.orange : Color.green).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(model.freshness).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("Выйти") { NSApplication.shared.terminate(nil) }.font(.system(size: 11)).buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: .command).help("Закрыть Portlight. Серверы продолжат работу.")
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }
}

private struct ServerRow: View {
    let server: Server
    let groupChoice: ProjectGroupChoice
    let chooseGroup: (ProjectGroupChoice) -> Void
    let status: RowStatus
    let expanded: Bool
    let busy: Bool
    let toggle: () -> Void
    let stop: () -> Void
    let publish: () -> Void
    let open: (URL?) -> Void
    let copy: (URL?) -> Void
    let reveal: (String) -> Void
    private var memory: String { server.residentBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? "—" }
    private var cpu: String { server.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—" }
    private var statusColor: Color { status.phase == .failed ? .orange : status.phase == .stopped ? .secondary : .green }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(server.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                ProjectGroupMenu(choice: groupChoice, disabled: busy, select: chooseGroup)
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 26)
                }.buttonStyle(.borderless).accessibilityLabel("Сведения о \(server.projectName)")
            }
            HStack(spacing: 4) {
                Text(server.runtime.rawValue)
                Text("·")
                Text(status.phase == .running ? "Работает" : status.phase == .stopping ? "Завершается…" : status.phase == .stopped ? "Завершён" : "Требует внимания")
                    .foregroundStyle(status.phase == .running ? Color.secondary : statusColor)
                Spacer()
                Text("\(cpu) · \(memory)").monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if !server.sourceVerified { Text("Источник не определён").font(.system(size: 10)).foregroundStyle(.secondary) }
            ForEach(server.ports, id: \.self) { port in
                HStack(spacing: 8) {
                    Text(server.url(for: port)?.absoluteString ?? "localhost:\(port)")
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { copy(server.url(for: port)) } label: { Image(systemName: "doc.on.doc").frame(width: 26, height: 26) }
                        .buttonStyle(.borderless).help("Скопировать адрес").accessibilityLabel("Скопировать адрес порта \(String(port))")
                    Button("Открыть") { open(server.url(for: port)) }.controlSize(.small).disabled(status.phase == .stopped)
                        .contextMenu {
                            Button("Открыть HTTPS") {
                                if let url = server.url(for: port), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) { parts.scheme = "https"; open(parts.url) }
                            }
                        }
                }
            }
            HStack {
                Text("PID \(String(server.identity.pid))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Опубликовать…", action: publish).controlSize(.small).disabled(busy)
                Button("Остановить", role: .destructive, action: stop).controlSize(.small).disabled(busy || status.phase == .stopped)
                    .help("SIGTERM только этому процессу, включая все его порты")
            }
            if status.phase == .failed || status.phase == .stopped {
                Text(status.message).font(.system(size: 11)).foregroundStyle(statusColor).fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                Divider()
                Button { reveal(server.cwd) } label: { Label(server.cwd, systemImage: "folder").font(.system(size: 11)).lineLimit(3).truncationMode(.middle) }
                    .buttonStyle(.borderless).help(server.cwd)
                Text(server.groupDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(server.sourceDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Родитель: PID \(String(server.parentPID)) · \(server.evidence)").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(server.executable).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                if server.exposedToLAN { Label("Все интерфейсы · возможен доступ из сети", systemImage: "network").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }.padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

struct ProjectGroupMenu: View {
    let choice: ProjectGroupChoice
    var disabled = false
    let select: (ProjectGroupChoice) -> Void
    var body: some View {
        Menu {
            ForEach(ProjectGroupChoice.allCases, id: \.self) { value in
                Button { select(value) } label: {
                    if value == choice { Label(value.rawValue, systemImage: "checkmark") }
                    else { Text(value.rawValue) }
                }
            }
        } label: { Image(systemName: "folder.badge.gearshape").frame(width: 26, height: 26) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(disabled)
            .help("Группа проекта · " + choice.rawValue).accessibilityLabel("Группа проекта")
    }
}

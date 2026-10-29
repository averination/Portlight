import AppKit
import SwiftUI
import PortlightCore
import Darwin

@main
struct PortlightMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--diagnose") {
            Task {
                do {
                    let service = ServerService()
                    await service.setProjectGroups(try await ProjectArchive().all())
                    let result = try await service.scan()
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try encoder.encode(result), as: UTF8.self))
                    exit(0)
                } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if arguments.contains("--archive-list") || arguments.contains("--archive-import") {
            Task {
                do {
                    let archive = ProjectArchive()
                    let projects: [ArchivedProject]
                    if let index = arguments.firstIndex(of: "--archive-import"), arguments.indices.contains(index + 1) {
                        let name = arguments.firstIndex(of: "--name").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                        projects = try await archive.add(path: arguments[index + 1], name: name)
                    } else { projects = try await archive.all() }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try encoder.encode(projects), as: UTF8.self)); exit(0)
                } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class UtilityPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// An accessory app anchored to the hardware notch. No NSStatusItem is created.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var fallbackWindow: NSPanel?
    private var notch: NotchController?
    private var publicationWindows: [UUID: PublicationWindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if args.contains("--display-info") {
            for screen in NSScreen.screens {
                print("screen=\(screen.localizedName) frame=\(screen.frame) safeTop=\(screen.safeAreaInsets.top) scale=\(screen.backingScaleFactor) left=\(String(describing: screen.auxiliaryTopLeftArea)) right=\(String(describing: screen.auxiliaryTopRightArea))")
            }
            NSApplication.shared.terminate(nil); return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != getpid() }) {
            NSApplication.shared.terminate(nil); return
        }
        model = AppModel()
        notch = NotchController(model: model)
        notch?.onWillOpen = { [weak self] in self?.fallbackWindow?.close() }
        model.onHideRequested = { [weak self] in
            // Let the native menu finish before ordering out its source window.
            DispatchQueue.main.async { self?.hidePresentation() }
        }
        model.onRevealArchive = { [weak self] in
            guard let self, self.model.notchEnabled else { return }
            if self.notch?.isExpanded != true && self.fallbackWindow?.isVisible != true { self.showPanel() }
            self.model.showArchive = true
        }
        model.onChange = { [weak self] in self?.notch?.update() }
        model.onPublishRequested = { [weak self] project in
            guard let self else { return }
            self.notch?.close(); self.fallbackWindow?.close()
            if self.publicationWindows[project.id] == nil {
                self.publicationWindows[project.id] = PublicationWindowController(project: project) { [weak self] configuration in
                    guard let self else { return }
                    try await self.model.savePublication(configuration, for: project)
                }
            }
            self.publicationWindows[project.id]?.show()
        }
        model.start()
        if args.contains("--show") || notch?.available != true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.showPanel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
    }
    private func showPanel() {
        if !model.notchEnabled {
            model.notchEnabled = true
            notch?.configure()
            model.start()
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        if notch?.matches(screen) == true {
            notch?.open()
        } else {
            // An explicit app reopen still works on an external/non-notched display,
            // or in a Space where the notch overlay is unavailable. No menu-bar slot.
            if fallbackWindow == nil {
                let window = UtilityPanel(contentRect: NSRect(x: 0, y: 0, width: 404, height: 540),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Portlight"; window.isReleasedWhenClosed = false
                window.level = .floating; window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                window.contentView = NSHostingView(rootView: PopoverView(model: model))
                window.delegate = self
                fallbackWindow = window
            }
            fallbackWindow?.center()
            NSApplication.shared.activate(ignoringOtherApps: true)
            fallbackWindow?.makeKeyAndOrderFront(nil)
            model.isVisible = true
            Task { await model.refresh() }
        }
    }
    private func hidePresentation() {
        model.notchEnabled = false
        notch?.configure()
        fallbackWindow?.close()
        model.pendingBatch = nil; model.isVisible = false
        model.suspend()
    }
    func windowWillClose(_ notification: Notification) {
        model.isVisible = false; model.pendingBatch = nil
    }
    @objc private func wokeUp() {
        guard model.notchEnabled else { return }
        notch?.configure(); model.start()
    }
    @objc private func willSleep() {
        notch?.hideForSleep(); fallbackWindow?.close(); model.suspend()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let controller = publicationWindows.values.first(where: { $0.model.busy != nil }) {
            controller.show()
            return .terminateCancel
        }
        return .terminateNow
    }

}

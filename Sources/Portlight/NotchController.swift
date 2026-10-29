import AppKit
import SwiftUI
import QuartzCore
import PortlightCore

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // AppKit's normal window constraint would push this HUD below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    var escape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { escape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape?() } else { super.keyDown(with: event) }
    }
}

/// One window and one backing surface throughout idle → hover → expanded.
@MainActor
final class NotchController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: NotchPanel
    private let surface: NotchSurface
    private var geometry: NotchGeometry?
    private var displayID: CGDirectDisplayID?
    private var collapseTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) var phase: NotchPhase = .idle
    var onExpanded: ((Bool) -> Void)?
    var onWillOpen: (() -> Void)?
    var available: Bool { geometry != nil && panel.isVisible }
    var isExpanded: Bool { phase == .expanded && panel.isVisible }

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        surface = NotchSurface(model: model)
        super.init()
        panel.contentView = surface
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        // The compact trigger must receive clicks in the menu-bar band, not sit behind it.
        // Only the cutout footprint is opaque/hit-testable at this level.
        panel.level = .statusBar
        // Do not join fullscreen Spaces as an auxiliary overlay. Reopening the app provides an ordinary-window fallback.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isMovable = false; panel.animationBehavior = .none; panel.delegate = self
        panel.escape = { [weak self] in self?.close() }
        surface.entered = { [weak self] in self?.entered() }
        surface.exited = { [weak self] in self?.exited() }
        surface.clicked = { [weak self] in
            guard let self else { return }
            if self.isExpanded { self.close() } else { self.open() }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.outsideClick() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53, self.isExpanded { self.close(); return nil }
            // Mouse clicks in this app can belong to its own menus or folder chooser.
            // The global monitor handles real clicks in other applications.
            return event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configure() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close(); self?.configure() }
        })
        configure()
    }


    func configure() {
        collapseTask?.cancel(); contentTask?.cancel()
        let wasExpanded = phase == .expanded
        phase = .idle
        if wasExpanded { model.isVisible = false; model.pendingBatch = nil; onExpanded?(false) }
        surface.setPhase(.idle, showContent: false)
        panel.level = .statusBar
        guard model.notchEnabled, let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0 && $0.safeAreaInsets.top > 0
        }), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.frame.height - screen.safeAreaInsets.top > 600 else {
            panel.orderOut(nil); geometry = nil; displayID = nil; return
        }
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        geometry = NotchGeometry(screen: screen.frame, topInset: screen.safeAreaInsets.top, leftAreaMaxX: left.maxX, rightAreaMinX: right.minX)
        surface.topInset = geometry!.topInset; surface.notchWidth = geometry!.notchWidth
        panel.setFrame(geometry!.frame(.idle), display: true)
        panel.orderFrontRegardless()
        update()
    }
    func update() { surface.summary = model.error == nil ? model.summary : "Проверка недоступна"; surface.activeCount = model.servers.count }
    func matches(_ screen: NSScreen?) -> Bool {
        guard let screen, let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return id.uint32Value == displayID && available && panel.isOnActiveSpace
    }
    func open() {
        guard available else { return }
        collapseTask?.cancel()
        onWillOpen?()
        if phase != .expanded { model.selectedCategory = .codex; model.showArchive = false; model.pendingBatch = nil; model.showScope = false }
        transition(.expanded)
        panel.makeKeyAndOrderFront(nil)
        model.isVisible = true; onExpanded?(true)
        Task { await model.refresh() }
    }
    func close() {
        guard phase == .expanded else { return }
        model.pendingBatch = nil; model.isVisible = false
        let hover = geometry?.containsActivationPoint(NSEvent.mouseLocation) == true
        transition(hover ? .hover : .idle)
        panel.resignKey()
        onExpanded?(false)
    }
    func hideForSleep() { close(); panel.orderOut(nil) }
    private func outsideClick() {
        if isExpanded {
            let point = surface.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if !surface.containsSurfacePoint(point) { close() }
        }
    }
    // Outside-click monitors and Escape dismiss the panel. Resigning key status alone
    // also happens while SwiftUI creates menus or a folder chooser, so it is not dismissal.
    private func entered() {
        collapseTask?.cancel()
        if phase == .idle { transition(.hover) }
    }
    private func exited() {
        guard phase == .hover else { return }
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled, let self, self.phase == .hover,
                  self.geometry?.containsActivationPoint(NSEvent.mouseLocation) != true else { return }
            self.transition(.idle)
        }
    }
    private func transition(_ next: NotchPhase) {
        guard let geometry else { return }
        contentTask?.cancel(); phase = next
        // The full cutout grows from the screen edge, including the menu-bar band.
        // Native popup menus have their own higher level.
        panel.level = .statusBar
        surface.setPhase(next, showContent: false)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : (next == .expanded ? 0.30 : 0.22)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1)
            panel.animator().setFrame(geometry.frame(next), display: true)
        }
        if next == .expanded {
            contentTask = Task { [weak self] in
                if !reduced { try? await Task.sleep(nanoseconds: 240_000_000) }
                guard !Task.isCancelled, let self, self.phase == .expanded else { return }
                self.surface.setPhase(next, showContent: true)
            }
        }
    }
}

private final class NotchSurface: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    var clicked: (() -> Void)?
    var summary = "Нет активных серверов" { didSet { setAccessibilityLabel("Portlight. " + summary); toolTip = "Portlight · " + summary + " · нажмите, чтобы открыть" } }
    var activeCount = 0 {
        didSet {
            needsDisplay = true; needsLayout = true
            guard activeCount != oldValue, phase == .idle, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.6; pulse.toValue = 1; pulse.duration = 0.22
            layer?.add(pulse, forKey: "countChanged")
        }
    }
    var topInset: CGFloat = 0
    var notchWidth: CGFloat = 185
    private var contentBounds: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - topInset)) }
    private var outline: CGPath { NotchOutline.surfacePath(in: bounds, topInset: topInset) }
    private var interactionBounds: NSRect {
        phase == .expanded ? bounds : NSRect(x: bounds.midX - notchWidth / 2, y: 0, width: notchWidth, height: bounds.height)
    }
    private var phase: NotchPhase = .idle
    private var area: NSTrackingArea?
    private let lighting = NotchLighting()
    private let body = CAShapeLayer()
    private let activity = CAShapeLayer()
    private let host: NSHostingView<PopoverView>
    init(model: AppModel) {
        host = NSHostingView(rootView: PopoverView(model: model, notchStyle: true))
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        appearance = NSAppearance(named: .darkAqua)
        body.fillColor = NSColor.black.cgColor
        layer?.addSublayer(body)
        layer?.addSublayer(lighting.layer)
        activity.fillColor = NSColor.systemGreen.cgColor
        layer?.addSublayer(activity)
        addSubview(host)
        host.isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityHelp("Нажмите, чтобы открыть локальные серверы")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
    func setPhase(_ value: NotchPhase, showContent: Bool, animated: Bool = true) {
        phase = value
        lighting.setActive(value == .hover, animated: animated)
        host.isHidden = value != .expanded || !showContent
        if !host.isHidden {
            host.alphaValue = animated ? 0 : 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                host.animator().alphaValue = 1
            }
        }
        // The expanded hosting view owns accessibility; the compact trigger is a single button.
        setAccessibilityElement(value != .expanded)
        needsDisplay = true; needsLayout = true
        updateTrackingAreas()
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.frame = bounds; body.path = outline; body.contentsScale = window?.backingScaleFactor ?? 2
        activity.frame = bounds
        activity.path = CGPath(ellipseIn: CGRect(x: bounds.midX - 1.5, y: 1.5, width: 3, height: 3), transform: nil)
        activity.isHidden = phase == .expanded || activeCount == 0
        CATransaction.commit()
        lighting.layout(contentBounds: contentBounds, outline: outline, scale: window?.backingScaleFactor ?? 2)
        host.frame = NSRect(x: (bounds.width - 404) / 2, y: contentBounds.maxY - 554, width: 404, height: 540)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: interactionBounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(next); area = next
    }
    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if phase != .expanded || point.y >= contentBounds.maxY { clicked?() }
    }
    func containsSurfacePoint(_ point: NSPoint) -> Bool {
        guard point.y >= bounds.minY, point.y <= bounds.maxY else { return false }
        let testPoint = NSPoint(x: point.x, y: point.y == bounds.maxY ? point.y - 0.01 : point.y)
        return outline.contains(testPoint)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactionBounds.contains(local) || (phase != .expanded && local.y == interactionBounds.maxY &&
            local.x >= interactionBounds.minX && local.x < interactionBounds.maxX) else { return nil }
        if phase != .expanded { return self }
        guard containsSurfacePoint(local) else { return nil }
        if local.y >= contentBounds.maxY { return self }
        return super.hitTest(point)
    }
}

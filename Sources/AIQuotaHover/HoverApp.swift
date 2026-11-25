import AppKit
import QuartzCore
import SwiftUI

/// Custom `NSHostingView` subclass that suppresses AppKit's automatic `NSTextInputClient` / `TSMDocument`
/// registration unless an explicit text field is being edited (`allowsTextInput == true`).
/// Without this override, `NSHostingView` creates a Roman/non-editable `NSTextInputContext` on mouse/button
/// interactions, which can cause macOS `HIToolbox` to flip non-Roman Input Methods (Pinyin/Sogou/Rime/WeChat/etc.) to `ABC`.
final class SilentHostingView<Content: View>: NSHostingView<Content> {
    var allowsTextInput: Bool = false

    override var inputContext: NSTextInputContext? {
        allowsTextInput ? super.inputContext : nil
    }

    override var acceptsFirstResponder: Bool {
        allowsTextInput
    }
}

final class FloatingHoverPanel: NSPanel {
    var allowsKeyStatus: Bool = false

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.becomesKeyOnlyIfNeeded = true
        self.ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { allowsKeyStatus }
    override var canBecomeMain: Bool { false }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard allowsKeyStatus else { return false }
        return super.makeFirstResponder(responder)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if allowsKeyStatus, event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case "v": if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
                case "c": if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
                case "x": if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
                case "a": if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
                default: break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class ButtonHoverResponder: NSResponder {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?

    override func mouseEntered(with event: NSEvent) { onEntered?() }
    override func mouseExited(with event: NSEvent) { onExited?() }
}

@MainActor
final class HoverStatusBarController: NSObject {
    private static let autosaveKey = "AIQuotaHoverStatusItem"
    private static let preferredPosDefaultsKey = "NSStatusItem Preferred Position AIQuotaHoverStatusItem"

    private let statusItem: NSStatusItem
    private let panel: FloatingHoverPanel
    private var hostingView: SilentHostingView<QuotaPanelView>?
    private let viewModel: QuotaViewModel
    private let hoverResponder = ButtonHoverResponder()
    private var trackingArea: NSTrackingArea?

    private var showWorkItem: DispatchWorkItem?
    private var hideGeneration: UInt64 = 0
    private var isClosing: Bool = false
    private var dismissCheckTimer: Timer?
    private var outsideSince: Date?
    private var globalClickMonitor: Any?
    private var spaceChangeObserver: NSObjectProtocol?

    private var shouldHoldPanelOpen: Bool {
        viewModel.isPinned
            || viewModel.isShowingSettings
            || viewModel.isPerformingModalAction
            || Date() < viewModel.holdPanelUntil
    }

    override init() {
        if UserDefaults.standard.object(forKey: Self.preferredPosDefaultsKey) == nil {
            UserDefaults.standard.set(258.0, forKey: Self.preferredPosDefaultsKey)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveKey
        self.statusItem = item
        self.viewModel = QuotaViewModel()
        self.panel = FloatingHoverPanel(contentRect: NSRect(x: 0, y: 0, width: 336, height: 318))
        super.init()

        setupPanel()
        setupStatusItem()
        setupGlobalMonitors()

        viewModel.onStatusChange = { [weak self] urgent in
            self?.updateStatusButtonAppearance(urgentItem: urgent)
        }
        viewModel.onLayoutChange = { [weak self] in
            self?.relayoutPanelIfVisible()
        }
        viewModel.onRequestKeyFocus = { [weak self] in
            guard let self else { return }
            self.hostingView?.allowsTextInput = true
            self.panel.allowsKeyStatus = true
            self.panel.makeKey()
        }
        viewModel.onReleaseKeyFocus = { [weak self] in
            self?.releaseKeyFocusIfNeeded()
        }
        viewModel.onEnsurePanelVisible = { [weak self] in
            guard let self else { return }
            if !self.panel.isVisible || self.isClosing {
                self.showPanel()
            } else {
                self.ensureDismissMonitorRunning()
                self.installOutsideClickMonitorIfNeeded()
            }
        }
        viewModel.onExitInlineSettings = { [weak self] in
            guard let self else { return }
            self.outsideSince = nil
            self.ensureDismissMonitorRunning()
            self.installOutsideClickMonitorIfNeeded()
        }
        updateStatusButtonAppearance(urgentItem: viewModel.mostUrgentItem)
    }

    func stop() {
        showWorkItem?.cancel()
        stopDismissMonitor()
        removeOutsideClickMonitor()
        if let obs = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceChangeObserver = nil
        }
        if let area = trackingArea, let button = statusItem.button {
            button.removeTrackingArea(area)
            trackingArea = nil
        }
        viewModel.stop()
    }

    private func releaseKeyFocusIfNeeded() {
        guard panel.allowsKeyStatus else { return }
        _ = panel.makeFirstResponder(nil)
        hostingView?.allowsTextInput = false
        panel.allowsKeyStatus = false
        panel.resignKey()
    }

    private func setupPanel() {
        let rootView = QuotaPanelView(
            viewModel: viewModel,
            onTogglePin: { [weak self] in self?.togglePin() }
        )
        let hosting = SilentHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hosting
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        hoverResponder.onEntered = { [weak self] in self?.scheduleHoverOpen() }
        hoverResponder.onExited = { [weak self] in self?.showWorkItem?.cancel() }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverResponder,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
    }

    private func setupGlobalMonitors() {
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                if !strongSelf.viewModel.isPinned {
                    strongSelf.forceHideImmediately()
                }
            }
        }
    }

    private func installOutsideClickMonitorIfNeeded() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                guard strongSelf.panel.isVisible,
                      !strongSelf.viewModel.isPinned,
                      !strongSelf.viewModel.isPerformingModalAction
                else { return }
                let mouse = NSEvent.mouseLocation
                let inPanel = strongSelf.panel.frame.contains(mouse)
                let inButton = strongSelf.statusButtonScreenFrame()?.contains(mouse) ?? false
                if !inPanel && !inButton {
                    strongSelf.viewModel.isShowingSettings = false
                    strongSelf.viewModel.holdPanelUntil = .distantPast
                    strongSelf.forceHideImmediately()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else if !panel.isVisible || isClosing {
            showPanel()
        } else {
            viewModel.isPinned = false
            viewModel.isShowingSettings = false
            viewModel.holdPanelUntil = .distantPast
            forceHideImmediately()
        }
    }

    private func updateStatusButtonAppearance(urgentItem: QuotaItem?) {
        guard let button = statusItem.button else { return }

        if let sym = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "AI 额度") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
            let img = sym.withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
        }

        if AppPreferences.shared.showPercentInMenuBar, let item = urgentItem {
            let pctStr = " \(Int(item.remainingPercent.rounded()))%"
            button.attributedTitle = NSAttributedString(
                string: pctStr,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: item.status == "critical"
                        ? NSColor.systemRed
                        : (item.status == "warning" ? NSColor.systemOrange : NSColor.labelColor)
                ]
            )
        } else {
            button.title = ""
        }
    }

    private func scheduleHoverOpen() {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.pressedMouseButtons != 0 {
            return
        }
        if panel.isVisible && !isClosing {
            outsideSince = nil
            ensureDismissMonitorRunning()
            return
        }

        showWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      let btnFrame = self.statusButtonScreenFrame(),
                      btnFrame.contains(NSEvent.mouseLocation),
                      !NSEvent.modifierFlags.contains(.command),
                      NSEvent.pressedMouseButtons == 0,
                      !self.hasCompetingPopupOrNotification(near: btnFrame)
                else { return }
                self.showPanel()
            }
        }
        showWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
    }

    private func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem.button,
              let win = button.window,
              button.bounds.width > 1
        else { return nil }
        let screenRect = win.convertToScreen(button.convert(button.bounds, to: nil))
        return screenRect.width > 1 ? screenRect : nil
    }

    private func resolveScreenAndVisibleFrame(for btnFrame: NSRect) -> (screen: NSScreen?, visibleFrame: NSRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(btnFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return (screen, visible)
    }

    private func relayoutPanelIfVisible() {
        guard panel.isVisible, !isClosing, let hosting = panel.contentView else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.isClosing else { return }
            let fit = hosting.fittingSize
            guard fit.width > 0 && fit.height > 0 else { return }
            if let btnFrame = self.statusButtonScreenFrame() {
                let (_, visibleFrame) = self.resolveScreenAndVisibleFrame(for: btnFrame)
                let x = max(visibleFrame.minX + 8, min(btnFrame.midX - fit.width / 2.0, visibleFrame.maxX - fit.width - 8))
                let y = max(visibleFrame.minY + 8, btnFrame.minY - fit.height - 6)
                self.panel.setFrame(NSRect(x: x, y: y, width: fit.width, height: fit.height), display: true, animate: true)
            } else {
                self.panel.setContentSize(fit)
            }
        }
    }

    /// Dynamically inspects screen geometry (`NSScreen.frame.maxY - visibleFrame.maxY`) and CoreGraphics
    /// window metadata so we never overlap an open menu/popover or top-right Notification Center banner.
    private func hasCompetingPopupOrNotification(near btnFrame: NSRect) -> Bool {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let primaryScreen = NSScreen.screens.first
        let primaryHeight = primaryScreen?.frame.height ?? 900
        let (activeScreen, _) = resolveScreenAndVisibleFrame(for: btnFrame)
        let menuBarHeight = max(24.0, (activeScreen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 28.0) + 4.0)

        let watchZone = NSRect(
            x: btnFrame.midX - 180,
            y: btnFrame.minY - 340,
            width: 360,
            height: 340
        )

        for info in infoList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer >= 1 && layer < 1000,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            else { continue }

            var cgRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &cgRect) else { continue }
            if cgRect.maxY <= menuBarHeight || cgRect.height <= 36 { continue }
            if let screenWidth = activeScreen?.frame.width, cgRect.width >= screenWidth * 0.85 { continue }

            let appKitRect = NSRect(
                x: cgRect.origin.x,
                y: primaryHeight - cgRect.origin.y - cgRect.height,
                width: cgRect.width,
                height: cgRect.height
            )
            if appKitRect.intersects(watchZone) {
                return true
            }
        }
        return false
    }

    private func showPanel() {
        guard let btnFrame = statusButtonScreenFrame() else { return }
        showWorkItem?.cancel()
        hideGeneration &+= 1
        isClosing = false
        outsideSince = nil
        panel.ignoresMouseEvents = false

        if let hosting = panel.contentView {
            let fit = hosting.fittingSize
            if fit.width > 0 && fit.height > 0 {
                panel.setContentSize(fit)
            }
        }

        let panelSize = panel.frame.size
        let (_, visibleFrame) = resolveScreenAndVisibleFrame(for: btnFrame)
        let x = max(visibleFrame.minX + 8, min(btnFrame.midX - panelSize.width / 2.0, visibleFrame.maxX - panelSize.width - 8))
        let targetY = max(visibleFrame.minY + 8, btnFrame.minY - panelSize.height - 6)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: x, y: targetY + 4))
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
            panel.animator().setFrameOrigin(NSPoint(x: x, y: targetY))
        }

        ensureDismissMonitorRunning()
        installOutsideClickMonitorIfNeeded()
        viewModel.setPanelVisible(true)
        Task { await viewModel.refreshIfStale(maxAge: 30) }
    }

    private func hidePanelAnimated() {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        panel.ignoresMouseEvents = true
        releaseKeyFocusIfNeeded()
        hideGeneration &+= 1
        let expectedGen = hideGeneration

        let endOrigin = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + 3)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
            panel.animator().setFrameOrigin(endOrigin)
        }, completionHandler: { [weak self] in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                guard strongSelf.hideGeneration == expectedGen, strongSelf.isClosing else { return }
                strongSelf.forceHideImmediately()
            }
        })

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let strongSelf = self, strongSelf.hideGeneration == expectedGen, strongSelf.isClosing else { return }
            strongSelf.forceHideImmediately()
        }
    }

    private func forceHideImmediately() {
        showWorkItem?.cancel()
        isClosing = false
        outsideSince = nil
        panel.ignoresMouseEvents = true
        releaseKeyFocusIfNeeded()
        removeOutsideClickMonitor()
        viewModel.setPanelVisible(false)
        panel.alphaValue = 0
        panel.orderOut(nil)
        stopDismissMonitor()
    }

    private func togglePin() {
        viewModel.isPinned.toggle()
        if !viewModel.isPinned {
            outsideSince = nil
            ensureDismissMonitorRunning()
            installOutsideClickMonitorIfNeeded()
        }
    }

    private func ensureDismissMonitorRunning() {
        guard dismissCheckTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in strongSelf.evaluateMouseHoverZone() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissCheckTimer = timer
    }

    private func stopDismissMonitor() {
        dismissCheckTimer?.invalidate()
        dismissCheckTimer = nil
    }

    private func evaluateMouseHoverZone() {
        if !panel.isVisible {
            stopDismissMonitor()
            return
        }
        if shouldHoldPanelOpen || isClosing || NSEvent.pressedMouseButtons != 0 {
            outsideSince = nil
            return
        }

        let mouse = NSEvent.mouseLocation
        if let btnFrame = statusButtonScreenFrame() {
            let inMenuBarStrip = mouse.y >= (btnFrame.minY - 2)
            let horizontallyOutsideOurButton = (mouse.x < btnFrame.minX || mouse.x > btnFrame.maxX)
            if (inMenuBarStrip && horizontallyOutsideOurButton) || hasCompetingPopupOrNotification(near: btnFrame) {
                forceHideImmediately()
                return
            }
        }

        let panelZone = panel.frame.insetBy(dx: -4, dy: -4)
        var inside = panelZone.contains(mouse)

        if !inside, let btnFrame = statusButtonScreenFrame() {
            let statusZone = btnFrame.insetBy(dx: 0, dy: -2)
            let gapHeight = max(0, btnFrame.minY - panel.frame.maxY)
            let bridgeRect = NSRect(
                x: min(btnFrame.minX - 8, panel.frame.midX - 30),
                y: panel.frame.maxY - 2,
                width: max(btnFrame.width + 16, 60),
                height: gapHeight + 4
            )
            inside = statusZone.contains(mouse) || bridgeRect.contains(mouse)
        }

        if inside {
            outsideSince = nil
        } else {
            let now = Date()
            if let since = outsideSince {
                if now.timeIntervalSince(since) >= 0.08 {
                    hidePanelAnimated()
                }
            } else {
                outsideSince = now
            }
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        forceHideImmediately()

        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "立即刷新全部额度", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let pinTitle = viewModel.isPinned ? "取消固定悬浮面板" : "固定悬浮面板"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(menuTogglePin), keyEquivalent: "p")
        pinItem.target = self
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "面板服务设置…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出悬浮额度栏", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func menuRefresh() { Task { await viewModel.refresh(force: true) } }

    @objc private func menuTogglePin() {
        viewModel.isPinned.toggle()
        if viewModel.isPinned { showPanel() } else { forceHideImmediately() }
    }

    @objc private func menuOpenSettings() {
        viewModel.openInlineSettings()
        showPanel()
    }

    @objc private func menuQuit() { NSApplication.shared.terminate(nil) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: HoverStatusBarController?
    private var lastExternalActiveApp: NSRunningApplication?
    private var appActivateObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        installStandardEditMenu()
        trackExternalFrontmostApp()
        self.controller = HoverStatusBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = appActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appActivateObserver = nil
        }
        controller?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !WebLoginController.shared.isWindowVisible,
              let prev = lastExternalActiveApp,
              !prev.isTerminated
        else { return }
        prev.activate()
    }

    private func trackExternalFrontmostApp() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != myPID {
            lastExternalActiveApp = front
        }
        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != myPID
            else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                self?.lastExternalActiveApp = NSRunningApplication(processIdentifier: pid)
            }
        }
    }

    private func installStandardEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }
}

@main
struct AIQuotaHoverMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

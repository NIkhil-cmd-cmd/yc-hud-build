//
//  AgentNotchPanel.swift
//  OpenHive — boring.notch window management (createBoringNotchWindow + positionWindow)
//

import AppKit
import SwiftUI

/// Non-activating panel matching boring.notch `BoringNotchWindow`.
final class AgentNotchWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentNotchPanelController {
    static let shared = AgentNotchPanelController()

    private var panel: AgentNotchWindow?
    private let viewModel = AgentNotchViewModel.shared
    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.adjustWindowPosition() }
        }
    }

    func show() {
        if panel == nil { createPanel() }
        adjustWindowPosition(changeAlpha: panel?.alphaValue == 0)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// boring.notch `adjustWindowPosition` / `positionWindow` — fixed window, content animates inside.
    func adjustWindowPosition(changeAlpha: Bool = false) {
        guard let panel else { return }
        viewModel.refreshClosedSize()

        if changeAlpha { panel.alphaValue = 0 }

        let size = NotchSizing.windowSize
        var frame = panel.frame
        frame.size = size
        frame.origin = NotchSizing.windowOrigin()
        panel.setFrame(frame, display: true)
        panel.alphaValue = 1
    }

    /// Legacy hook — window size is fixed; content handles expand/collapse.
    func reposition(animated: Bool = true) {
        adjustWindowPosition()
        if engineRunning() { viewModel.open() }
    }

    private func engineRunning() -> Bool {
        EngineBridge.shared.isExecuting || TaskRunState.shared.phase == .running
    }

    private func createPanel() {
        let content = AgentNotchView(vm: viewModel)
        let hosting = NSHostingView(rootView: content)
        let rect = NSRect(origin: NotchSizing.windowOrigin(), size: NotchSizing.windowSize)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]
        let p = AgentNotchWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)
        p.contentView = hosting
        panel = p
    }
}

//
//  AgentNotchViewModel.swift
//  OpenHive — open/close state (boring.notch BoringViewModel pattern)
//

import SwiftUI

enum AgentNotchState: Equatable {
    case closed
    case open
}

@MainActor
@Observable
final class AgentNotchViewModel {
    static let shared = AgentNotchViewModel()

    private(set) var notchState: AgentNotchState = .closed
    var notchSize: CGSize = NotchSizing.closedSize()
    var closedNotchSize: CGSize = NotchSizing.closedSize()
    var isHovering: Bool = false

    private init() {
        refreshClosedSize()
    }

    var effectiveClosedNotchHeight: CGFloat {
        closedNotchSize.height
    }

    func refreshClosedSize() {
        let closed = NotchSizing.closedSize()
        closedNotchSize = closed
        if notchState == .closed {
            notchSize = closed
        }
    }

    func open() {
        notchSize = NotchSizing.openNotchSize
        notchState = .open
    }

    func close() {
        refreshClosedSize()
        notchState = .closed
    }

    func isMouseHovering(at position: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let frame = NotchSizing.screenFrame() else { return false }
        let baseY = frame.maxY - notchSize.height
        let baseX = frame.midX - notchSize.width / 2
        return position.y >= baseY
            && position.x >= baseX
            && position.x <= baseX + notchSize.width
    }
}

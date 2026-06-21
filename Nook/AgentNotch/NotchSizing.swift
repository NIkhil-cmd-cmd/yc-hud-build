//
//  NotchSizing.swift
//  OpenHive — geometry from boring.notch sizing/matters.swift
//

import AppKit

enum NotchSizing {
    static let shadowPadding: CGFloat = 20
    static let openNotchSize = CGSize(width: 360, height: 138)
    static var windowSize: CGSize {
        CGSize(width: openNotchSize.width, height: openNotchSize.height + shadowPadding)
    }

    static let cornerRadiusInsets: (
        opened: (top: CGFloat, bottom: CGFloat),
        closed: (top: CGFloat, bottom: CGFloat)
    ) = (
        opened: (top: 19, bottom: 24),
        closed: (top: 6, bottom: 14)
    )

    /// Physical notch width + menu-bar height (boring.notch `getClosedNotchSize`).
    @MainActor
    static func closedSize(for screen: NSScreen? = NSScreen.main) -> CGSize {
        var notchWidth: CGFloat = 185
        var notchHeight: CGFloat = 32

        guard let screen else {
            return CGSize(width: notchWidth, height: notchHeight)
        }

        if let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right + 4
        }

        if screen.safeAreaInsets.top > 0 {
            notchHeight = screen.safeAreaInsets.top
        } else {
            notchHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 28)
        }

        return CGSize(width: notchWidth, height: notchHeight)
    }

    @MainActor
    static func screenFrame(for screen: NSScreen? = NSScreen.main) -> CGRect? {
        screen?.frame
    }

    /// Top-center anchor (boring.notch `positionWindow`).
    @MainActor
    static func windowOrigin(for screen: NSScreen? = NSScreen.main) -> NSPoint {
        guard let screen else { return .zero }
        let frame = screen.frame
        return NSPoint(
            x: frame.origin.x + (frame.width / 2) - windowSize.width / 2,
            y: frame.origin.y + frame.height - windowSize.height
        )
    }
}

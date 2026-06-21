//
//  OpenHiveTheme.swift
//  Liquid Glass design tokens for OpenHive panels
//

import SwiftUI

enum OpenHiveTheme {
    static let sidebarWidth: CGFloat = 320
    static let cornerRadius: CGFloat = 12
    static let sidebarPadding: CGFloat = 12

    static var panelBackground: some ShapeStyle {
        .ultraThinMaterial
    }
}

struct OpenHiveGlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(OpenHiveTheme.sidebarPadding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: OpenHiveTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: OpenHiveTheme.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}

extension View {
    func openHiveGlassPanel() -> some View {
        modifier(OpenHiveGlassPanel())
    }
}

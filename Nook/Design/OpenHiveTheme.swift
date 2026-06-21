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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(OpenHiveTheme.sidebarPadding)
            .modifier(LiquidGlassSurface(cornerRadius: OpenHiveTheme.cornerRadius, thickness: .regular))
    }
}

/// Liquid Glass — URL bar, omnibox, floating panels. One glass surface at a time.
struct LiquidGlassSurface: ViewModifier {
    enum Thickness { case thin, regular, thick }

    var cornerRadius: CGFloat = 12
    var thickness: Thickness = .regular

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                )
        } else {
            content
                .background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(strokeTop), .white.opacity(strokeBottom)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
        }
    }

    private var material: Material {
        switch thickness {
        case .thin: .ultraThinMaterial
        case .regular: .thinMaterial
        case .thick: .regularMaterial
        }
    }

    private var strokeTop: Double { thickness == .thin ? 0.28 : 0.35 }
    private var strokeBottom: Double { 0.06 }
    private var shadowOpacity: Double { thickness == .thick ? 0.14 : 0.08 }
    private var shadowRadius: CGFloat { thickness == .thick ? 16 : 10 }
    private var shadowY: CGFloat { thickness == .thick ? 8 : 4 }
}

struct LiquidGlassCapsule: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule(style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
                .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
        }
    }
}

extension View {
    func openHiveGlassPanel() -> some View {
        modifier(OpenHiveGlassPanel())
    }

    func liquidGlassSurface(cornerRadius: CGFloat = 12, thickness: LiquidGlassSurface.Thickness = .regular) -> some View {
        modifier(LiquidGlassSurface(cornerRadius: cornerRadius, thickness: thickness))
    }

    func liquidGlassCapsule() -> some View {
        modifier(LiquidGlassCapsule())
    }

    func openHiveFadeTransition() -> some View {
        transition(.opacity.combined(with: .scale(scale: 0.98)))
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: UUID())
    }
}

//
//  ShaderGradientBackground.swift
//  Real ShaderGradient WebGL background keyed to agent model brand
//

import SwiftUI

/// Slow-drifting, grainy ShaderGradient background — same library as the Tera marketing site.
struct ShaderGradientBackground: View {
    var brand: AgentModelBrand
    var animate: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var shouldAnimate: Bool {
        animate && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.035, blue: 0.035)

            if shouldAnimate {
                ShaderGradientWebView(gradientURL: brand.shaderGradientURL)
            } else {
                ShaderGradientWebView(gradientURL: brand.shaderGradientURL)
                    .opacity(0.85)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 2.4), value: brand)
    }
}

/// Static gradient for empty states (animate off, muted).
struct ShaderGradientStaticBackground: View {
    var brand: AgentModelBrand = AgentModelCatalog.defaultOption.brand

    var body: some View {
        ShaderGradientBackground(brand: brand, animate: false)
            .opacity(0.75)
    }
}

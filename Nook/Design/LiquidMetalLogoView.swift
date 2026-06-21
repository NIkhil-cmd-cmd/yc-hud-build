//
//  LiquidMetalLogoView.swift
//  Liquid-metal shimmer on the OpenHive mark (splash, about, agent home)
//

import SwiftUI

struct LiquidMetalLogoView: View {
    var size: CGFloat = 44
    var animate: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animate && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    logoContent(phase: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                logoContent(phase: 0)
            }
        }
        .accessibilityLabel("OpenHive")
    }

    private func logoContent(phase: Double) -> some View {
        ZStack {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.55, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    shimmerColor(phase: phase, offset: 0),
                    shimmerColor(phase: phase, offset: 0.35),
                    shimmerColor(phase: phase, offset: 0.7)
                )
                .shadow(color: shimmerColor(phase: phase, offset: 0.2).opacity(0.45), radius: size * 0.12)
        }
        .frame(width: size, height: size)
    }

    private func shimmerColor(phase: Double, offset: Double) -> Color {
        let hue = (phase * 0.08 + offset).truncatingRemainder(dividingBy: 1.0)
        return Color(hue: hue, saturation: 0.55, brightness: 0.92)
    }
}

struct LiquidMetalLogoBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            LiquidMetalLogoView(size: 28, animate: true)
            Text("OpenHive")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.85))
        }
    }
}

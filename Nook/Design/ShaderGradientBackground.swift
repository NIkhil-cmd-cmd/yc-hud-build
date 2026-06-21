//
//  ShaderGradientBackground.swift
//  Animated mesh-style gradient for Agent Home / empty states (ShaderGradient-inspired)
//

import SwiftUI

/// Slow-drifting gradient background — pauses when tab unfocused or reduce motion is on.
struct ShaderGradientBackground: View {
    var animate: Bool = true
    /// uSpeed analogue — keep low (0.1–0.3) to avoid motion sickness
    var speed: Double = 0.18
    var palette: TimeOfDayPalette = .current()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var shouldAnimate: Bool {
        animate && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        Group {
            if shouldAnimate {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    gradientCanvas(t: timeline.date.timeIntervalSinceReferenceDate * speed)
                }
            } else {
                gradientCanvas(t: 0)
            }
        }
        .ignoresSafeArea()
    }

    private func gradientCanvas(t: Double) -> some View {
        Canvas { context, size in
                let colors = palette.colors(for: colorScheme)
                let blobs: [(CGPoint, Color, CGFloat)] = [
                    (wavePoint(t: t, phase: 0, size: size), colors[0], size.width * 0.55),
                    (wavePoint(t: t, phase: 1.8, size: size), colors[1], size.width * 0.48),
                    (wavePoint(t: t, phase: 3.2, size: size), colors[2], size.width * 0.42),
                ]
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [colors[0].opacity(0.35), colors[2].opacity(0.2)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )
                for (center, color, radius) in blobs {
                    let rect = CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [color.opacity(0.55), color.opacity(0)]),
                            center: center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }
        }
    }

    private func wavePoint(t: Double, phase: Double, size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * (0.5 + 0.28 * sin(t + phase)),
            y: size.height * (0.45 + 0.22 * cos(t * 0.85 + phase * 0.6))
        )
    }
}

struct TimeOfDayPalette {
    let dawn: [Color]
    let day: [Color]
    let dusk: [Color]
    let night: [Color]

    static func current(date: Date = .now) -> TimeOfDayPalette {
        TimeOfDayPalette(
            dawn: [
                Color(red: 0.98, green: 0.72, blue: 0.55),
                Color(red: 0.55, green: 0.65, blue: 0.95),
                Color(red: 0.85, green: 0.55, blue: 0.78),
            ],
            day: [
                Color(red: 0.45, green: 0.72, blue: 0.98),
                Color(red: 0.62, green: 0.55, blue: 0.95),
                Color(red: 0.55, green: 0.85, blue: 0.78),
            ],
            dusk: [
                Color(red: 0.95, green: 0.45, blue: 0.55),
                Color(red: 0.45, green: 0.35, blue: 0.72),
                Color(red: 0.85, green: 0.55, blue: 0.45),
            ],
            night: [
                Color(red: 0.12, green: 0.16, blue: 0.32),
                Color(red: 0.22, green: 0.18, blue: 0.42),
                Color(red: 0.08, green: 0.22, blue: 0.38),
            ]
        )
    }

    func colors(for scheme: ColorScheme) -> [Color] {
        let hour = Calendar.current.component(.hour, from: .now)
        if scheme == .dark || hour >= 20 || hour < 6 {
            return night
        }
        if hour < 9 { return dawn }
        if hour >= 17 { return dusk }
        return day
    }
}

/// Static gradient for empty states (animate off, muted).
struct ShaderGradientStaticBackground: View {
    var body: some View {
        ShaderGradientBackground(animate: false, speed: 0)
            .opacity(0.65)
    }
}

//
//  HUDBenchmarkView.swift
//  OpenHive — native vs HUD browser timing comparison
//

import SwiftUI

struct HUDBenchmarkResult: Equatable {
    var nativeMs: Int = 0
    var hudMs: Int = 0
    var nativeTokens: Int = 0
    var hudTokens: Int = 0
    var nativeGrade: Double = 0
    var hudGrade: Double = 0
    var speedup: Double = 1
    var runId: String?
    var isRunning: Bool = false
    var phase: String = ""
}

struct HUDBenchmarkView: View {
    @Bindable var runState = TaskRunState.shared
    var benchmark: HUDBenchmarkResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HUD Browser Compare")
                .font(.headline)

            if benchmark.isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(benchmark.phase.isEmpty ? "Running benchmark…" : benchmark.phase)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                benchmarkCard(
                    title: "Native",
                    ms: benchmark.nativeMs,
                    tokens: benchmark.nativeTokens,
                    grade: benchmark.nativeGrade,
                    tint: .green
                )
                benchmarkCard(
                    title: "HUD browser",
                    ms: benchmark.hudMs,
                    tokens: benchmark.hudTokens,
                    grade: benchmark.hudGrade,
                    tint: .orange
                )
            }

            if benchmark.speedup > 1, !benchmark.isRunning {
                Text("Native is \(String(format: "%.1f", benchmark.speedup))× faster · \(benchmark.nativeTokens) vs \(benchmark.hudTokens) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .openHiveGlassPanel()
        .frame(maxWidth: 480)
    }

    private func benchmarkCard(title: String, ms: Int, tokens: Int, grade: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(formatMs(ms))
                .font(.title2.monospacedDigit())
            Text("\(tokens) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
            if grade > 0 {
                Text("\(Int(grade * 100))% HUD grade")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func formatMs(_ ms: Int) -> String {
        if ms >= 1000 {
            return String(format: "%.1fs", Double(ms) / 1000)
        }
        return "\(ms)ms"
    }
}

//
//  SkillConfirmSheet.swift
//  OpenHive — confirm KNN skill match before MDP rollout
//

import SwiftUI

struct SkillConfirmSheet: View {
    let match: SkillMatch
    let onRunSkill: () -> Void
    let onUseAgent: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Skill found")
                    .font(.headline)
                Text("\"\(match.name)\"")
                    .font(.title3.weight(.semibold))
                Text("\(Int(match.confidence * 100))% match")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Use agent instead", action: onUseAgent)
                Button("Run skill", action: onRunSkill)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 380)
    }
}

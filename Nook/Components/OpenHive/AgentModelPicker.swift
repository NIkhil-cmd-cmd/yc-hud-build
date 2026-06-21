//
//  AgentModelPicker.swift
//  OpenHive — logo model picker for the new-tab agent bar
//

import SwiftUI

struct AgentModelLogo: View {
    let brand: AgentModelBrand
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [brand.accent.opacity(0.95), brand.accent.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if brand.usesEmojiLogo {
                Text(brand.monogram)
                    .font(.system(size: size * 0.52))
            } else {
                Text(brand.monogram)
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: brand.accent.opacity(0.25), radius: 4, y: 2)
    }
}

struct AgentModelPickerButton: View {
    @Binding var selection: AgentModelOption
    @State private var showPicker = false

    var body: some View {
        Button {
            showPicker.toggle()
        } label: {
            HStack(spacing: 6) {
                AgentModelLogo(brand: selection.brand, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(selection.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(selection.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Choose agent model")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            AgentModelPickerGrid(selection: $selection, isPresented: $showPicker)
        }
    }
}

private struct AgentModelPickerGrid: View {
    @Binding var selection: AgentModelOption
    @Binding var isPresented: Bool

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent model")
                .font(.headline)
            Text("Runs tasks in this tab with the selected provider.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AgentModelCatalog.all) { option in
                    Button {
                        selection = option
                        TaskRunState.shared.setAgentModel(option)
                        EngineBridge.shared.setAgentModelPreference(
                            provider: option.provider,
                            model: option.model
                        )
                        isPresented = false
                    } label: {
                        HStack(spacing: 10) {
                            AgentModelLogo(brand: option.brand, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(option.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if option == selection {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            option == selection
                                ? Color.accentColor.opacity(0.10)
                                : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    option == selection ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

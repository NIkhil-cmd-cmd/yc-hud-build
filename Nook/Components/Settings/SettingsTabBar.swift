//
//  SettingsTabBar.swift
//  Nook
//
//  Created by Maciek Bagiński on 03/08/2025.
//
import SwiftUI

struct SettingsTabBar: View {
    @Environment(\.nookSettings) var nookSettings

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            Text(nookSettings.currentSettingsTab.name)
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 40)
        .background {
            BlurEffectView(
                material: nookSettings.currentMaterial,
                state: .active
            )
        }
        .overlay {
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .backgroundDraggable()
    }
}

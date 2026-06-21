//
//  EmptyWebsiteView.swift
//  Nook
//
//  Created by Maciek Bagiński on 28/07/2025.
//

import SwiftUI

struct EmptyWebsiteView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Match the exact background and styling of the real webview
                Color(nsColor: .windowBackgroundColor).opacity(0.2)
                    .clipShape(RoundedRectangle(cornerRadius: {
                        if #available(macOS 26.0, *) {
                            return 12
                        } else {
                            return 6
                        }
                    }(), style: .continuous))
                    .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 0)

                VStack(spacing: 12) {
                    Image(systemName: "moon.stars")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.5))

                    Text("No tab selected")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

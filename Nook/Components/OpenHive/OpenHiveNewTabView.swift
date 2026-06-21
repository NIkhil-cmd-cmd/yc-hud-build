//
//  OpenHiveNewTabView.swift
//  Nook — redirects to AgentHomeView
//

import SwiftUI

struct OpenHiveNewTabView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        AgentHomeView()
            .environmentObject(browserManager)
            .environment(windowState)
    }
}

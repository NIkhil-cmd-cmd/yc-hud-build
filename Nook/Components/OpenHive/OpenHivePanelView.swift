//
//  OpenHivePanelView.swift
//  OpenHive — legacy wrapper; use WorkflowsPanelView
//

import SwiftUI

struct OpenHivePanelView: View {
    @EnvironmentObject var browserManager: BrowserManager

    var body: some View {
        WorkflowsPanelView(style: .compact)
            .padding(.horizontal, 8)
    }
}

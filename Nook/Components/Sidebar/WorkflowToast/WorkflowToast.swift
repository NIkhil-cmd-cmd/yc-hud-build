//
//  WorkflowToast.swift
//  Nook
//

import SwiftUI

struct WorkflowToast: View {
    @Environment(BrowserWindowState.self) private var windowState

    private var message: String {
        windowState.workflowToastMessage ?? ""
    }

    var body: some View {
        ToastView {
            HStack(spacing: 8) {
                Image(systemName: windowState.workflowToastIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .padding(4)
                    .background(Color.white.opacity(windowState.workflowToastIsError ? 0.15 : 0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.4), lineWidth: 1)
                    }

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .transition(.toast)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                windowState.isShowingWorkflowToast = false
            }
        }
        .onTapGesture {
            windowState.isShowingWorkflowToast = false
        }
    }
}

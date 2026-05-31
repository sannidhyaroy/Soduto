//
//  SMSView.swift
//  Soduto
//
//  Created by Sannidhya Roy on 17/05/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

/// Root view of a per-device SMS window: 2-column NavigationSplitView with the
/// conversation list on the left and the message thread on the right.
struct SMSView: View {
    @ObservedObject var model: SMSDataModel
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    
    /// True when the user has collapsed the sidebar.
    /// Drives where the compose button renders: sidebar's title bar slot when the sidebar is visible, detail pane's toolbar when it's hidden.
    /// Mirrors Apple Mail / Messages behaviour so compose is always reachable regardless of sidebar state.
    private var sidebarIsCollapsed: Bool {
        sidebarVisibility == .detailOnly
    }
    
    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            ConversationListView(model: model, showComposeButton: !sidebarIsCollapsed)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            detailPane
                .toolbar {
                    if sidebarIsCollapsed {
                        ToolbarItem(placement: .primaryAction) {
                            composeButton
                        }
                    }
                }
        }
        // Window title (also what Dock and Window menu show): "New Message" while composing, bare sender name when a conversation is selected, "Messages" otherwise
        // Subtitle hosts the device context (only visible in the titlebar itself, not in the Dock tooltip)
        .navigationTitle(windowTitle)
        .navigationSubtitle(model.device.name)
    }
    
    /// Single source of truth for the compose button; same Button used in both sidebar-visible and sidebar-collapsed configurations.
    private var composeButton: some View {
        Button {
            model.startNewConversation()
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .help("New Message")
        .disabled(model.composingNew)
    }
    
    private var windowTitle: String {
        if model.composingNew { return "New Message" }
        return model.selectedThreadTitle ?? "Messages"
    }
    
    @ViewBuilder
    private var detailPane: some View {
        if model.composingNew {
            NewConversationView(model: model)
        } else if let threadId = model.selectedThreadId {
            ConversationDetailView(model: model, threadId: threadId)
        } else {
            ContentUnavailableView(
                "Select a conversation",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Pick a conversation from the list to view its messages.")
            )
        }
    }
}

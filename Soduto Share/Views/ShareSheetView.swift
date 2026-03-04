//
//  ShareSheetView.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 30/01/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

// MARK: - Transfer Status

enum DeviceTransferStatus: Equatable {
    case idle         // no decoration, interactive
    case transferring // breathing ring, disabled
    case sent         // green ring (after brief green overlay flash), disabled
    case failed       // red ring (after brief red overlay flash), interactive (retry)
}

// MARK: - View Model

class ShareViewModel: ObservableObject {
    @Published var deviceStatuses: [DeviceTransferStatus]
    @Published var cachedBookmarks: [Data]? = nil
    @Published var cachedTexts: [String]? = nil
    @Published var isCollectingAttachments: Bool = false
    
    init(deviceCount: Int) {
        deviceStatuses = Array(repeating: .idle, count: deviceCount)
    }
    
    /// True once any device has been tapped (regardless of outcome).
    var hasInitiatedAnyShare: Bool {
        deviceStatuses.contains(where: { $0 != .idle })
    }
    
    /// Whether a device is currently interactive (can be tapped).
    func isInteractive(_ index: Int) -> Bool {
        guard index < deviceStatuses.count else { return false }
        switch deviceStatuses[index] {
        case .idle, .failed: return true
        case .transferring, .sent: return false
        }
    }
}

// MARK: - Helpers

/// Maps a device type string to the corresponding SF Symbol name.
func sfSymbolName(for deviceType: String) -> String {
    switch deviceType {
    case "desktop": return "desktopcomputer"
    case "laptop":  return "laptopcomputer"
    case "phone":   return "iphone"
    case "tablet":  return "ipad"
    case "tv":      return "tv"
    default:        return "display"
    }
}

// MARK: - ShareSheetView

struct ShareSheetView: View {
    @ObservedObject var viewModel: ShareViewModel
    let deviceEntries: [[String: String]]
    let onDeviceSelected: (Int) -> Void
    let onDismiss: () -> Void
    
    private let columns = [GridItem(.adaptive(minimum: 80))]
    
    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 24, height: 24)
                Text("Soduto Share")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
            
            // Content
            if deviceEntries.isEmpty {
                Spacer()
                Text("No devices available.\nMake sure Soduto is running and a device is paired.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                    .padding(.horizontal, 24)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Array(deviceEntries.enumerated()), id: \.offset) { index, entry in
                            DeviceBubble(
                                name: entry["name"] ?? "Unknown Device",
                                type: entry["type"] ?? "unknown",
                                status: viewModel.deviceStatuses[index]
                            ) {
                                onDeviceSelected(index)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            
            Divider()
            
            // Footer
            HStack {
                Spacer()
                if viewModel.hasInitiatedAnyShare {
                    Button("Done") {
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DeviceBubble

struct DeviceBubble: View {
    let name: String
    let type: String
    let status: DeviceTransferStatus
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var ringBreathing = false
    @State private var showFlashOverlay = false
    
    private var isInteractive: Bool {
        status == .idle || status == .failed
    }
    
    private var ringColor: Color {
        switch status {
        case .idle:         return .clear
        case .transferring: return .accentColor
        case .sent:         return .green
        case .failed:       return .red
        }
    }
    
    private var statusTooltip: String {
        switch status {
        case .idle:         return name
        case .transferring: return "\(name) — Sending\u{2026}"
        case .sent:         return "\(name) — Sent"
        case .failed:       return "\(name) — Failed"
        }
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    // Ring (hidden when idle)
                    if status != .idle {
                        Circle()
                            .stroke(ringColor, lineWidth: 2.5)
                            .frame(width: 59, height: 59)
                            .opacity(status == .transferring ? (ringBreathing ? 0.3 : 1.0) : 1.0)
                    }
                    
                    // Background circle
                    Circle()
                        .fill(isHovering && isInteractive
                              ? Color.accentColor.opacity(0.15)
                              : Color(NSColor.controlBackgroundColor))
                        .frame(width: 56, height: 56)
                    
                    // Device icon
                    Image(systemName: sfSymbolName(for: type))
                        .font(.system(size: 24))
                        .foregroundColor(.primary)
                    
                    // Flash overlay (momentary, on status transition)
                    if showFlashOverlay {
                        if status == .sent {
                            Circle()
                                .fill(Color.green.opacity(0.85))
                                .frame(width: 56, height: 56)
                            Image(systemName: "checkmark")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                        } else if status == .failed {
                            Circle()
                                .fill(Color.red.opacity(0.85))
                                .frame(width: 56, height: 56)
                            Image(systemName: "xmark")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: status)
                .animation(.easeInOut(duration: 0.3), value: showFlashOverlay)
                
                Text(name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .help(statusTooltip)
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: status) { oldStatus, newStatus in
            switch newStatus {
            case .transferring:
                showFlashOverlay = false
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    ringBreathing = true
                }
            case .sent, .failed:
                withAnimation(.default) {
                    ringBreathing = false
                }
                withAnimation(.easeIn(duration: 0.2)) {
                    showFlashOverlay = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        showFlashOverlay = false
                    }
                }
            case .idle:
                ringBreathing = false
                showFlashOverlay = false
            }
        }
    }
}


#Preview {
    ShareSheetView(
        viewModel: ShareViewModel(deviceCount: 5),
        deviceEntries: [
            ["id": "pixel-9", "name": "Pixel 9", "type": "phone"],
            ["id": "galaxy-tab", "name": "Galaxy Tab", "type": "tablet"],
            ["id": "thinkstation", "name": "ThinkStation", "type": "desktop"],
            ["id": "macbookpro", "name" : "MacBook Pro", "type": "laptop" ],
            ["id": "unknowndevice", "name": "Unknown Device", "type": "unknowndevice"]
        ],
        onDeviceSelected: { _ in },
        onDismiss: { }
    )
}

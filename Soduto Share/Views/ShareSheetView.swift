//
//  ShareSheetView.swift
//  Soduto Share
//
//  Created by Sannidhya Roy on 30/01/26.
//  Copyright © 2026 Soduto. All rights reserved.
//

import SwiftUI

struct ShareSheetView: View {
    let deviceEntries: [[String: String]]
    let onDeviceSelected: (Int) -> Void
    let onCancel: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 80))]

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
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
                                type: entry["type"] ?? "unknown"
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
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 410, height: 240)
    }
}

struct DeviceBubble: View {
    let name: String
    let type: String
    let action: () -> Void

    @State private var isHovering = false

    private var sfSymbolName: String {
        switch type {
        case "desktop":
            return "desktopcomputer"
        case "laptop":
            return "laptopcomputer"
        case "phone":
            return "iphone"
        case "tablet":
            return "ipad"
        default:
            return "display"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isHovering
                              ? Color.accentColor.opacity(0.15)
                              : Color(NSColor.controlBackgroundColor))
                        .frame(width: 56, height: 56)

                    Image(systemName: sfSymbolName)
                        .font(.system(size: 24))
                        .foregroundColor(.primary)
                }

                Text(name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 72)
                    .help(name)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}


#Preview {
    ShareSheetView(
        deviceEntries: [
            ["id": "pixel-9", "name": "Pixel 9", "type": "phone"],
            ["id": "galaxy-tab", "name": "Galaxy Tab", "type": "tablet"],
            ["id": "thinkstation", "name": "ThinkStation", "type": "desktop"],
            ["id": "macbookpro", "name" : "MacBook Pro", "type": "laptop" ],
            ["id": "unknowndevice", "name": "Unknown Device", "type": "unknowndevice"]
        ],
        onDeviceSelected: { _ in },
        onCancel: { }
    )
}
